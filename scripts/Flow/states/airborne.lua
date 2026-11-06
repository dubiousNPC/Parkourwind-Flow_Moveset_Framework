---@omw-context player
-- Airborne. Owns the priority ladder, Roll arming and the air poses.
local BaseState = require('scripts/Flow/states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local input = require('openmw.input')
local async = require('openmw.async')
local mwSelf = require('openmw.self')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local RollState = require('scripts/Flow/states/roll')
local InputManager = require('scripts/Flow/core/input')
local Settings = require('scripts/Flow/settings')
local AirPose = require('scripts/Flow/core/air_pose')
local SkillCheck = require('scripts/Flow/core/skill_check')
local StateManager = require('scripts/Flow/core/state_manager')

local AirborneState = BaseState.new("Airborne", { sensors = { forward = true, ledge = true } })

-- PRIORITY LADDER. Lowest available action wins; each target's canEnter is
-- the gate. Nothing may go above LedgeHang without re-reading README's
-- Action priority.
local RUNGS = { "Vault", "Mantle", "LedgeHang" }

local FORWARD_DEADZONE = 0.1

local ROLL_MIN_AIR_TIME = 0.75

-- Skydive arms on its own after a sustained fall, with real air below.
local SKYDIVE_ARM_TIME = 1.2
local SKYDIVE_CLEARANCE = 1200.0
-- And only while actually FALLING. Not grounded is not falling: a Levitate
-- spell, a hookshot hang, a rider or passenger placed every frame are all
-- not grounded and still, and each skydived 1.2 s in, then landed as a
-- knockdown. A real fall is past 400 u/s down by the time it arms (750
-- from a standing drop, ~450 after a jump's rise), so 300 costs it nothing.
-- Until the fall starts the arm stays open rather than being spent: a
-- levitation that ends over a drop still gets its skydive.
local SKYDIVE_MIN_FALL_SPEED = 300.0

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
    isActive = true
    armed = false
    timeAirborne = 0
    landedSignal = false
    skydiveTried = false
    rollHandoff = false
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

    if inputData.jump and StateManager.tryAny(RUNGS) then return end

    -- Water owes nothing: no skydive, and no stumble waiting for the shore.
    -- The only water test per frame; AirPose.update relies on it.
    if AirPose.inWater() then
        SkillCheck.clearBotch()
        skydiveTried = true
        AirPose.clear()
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

    -- A released skydive lands as a knockdown, ahead of everything else: it is
    -- the end of the fall, not a manoeuvre to recover from.
    local skydiveLanding = AirPose.takeSkydiveLanding()
    AirPose.clear()

    if skydiveLanding then
        armed = false
        RollState.setBuff(false)
        SkillCheck.clearBotch()
        return "Stumble", { kind = "knockdown" }
    end

    -- A botched manoeuvre is paid for here, ahead of the roll it would have
    -- earned: the stumble IS the failure, so it cannot be rolled out of.
    if SkillCheck.botched() then
        armed = false
        RollState.setBuff(false)
        return "Stumble", { kind = "stumble" }
    end

    if armed then
        armed = false
        rollHandoff = true
        return "Roll"
    end

    return "Idle"
end

return AirborneState
