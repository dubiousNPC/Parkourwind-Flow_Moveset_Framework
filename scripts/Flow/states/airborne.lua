---@omw-context player
-- Airborne. Owns the priority ladder, Roll arming and the air poses.
local BaseState = require('scripts/Flow/states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local input = require('openmw.input')
local async = require('openmw.async')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local RollState = require('scripts/Flow/states/roll')
local InputManager = require('scripts/Flow/core/input')
local Settings = require('scripts/Flow/settings')
local AirPose = require('scripts/Flow/core/air_pose')
local SkillCheck = require('scripts/Flow/core/skill_check')
local StateManager = require('scripts/Flow/core/state_manager')
local Anim = require('scripts/Flow/playerAnim')
local FallPick = require('scripts/Flow/core/fall_pick')
local FallPlan = require('scripts/Flow/core/fall_plan')
local LandingWatch = require('scripts/Flow/core/landing_watch')
local Surface = require('scripts/Flow/core/surface')

local AirborneState = BaseState.new("Airborne", { sensors = { forward = true, ledge = true } })

local RUNGS = { "Vault", "Mantle", "LedgeHang" }

local FORWARD_DEADZONE = 0.1

local ROLL_MIN_AIR_TIME = 0.75

-- Skydive arms on its own after a sustained fall, with real air below.
local SKYDIVE_ARM_TIME = 1.2
local SKYDIVE_CLEARANCE = 1200.0
local SKYDIVE_MIN_FALL_SPEED = 300.0

local HEAVY_FALL_SPEED = 900.0   -- u/s down: the air pool narrows to the big tumbles
local FALLEN_POSE_TIME = 0.6     -- a botch that showed the Falling pose this long lands as "fallen"
local fallVz = 0                 -- peak downward speed while off the ground
local fallVx, fallVy = 0, 0      -- horizontal velocity, world axes
local peakZ = 0                  -- highest point of this fall, for the fall's height

-- Asked by playerAnim at pick time only.
local function fallContext()
    local bearing = nil
    if fallVx * fallVx + fallVy * fallVy > 100 * 100 then
        local f = mwSelf.rotation * util.vector3(0, 1, 0)
        bearing = FallPick.bearing(fallVx, fallVy, f.x, f.y)
    end
    return bearing, fallVz < -HEAVY_FALL_SPEED, -fallVz
end
Anim.setFallContextProvider(fallContext)

local armed = false
local timeAirborne = 0
local isActive = false
local skydiveTried = false
local rollHandoff = false   -- landing into Roll: the buff stays on, Roll removes it

local DOWN_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

local function skydiveClearance()
    local pos = mwSelf.position
    return not nearby.castRay(pos,
        pos - util.vector3(0, 0, SKYDIVE_CLEARANCE), DOWN_RAY_OPTS).hit
end

input.registerTriggerHandler("Jump", async:callback(function()
    if core.isWorldPaused() then return end
    if not isActive then return end

    if armed then return end

    if not Settings.stateEnabled("Roll") then return end

    if timeAirborne < ROLL_MIN_AIR_TIME then return end

    -- Forward must be held at the tap.
    if InputManager.intents.moveVector.y <= FORWARD_DEADZONE then return end

    armed = true
    RollState.setBuff(true)
end))

local landedSignal = false

if I.AnimationController and I.AnimationController.addTextKeyHandler then
    I.AnimationController.addTextKeyHandler('jump', function(groupname, key)
            if string.sub(key, -4) == 'land' then
                landedSignal = true
            elseif string.sub(key, -4) == 'stop' and string.sub(key, -9) ~= 'loop stop' then
                landedSignal = true
            end
    end)
end

function AirborneState.getRollDebug()
    if armed then
        return string.format("ROLL: ARMED air=%.2f%s %s", timeAirborne,
            landedSignal and " LANDKEY" or "", AirPose.debugString())
    end
    return string.format("ROLL: idle air=%.2f fwd=%.2f %s", timeAirborne,
        InputManager.intents.moveVector.y, AirPose.debugString())
end

function AirborneState:enter()
    LandingWatch.clear()   -- a new jump: the last landing's window is over
    peakZ = mwSelf.position.z
    isActive = true
    armed = false
    timeAirborne = 0
    landedSignal = false
    skydiveTried = false
    rollHandoff = false
    fallVz = 0
    fallVx, fallVy = 0, 0
end

function AirborneState:exit()
    isActive = false
    if not rollHandoff then RollState.setBuff(false) end
    rollHandoff = false
    AirPose.clear()
end

function AirborneState:update(dt, syncData, inputData)
    timeAirborne = timeAirborne + dt

    -- Still here after handing off: Roll refused (disabled mid-fall).
    if rollHandoff then
        rollHandoff = false
        RollState.setBuff(false)
    end

    local wl = Surface.waterLevel()
    local feetWet = wl and mwSelf.position.z < wl - 10
    if inputData.jump and not feetWet and StateManager.tryAny(RUNGS) then return end

    -- travel while AIRBORNE only: on the touchdown frame the engine reports no
    -- horizontal speed, and reading it then landed a backward fall forward
    if not syncData.isGrounded then
        fallVx, fallVy = syncData.velocityX or 0, syncData.velocityY or 0
    end
    if mwSelf.position.z > peakZ then peakZ = mwSelf.position.z end
    local vz = syncData.verticalVelocity
    if not syncData.isGrounded and vz and vz < fallVz then fallVz = vz end

    if AirPose.inWater() then
        SkillCheck.clearBotch()
        skydiveTried = true
        AirPose.clear()
        if Surface.inWater() then return "Underwater" end
    end

    -- Below the ladder, and a pose rather than a state, so everything above
    -- stays reachable while it runs.
    if not AirPose.active() and not skydiveTried and not armed
       and timeAirborne >= SKYDIVE_ARM_TIME
       and not syncData.isGrounded
       and (syncData.verticalVelocity or 0) < -SKYDIVE_MIN_FALL_SPEED
       and Settings.stateEnabled("Skydive") then
        skydiveTried = true
        if skydiveClearance() then AirPose.startSkydive() end
    end

    if not AirPose.active() and SkillCheck.botched() then
        AirPose.showFalling()
    end

    AirPose.update(dt, syncData, inputData)

    local touchedDown = syncData.isGrounded or (landedSignal and armed)
    if not touchedDown then return nil end

    landedSignal = false

    local skydiveLanding = AirPose.takeSkydiveLanding()
    local fellFor = AirPose.takeFallingTime()
    AirPose.clear()

    -- The landing check: skill, agility and LUCK, scaled by the remaining
    -- FATIGUE %, against the impact speed, with a roll. Its band picks the
    -- clips (core/fall_plan.lua). Taken after AirPose.clear(), so a skydive's
    -- acrobatics buff is already gone and the player's own skill is tested.
    local impact = -fallVz

    if skydiveLanding then
        SkillCheck.clearBotch()
        local margin, high, chance, diff = SkillCheck.fallCheck(impact, FallPlan.roll())
        local landing = { outcome = FallPlan.outcome(margin), highSkill = high }
        AirborneState.lastLanding = string.format("skydive %s%s m%+.0f (c%.0f d%.0f) v%.0f",
            landing.outcome, high and " HIGH" or "", margin, chance or 0, diff or 0, impact)
        if Settings.debugMode() then print("[FLOW] landing " .. AirborneState.lastLanding) end
        -- made it, without the skill for a display: an ordinary landing
        if #Anim.landingGroups("knockdown", landing) == 0 then
            if armed then
                armed = false
                rollHandoff = true
                return "Roll"
            end
            RollState.setBuff(false)
            return "Idle"
        end
        armed = false
        RollState.setBuff(false)
        return "Stumble", { kind = "knockdown", landing = landing }
    end

    if SkillCheck.botched() then
        armed = false
        RollState.setBuff(false)
        -- a botch IS the failure; the check only says how bad it is
        local margin, high, chance, diff = SkillCheck.fallCheck(impact, FallPlan.roll())
        local landing = { outcome = FallPlan.outcome(math.min(margin, -1)), highSkill = high }
        local kind = fellFor >= FALLEN_POSE_TIME and "fallen" or "stumble"
        AirborneState.lastLanding = string.format("botch/%s %s%s m%+.0f (c%.0f d%.0f) v%.0f", kind,
            landing.outcome, high and " HIGH" or "", margin, chance or 0, diff or 0, impact)
        if Settings.debugMode() then print("[FLOW] landing " .. AirborneState.lastLanding) end
        return "Stumble", { kind = kind, landing = landing }
    end

    -- an ordinary landing: the engine may still knock the player down for the
    -- fall's damage; Idle watches for it (core/landing_watch.lua)
    LandingWatch.arm(impact, peakZ - mwSelf.position.z)
    if armed then
        armed = false
        rollHandoff = true
        return "Roll"
    end

    return "Idle"
end

return AirborneState
