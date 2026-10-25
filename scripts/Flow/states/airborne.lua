---@omw-context player
-- Airborne. Owns the priority ladder, Roll arming and the air poses.
local BaseState = require('scripts/Flow/states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local camera = require('openmw.camera')
local input = require('openmw.input')
local async = require('openmw.async')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local Sensor = require('scripts/Flow/core/sensor')
local SensorExt = require('scripts/Flow/core/optional/sensor_ext')
local RollState = require('scripts/Flow/states/roll')
local InputManager = require('scripts/Flow/core/input')
local VaultState = require('scripts/Flow/states/vault')
local MantleState = require('scripts/Flow/states/mantle')
local Settings = require('scripts/Flow/settings')
local Owned = require('scripts/Flow/core/owned')
local AirPose = require('scripts/Flow/core/air_pose')
local StumbleState = require('scripts/Flow/states/stumble')
local SkillCheck = require('scripts/Flow/core/skill_check')

local AirborneState = BaseState.new("Airborne")

local AGILITY_BONUS = 70

local LEDGE_AIM_DROP = 34   -- how far below level still counts as looking up

local FORWARD_DEADZONE = 0.1

local ROLL_MIN_AIR_TIME = 0.75

-- Skydive arms on its own after a sustained fall, with real air below.
local SKYDIVE_ARM_TIME = 1.2
local SKYDIVE_CLEARANCE = 1200.0

local armed = false
local timeAirborne = 0
local isActive = false
local agilityApplied = false
local skydiveTried = false

local function applyAgility(enable)
    if enable == agilityApplied then return end
    local amount = enable and AGILITY_BONUS or -AGILITY_BONUS
    Owned.attribute('agility', amount)
    Owned.effect(core.magic.EFFECT_TYPE.FortifyAttribute, amount, 'agility')
    agilityApplied = enable
end

-- Camera aimed at or above the lip. SharedRay is camera-aimed, so no pitch sign.
local function lookingAtLedge(targetPos)
    local get = I.SharedRay and (I.SharedRay.getUnclipped or I.SharedRay.get)
    if not get then return true end
    local ray = get()
    if not (ray and ray.hit and ray.hitPos) then return true end
    -- Look DIRECTION, camera to what the camera hit: sign-free, and it does not
    -- care how far away the hit is. Comparing the hit's absolute Z to the lip
    -- rejected any shot that landed on the wall below it, which is most of them.
    return (ray.hitPos.z - camera.getPosition().z) > -LEDGE_AIM_DROP
end

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
    applyAgility(true)
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

local healthBeforeLanding = nil

function AirborneState:enter(syncData)
    isActive = true
    healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
    armed = false
    timeAirborne = 0
    landedSignal = false
    skydiveTried = false
end

function AirborneState:exit()
    isActive = false
    applyAgility(false)
    AirPose.clear()
end

function AirborneState:update(dt, syncData, inputData)
    timeAirborne = timeAirborne + dt

    -- PRIORITY LADDER. Lowest available action wins. See README.
    if inputData.jump then
        if Sensor.data.interaction == "Vault"
           and not VaultState.isBlocked(Sensor.data.targetPos) then
            return "Vault"
        end

        if Sensor.data.interaction == "Mantle"
           and not MantleState.isBlocked(Sensor.data.targetPos) then
            return "Mantle"
        end

        if SensorExt.data.interaction == "LedgeHang" and SensorExt.data.targetPos
           and lookingAtLedge(SensorExt.data.targetPos) then
            local handsZ = mwSelf.position.z + SensorExt.grabFloorHeight()
            if SensorExt.data.targetPos.z > handsZ then
                return "LedgeHang"
            end
        end
    end

    -- Below the ladder, and a pose rather than a state, so everything above
    -- stays reachable while it runs.
    if not AirPose.active() and not skydiveTried and not armed
       and timeAirborne >= SKYDIVE_ARM_TIME
       and not syncData.isGrounded
       and Settings.stateEnabled("Skydive") then
        skydiveTried = true
        if skydiveClearance() then AirPose.startSkydive() end
    end

    if not AirPose.active() and SkillCheck.botched() then
        AirPose.showFalling()
    end

    AirPose.update(dt, syncData, inputData)

    local touchedDown = syncData.isGrounded or (landedSignal and armed)

    if not touchedDown then
        healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
        return nil
    end

    landedSignal = false
    applyAgility(false)

    -- A released skydive lands as a knockdown, ahead of everything else: it is
    -- the end of the fall, not a manoeuvre to recover from.
    local skydiveLanding = AirPose.takeSkydiveLanding()
    AirPose.clear()

    if skydiveLanding then
        armed = false
        SkillCheck.clearBotch()
        StumbleState.request("knockdown")
        return "Stumble"
    end

    -- A botched manoeuvre is paid for here, ahead of the roll it would have
    -- earned: the stumble IS the failure, so it cannot be rolled out of.
    if SkillCheck.botched() then
        armed = false
        StumbleState.request("stumble")
        return "Stumble"
    end

    if armed then
        armed = false
        RollState.setLandingData(healthBeforeLanding)
        return "Roll"
    end

    return "Idle"
end

return AirborneState