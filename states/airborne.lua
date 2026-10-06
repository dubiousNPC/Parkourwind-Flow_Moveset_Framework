---@omw-context player
-- Airborne. Owns Roll arming and WallJump entry.
local BaseState = require('states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local input = require('openmw.input')
local async = require('openmw.async')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local RollState = require('states/roll')
local InputManager = require('core/input')
local VaultState = require('states/vault')
local MantleState = require('states/mantle')
local Settings = require('settings')
local Body = require('core/body')
local Owned = require('core/owned')
local EngineSync = require('core/engine_sync')

local AirborneState = BaseState.new("Airborne")

local AGILITY_BONUS = 70

local LEDGE_GRAB_TOLERANCE = 20
local LEDGE_AIM_TOLERANCE = 40

local FORWARD_DEADZONE = 0.1

local ROLL_MIN_AIR_TIME = 1.0

local WALL_JUMP_WINDOW = 0.45
local WALL_JUMP_COOLDOWN = 2.0

local WALL_CONTACT_MARGIN = 8.0

local WALL_CONTACT_HEIGHT = 70.0

local armed = false
local timeAirborne = 0
local isActive = false
local jumpEdge = false
local wallJumpReadyAt = 0
local wallJumpLanding = nil
local agilityApplied = false

-- One wall jump per confirmed landing, counted by EngineSync.
local function wallJumpSpent(syncData)
    return wallJumpLanding ~= nil and wallJumpLanding == syncData.landings
end

local function applyAgility(enable)
    if enable == agilityApplied then return end
    local amount = enable and AGILITY_BONUS or -AGILITY_BONUS
    Owned.attribute('agility', amount)
    Owned.effect(core.magic.EFFECT_TYPE.FortifyAttribute, amount, 'agility')
    agilityApplied = enable
end

-- No HeightMap: terrain slopes were reading as walls.
local WALL_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door
}

-- Camera aimed at or above the lip. SharedRay is camera-aimed, so no pitch sign.
local function lookingAtLedge(targetPos)
    local get = I.SharedRay and (I.SharedRay.getUnclipped or I.SharedRay.get)
    if not get then return true end
    local ray = get()
    if not (ray and ray.hit and ray.hitPos) then return true end
    return ray.hitPos.z >= targetPos.z - LEDGE_AIM_TOLERANCE
end

-- One ray, straight ahead, cast only on the keypress.
local function wallContact()
    local reach = Body.halfWidth() + WALL_CONTACT_MARGIN
    local pos = mwSelf.position
    local origin = util.vector3(pos.x, pos.y, pos.z + WALL_CONTACT_HEIGHT)

    local yaw = mwSelf.rotation:getYaw()
    local fwd = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))

    local res = nearby.castRay(origin, origin + fwd * reach, WALL_RAY_OPTS)
    return res.hit and res.hitNormal ~= nil
        and res.hitNormal.z < Sensor.WALKABLE_SLOPE_Z
end

input.registerTriggerHandler("Jump", async:callback(function()
    if core.isWorldPaused() then return end
    if not isActive then return end

    if InputManager.intents.moveVector.y > FORWARD_DEADZONE then
        jumpEdge = true
    end

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
    local wj = wallJumpSpent(EngineSync.data) and " WJ-used"
        or (timeAirborne <= WALL_JUMP_WINDOW and " WJ-ready" or "")

    if armed then
        return string.format("ROLL: ARMED air=%.2f%s%s", timeAirborne,
            landedSignal and " LANDKEY" or "", wj)
    end
    return string.format("ROLL: idle air=%.2f fwd=%.2f%s", timeAirborne,
        InputManager.intents.moveVector.y, wj)
end

local healthBeforeLanding = nil

function AirborneState:enter(syncData)
    isActive = true
    healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
    armed = false
    timeAirborne = 0
    jumpEdge = false
    landedSignal = false
end

function AirborneState:exit()
    isActive = false
    applyAgility(false)
end

function AirborneState:update(dt, syncData, inputData)
    timeAirborne = timeAirborne + dt

    -- PRIORITY LADDER. Lowest available action wins; WallJump is the last
    -- resort, for when the top is out of reach of all three. See README.
    if inputData.jump then
        if Sensor.data.interaction == "Vault"
           and not VaultState.isBlocked(Sensor.data.targetPos) then
            jumpEdge = false
            return "Vault"
        end

        if Sensor.data.interaction == "Mantle"
           and not MantleState.isBlocked(Sensor.data.targetPos) then
            jumpEdge = false
            return "Mantle"
        end

        if SensorExt.data.interaction == "LedgeHang" and SensorExt.data.targetPos
           and lookingAtLedge(SensorExt.data.targetPos) then
            local handsZ = mwSelf.position.z + SensorExt.grabMinHeight() - LEDGE_GRAB_TOLERANCE
            if SensorExt.data.targetPos.z > handsZ then
                jumpEdge = false
                return "LedgeHang"
            end
        end
    end

    if jumpEdge then
        jumpEdge = false
        if not wallJumpSpent(syncData)
           and Sensor.data.tooHigh
           and timeAirborne <= WALL_JUMP_WINDOW
           and core.getRealTime() >= wallJumpReadyAt
           and Settings.stateEnabled("WallJump")
           and wallContact() then
            wallJumpLanding = syncData.landings
            wallJumpReadyAt = core.getRealTime() + WALL_JUMP_COOLDOWN
            return "WallJump"
        end
    end

    local touchedDown = syncData.isGrounded or (landedSignal and armed)

    if not touchedDown then
        healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
        return nil
    end

    landedSignal = false
    if armed then
        applyAgility(false)
        armed = false
        RollState.setLandingData(healthBeforeLanding)
        return "Roll"
    end

    applyAgility(false)
    return "Idle"
end

return AirborneState