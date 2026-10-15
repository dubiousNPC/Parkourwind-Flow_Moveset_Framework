---@omw-context player
-- LedgeHang. Holds an overhead ledge; routes to Shimmy and Mantle.
local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')
local Sensor = require('core/sensor')
local Settings = require('settings')
local SensorExt = require('core/optional/sensor_ext')
local ShimmyState = require('states/shimmy')
local MantleState = require('states/mantle')
local Owned = require('core/owned')

local LedgeHangState = BaseState.new("LedgeHang")

local KICK_RAY_OPTS = { ignore = mwSelf }

local LIP_SANITY_RANGE = 300

local LEVITATE_MAG = 200
local HANG_OFFSET_Z = 125
local WALL_OFFSET = 35
local KICK_FORCE_BACK = 350
local KNEE_CHECK_DIST = 60
local CLIMB_COOLDOWN = 0.3

local levitationApplied = false
local wallNormal = nil
local timeInState = 0
local cachedTargetPos = nil

local function applyGravityHack(enable)
    if enable == levitationApplied then return end
    Owned.effect(core.magic.EFFECT_TYPE.Levitate, enable and LEVITATE_MAG or -LEVITATE_MAG)
    levitationApplied = enable
end

local function snapTo(pos, rot)
    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = pos,
        rotation = rot
    })
end

function LedgeHangState:enter(syncData)
    if Settings.debugMode() then print("[FLOW_STATE] >>> ENTERING LEDGE HANG") end

    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("LedgeHang", SensorExt.data.debugReason, "GRABBED")

    timeInState = 0
    applyGravityHack(true)

    local resumeLip, resumeNormal = ShimmyState.consumeResultLip()
    if not resumeLip then ShimmyState.clearLastDirection() end

    if resumeLip and (resumeLip - mwSelf.position):length() > LIP_SANITY_RANGE then
        resumeLip, resumeNormal = nil, nil
    end

    local lipSource = resumeLip or SensorExt.data.targetPos

    if lipSource then
        cachedTargetPos = lipSource

        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        wallNormal = resumeNormal or SensorExt.data.wallNormal or -forward

        local hangPos = cachedTargetPos - util.vector3(0, 0, HANG_OFFSET_Z)
        hangPos = hangPos + (wallNormal * WALL_OFFSET)

        local lookDir = -wallNormal
        local targetYaw = math.atan2(lookDir.x, lookDir.y)
        local targetRot = util.transform.rotateZ(targetYaw)

        snapTo(hangPos, targetRot)
    end

    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
end

function LedgeHangState:exit()
    if Settings.debugMode() then print("[FLOW_STATE] <<< EXITING LEDGE HANG") end
    applyGravityHack(false)

    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)

    cachedTargetPos = nil
end

function LedgeHangState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    local lateralInput = inputData.moveVector.x
    if math.abs(lateralInput) > 0.1 and wallNormal and cachedTargetPos then
        local dir = (lateralInput > 0) and 1 or -1
        local newLip = ShimmyState.probeStep(mwSelf.position, cachedTargetPos, wallNormal, dir)
        if newLip then
            ShimmyState.setStep(dir, wallNormal, newLip)
            return "Shimmy"
        end
    end

    if inputData.jump and inputData.moveVector.y < 0 then
        local kneePos = mwSelf.position + util.vector3(0,0, 30)
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local kickTarget = kneePos + (forward * KNEE_CHECK_DIST)
        local res = nearby.castRay(kneePos, kickTarget, KICK_RAY_OPTS)

        local turnSign = (ShimmyState.lastDirection() < 0) and -1 or 1
        local awayYaw = mwSelf.rotation:getYaw() + (turnSign * math.pi * 0.5)
        local awayRot = util.transform.rotateZ(awayYaw)

        if res.hit then
            local nudge = mwSelf.position + (-forward * (KICK_FORCE_BACK * 0.15)) + (util.vector3(0,0,20))
            snapTo(nudge, awayRot)
        else
            -- Nothing to push off, but still turn to face the fall.
            snapTo(mwSelf.position, awayRot)
        end
        return "Airborne"
    end

    if inputData.jump and timeInState > CLIMB_COOLDOWN then
        Sensor.data.interaction = "Mantle"
        Sensor.data.targetPos = cachedTargetPos
        MantleState.vouchDestination()

        return "Mantle"
    end

    if inputData.crouch then
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local nudge = mwSelf.position + (-forward * 20)
        snapTo(nudge)
        return "Airborne"
    end

    return nil
end

return LedgeHangState