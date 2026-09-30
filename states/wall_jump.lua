---@omw-context player
--[[
    states/wall_jump.lua

    Boosted double-jump off a wall, straight up. Jump into a wall, then press
    jump again while airborne and still in contact with it.

    ENTRY is owned by states/airborne.lua - see its WALL JUMP block. The wall
    detection and the timing window live up there because both are answered on
    the Jump KEYPRESS, which costs nothing per frame. This state is entered
    with the decision already made.

    WHY THIS ONE WORKS WHERE THE OLD WALLJUMP DID NOT
    -------------------------------------------------
    The removed WallJump moved the player with a fixed teleport-lerp toward a
    spawned platform mesh. It failed for two reasons, neither of them
    ballistic: a per-tick collision cage clamped the move to zero against the
    very wall the player was flush against, and a stuck-failsafe threshold
    borrowed from Hookshot was applied per tick instead of over the 50ms
    window it was measured for.

    This uses FLOW_Boost_Start - the velocity-and-gravity integrator in
    global/flow_amf_backend.lua that states/wall_boost.lua already runs on.
    No new movement code, no cage, no platform mesh, no lerp to a fixed point.
    A wall jump is simply a WallBoost with the horizontal component set to
    zero, which is what "straight up" means in the backend's own terms.

    Reusing that path is also the answer to whether Acrobatics Expansion has a
    cheaper method. Its KickOff event teleports the actor in ten discrete steps
    across 0.1s, which is the same shape as the per-frame waypoint snapping
    that made Shimmy's camera judder. Integrating a velocity produces a
    continuous trajectory instead, and the camera interpolates it.

    ANIMATION: "pwwalljump1", one-shot, registered in playerAnim.lua's GROUPS
    and ONE_SHOT_STATES. The group is present in all three shipped .kf sets
    (third-person, first-person and the kna variant), which is worth stating
    because the ORIGINAL WallJump T-posed for asking for "pwwalljump" without
    the digit - a full-body blend mask over a group that does not exist leaves
    nothing driving the skeleton.
]]--

local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local BaseState = require('states/base_state')
local EngineSync = require('core/engine_sync')

local WallJumpState = BaseState.new("WallJump")

-- ==============================================
-- CONFIGURATION
-- ==============================================
-- Peak height above the launch point, before the Acrobatics scaling below.
-- Deliberately lower than WallBoost's 160: that one launches away from a ledge
-- across a gap, this one only has to feel like a second jump.
local BASE_APEX_HEIGHT = 120.0

-- Acrobatics scaling on the apex, so the move rewards the skill that governs
-- jumping rather than being a flat bonus. At 0 Acrobatics the apex is
-- BASE_APEX_HEIGHT; at 100 or above it is BASE * (1 + APEX_SKILL_GAIN).
local APEX_SKILL_GAIN = 0.40
local APEX_SKILL_CAP = 100.0

local MAX_DURATION = 1.2      -- hard cap; the landing check normally ends it
local MIN_STATE_TIME = 0.20   -- don't hand off before the launch is visible

-- Brief Jump fortify for the launch, per the feature's spec.
--
-- TWO PARTS, AND THEY DO DIFFERENT JOBS. Morrowind has no "Jump" skill - the
-- skill that governs jumping is Acrobatics, and "Jump" is a magic EFFECT. So
-- the Acrobatics modifier is what has mechanical weight (and it is what scales
-- the apex above), while the activeEffects entry uses EFFECT_TYPE.Jump so the
-- boost reads in the magic menu as the jump fortify it is, rather than as an
-- unexplained skill jump.
--
-- The same pairing rule as everywhere else in this mod applies: the OpenMW
-- docs are explicit that a fortify active effect has "no practical effect of
-- its own, and must be paired with explicitly modifying the target stat".
local ACROBATICS_BONUS = 40

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local timeInState = 0
local boostApplied = false

local function applyJumpFortify(enable)
    if enable == boostApplied then return end
    local sign = enable and 1 or -1

    local skill = types.NPC.stats.skills.acrobatics(mwSelf)
    skill.modifier = skill.modifier + (sign * ACROBATICS_BONUS)

    local fx = types.Actor.activeEffects(mwSelf)
    if fx then
        fx:modify(sign * ACROBATICS_BONUS, core.magic.EFFECT_TYPE.Jump)
    end

    boostApplied = enable
end

local function apexHeight()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / APEX_SKILL_CAP))
    return BASE_APEX_HEIGHT * (1.0 + APEX_SKILL_GAIN * t)
end

function WallJumpState:enter(syncData)
    timeInState = 0

    -- Straight up: zero horizontal push. The backend derives the vertical
    -- launch velocity from the apex and its own GRAVITY, so the height is
    -- requested in the one unit that cannot disagree with the integrator.
    --
    -- Read the Acrobatics bonus BEFORE applying it, or the apex would compound
    -- the fortify it is already being scaled by.
    local apex = apexHeight()

    I.Controls.overrideMovementControls(true)
    EngineSync.suspendTeleportDetection(true)
    applyJumpFortify(true)

    core.sendGlobalEvent('FLOW_Boost_Start', {
        actor = mwSelf,
        apexHeight = apex,
        pushVelocity = util.vector3(0, 0, 0),
        maxDuration = MAX_DURATION,
    })
end

function WallJumpState:exit()
    I.Controls.overrideMovementControls(false)
    EngineSync.suspendTeleportDetection(false)
    applyJumpFortify(false)
    core.sendGlobalEvent('FLOW_Boost_Cancel', { actor = mwSelf })
end

function WallJumpState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- Absolute safety net - the backend drops the move at maxDuration, so
    -- reaching this means the hand-off below never fired.
    if timeInState > MAX_DURATION + 0.1 then
        return "Airborne"
    end

    if timeInState < MIN_STATE_TIME then
        return nil
    end

    if syncData.isGrounded then
        return "Idle"
    end

    -- Still airborne once the launch has been handed back. Airborne owns the
    -- descent, which keeps Vault, Mantle, LedgeHang and the Roll all reachable
    -- from the top of a wall jump - and airborne.lua's wallJumpUsed flag is
    -- what stops the player chaining another one without touching ground.
    return "Airborne"
end

return WallJumpState
