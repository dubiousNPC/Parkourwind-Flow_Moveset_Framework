---@omw-context player
--[[
    states/wall_boost.lua

    Launch away from a ledge at 45 degrees. Entered from Shimmy by pressing
    back + jump. This is the double-jump mechanic reimplemented for the hang:
    a real ballistic arc the player retains control over, not a scripted
    teleport to a fixed point.

    MOVEMENT: velocity + gravity integration in global/flow_amf_backend.lua
    (FLOW_Boost_Start), the same technique Hookshot uses for its DROP/PULL
    sequences. The arc ends when the player actually lands or the backend's
    ground probe fires - not on a timer.

    Note the removed WallJump used a fixed teleport-lerp and was cut for
    exactly that reason. What broke that feature was never the ballistics; it
    was the per-tick collision cage clamping the move to zero at the wall the
    player was flush against, and a stuck-failsafe threshold misapplied per
    tick instead of per 50ms window. Neither applies here: the boost path in
    the backend does no cage work at all.

    45 DEGREES: equal horizontal and vertical speed components. The launch
    velocity for a given apex is derived in the backend from its own GRAVITY
    constant, so the horizontal component is matched to it here rather than
    both being guessed independently.

    ANIMATION: directional, via Anim.setVariant() - group names live only in
    playerAnim.lua's GROUPS.WallBoost.variants.
]]--

local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local BaseState = require('states/base_state')
local Anim = require('playerAnim')
local EngineSync = require('core/engine_sync')

local WallBoostState = BaseState.new("WallBoost")

-- ==============================================
-- CONFIGURATION
-- ==============================================
local APEX_HEIGHT = 160.0     -- peak height above the launch point
local MAX_DURATION = 1.4      -- hard cap; the backend normally ends it earlier
local MIN_STATE_TIME = 0.25   -- don't hand off before the arc visibly starts

-- Acrobatics boost for the duration of the arc. As with the Roll's Fortify
-- Agility, the activeEffects entry alone is cosmetic - the OpenMW docs are
-- explicit that fortify-attribute effects "have no practical effect of their
-- own, and must be paired with explicitly modifying the target stat", so the
-- skill modifier is what actually does the work.
local ACROBATICS_BONUS = 40

-- ==============================================
-- ENTRY DATA
-- ==============================================
local pendingWallNormal = nil
local pendingDir = 1

function WallBoostState.setLaunch(wallNormal, dir)
    pendingWallNormal = wallNormal
    pendingDir = dir or 1
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local timeInState = 0
local boostApplied = false

local function applyAcrobatics(enable)
    if enable == boostApplied then return end
    local sign = enable and 1 or -1

    local skill = types.NPC.stats.skills.acrobatics(mwSelf)
    skill.modifier = skill.modifier + (sign * ACROBATICS_BONUS)

    local fx = types.Actor.activeEffects(mwSelf)
    if fx then
        fx:modify(sign * ACROBATICS_BONUS, core.magic.EFFECT_TYPE.FortifyAttribute, 'acrobatics')
    end

    boostApplied = enable
end

function WallBoostState:enter(syncData)
    timeInState = 0

    Anim.setVariant(pendingDir < 0 and "left" or "right")

    -- Horizontal push directly away from the wall. Matching the vertical
    -- component's magnitude gives the requested 45 degrees; the backend
    -- derives that vertical component from APEX_HEIGHT and its own gravity,
    -- so mirror the same formula here rather than hardcoding a second number.
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

    -- Absolute safety net - the backend should always end the arc first.
    if timeInState > MAX_DURATION + 0.1 then
        return "Airborne"
    end

    if timeInState < MIN_STATE_TIME then
        return nil
    end

    if syncData.isGrounded then
        return "Idle"
    end

    -- Still in the air once the arc has been handed back: let Airborne take
    -- over so Vault/Mantle/LedgeHang/Roll all remain reachable from the boost.
    return "Airborne"
end

return WallBoostState
