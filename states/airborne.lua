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

local AirborneState = BaseState.new("Airborne")

local AGILITY_BONUS = 70

local LEDGE_GRAB_TOLERANCE = 20

local FORWARD_DEADZONE = 0.1

local ROLL_MIN_AIR_TIME = 1.0

local WALL_JUMP_WINDOW = 0.45
local WALL_JUMP_COOLDOWN = 1.2

local WALL_CONTACT_MARGIN = 8.0

local WALL_CONTACT_HEIGHT = 70.0

local armed = false
local timeAirborne = 0          -- seconds since this airborne period began;
                                 -- gates both the Roll and the WallJump
local wallJumpUsed = false      -- one wall jump per airborne period. NOT reset
local isActive = false          -- is Airborne the current state? gates the
local wallJumpRequested = false
local wallJumpReadyAt = 0 -- set by the trigger handler, consumed by
local agilityApplied = false

local function applyAgility(enable)
    if enable == agilityApplied then return end
    local sign = enable and 1 or -1

    local attr = types.Actor.stats.attributes.agility(mwSelf)
    attr.modifier = attr.modifier + (sign * AGILITY_BONUS)

    local fx = types.Actor.activeEffects(mwSelf)
    if fx then
        fx:modify(sign * AGILITY_BONUS, core.magic.EFFECT_TYPE.FortifyAttribute, 'agility')
    end

    agilityApplied = enable
end

-- No HeightMap: terrain slopes were reading as walls.
local WALL_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door
}

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

    if not wallJumpUsed
       and not wallJumpRequested
       and timeAirborne <= WALL_JUMP_WINDOW
       and core.getRealTime() >= wallJumpReadyAt
       and InputManager.intents.moveVector.y > FORWARD_DEADZONE
       and Settings.stateEnabled("WallJump")
       and wallContact() then
        wallJumpUsed = true
        wallJumpRequested = true
        wallJumpReadyAt = core.getRealTime() + WALL_JUMP_COOLDOWN
        return
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
    local wj = wallJumpUsed and " WJ-used"
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
    -- Fresh airborne period starts unarmed.
    armed = false
    timeAirborne = 0
    wallJumpRequested = false
    landedSignal = false

end

function AirborneState:exit()
    isActive = false
    applyAgility(false)
end

function AirborneState:update(dt, syncData, inputData)
    timeAirborne = timeAirborne + dt

    if wallJumpRequested then
        wallJumpRequested = false
        return "WallJump"
    end

    -- 1. Obstacle Interaction (Mid-Air) - jump-gated, matching Idle
    if inputData.jump then
        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked(Sensor.data.targetPos) then
            return "Vault"
        end

        -- B. Ledge Hang (High/Overhead obstacles)
        if SensorExt.data.interaction == "LedgeHang" and SensorExt.data.targetPos then
            local handsZ = mwSelf.position.z + SensorExt.grabMinHeight() - LEDGE_GRAB_TOLERANCE
            if SensorExt.data.targetPos.z > handsZ then
                return "LedgeHang"
            end
        end

        -- C. Mantling (Medium obstacles)
        if Sensor.data.interaction == "Mantle" and not MantleState.isBlocked(Sensor.data.targetPos) then
            return "Mantle"
        end
    end

    local touchedDown = syncData.isGrounded or (landedSignal and armed)

    if not touchedDown then
        healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
    end

    -- 2. Landing Logic
    if touchedDown then
        landedSignal = false
        wallJumpUsed = false   -- cleared on touchdown only; see README
        if armed then
            applyAgility(false)
            armed = false
            RollState.setLandingData(healthBeforeLanding)
            return "Roll"
        end

        applyAgility(false)

        return "Idle"
    end

    return nil
end

return AirborneState