---@omw-context player
-- WallBoost. 45-degree launch away from a ledge.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local Owned = require('core/owned')
local I = require('openmw.interfaces')
local BaseState = require('states/base_state')
local Anim = require('playerAnim')
local EngineSync = require('core/engine_sync')

local WallBoostState = BaseState.new("WallBoost")

local APEX_HEIGHT = 160.0     -- peak height above the launch point
local MAX_DURATION = 1.4      -- backend cap
local MIN_STATE_TIME = 0.25   -- hands off to Airborne after this; exit cancels the boost

local ACROBATICS_BONUS = 40

local pendingWallNormal = nil
local pendingDir = 1

function WallBoostState.setLaunch(wallNormal, dir)
    pendingWallNormal = wallNormal
    pendingDir = dir or 1
end

local timeInState = 0
local boostApplied = false

local function applyAcrobatics(enable)
    if enable == boostApplied then return end
    local amount = enable and ACROBATICS_BONUS or -ACROBATICS_BONUS
    Owned.skill('acrobatics', amount)
    Owned.effect(core.magic.EFFECT_TYPE.FortifySkill, amount, 'acrobatics')
    boostApplied = enable
end

function WallBoostState:enter(syncData)
    timeInState = 0

    Anim.setVariant(pendingDir < 0 and "left" or "right")

    local M_TO_UNITS = 400
    local GRAVITY = 9.80665 * M_TO_UNITS
    local speed = math.sqrt(2 * GRAVITY * APEX_HEIGHT)

    local n = pendingWallNormal or util.vector3(0, 0, 0)
    local flat = util.vector3(n.x, n.y, 0)
    if flat:length() > 0.01 then
        flat = flat:normalize()
    end

    pendingWallNormal = nil

    I.Controls.overrideMovementControls(true)
    EngineSync.suspendTeleportDetection(true)
    applyAcrobatics(true)

    core.sendGlobalEvent('FLOW_Boost_Start', {
        actor = mwSelf,
        apexHeight = APEX_HEIGHT,
        pushVelocity = flat * speed,
        maxDuration = MAX_DURATION,
    })
end

function WallBoostState:exit()
    I.Controls.overrideMovementControls(false)
    EngineSync.suspendTeleportDetection(false)
    applyAcrobatics(false)
    core.sendGlobalEvent('FLOW_Boost_Cancel', { actor = mwSelf })
end

function WallBoostState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState < MIN_STATE_TIME then
        return nil
    end

    if syncData.isGrounded then
        return "Idle"
    end

    return "Airborne"
end

return WallBoostState
