---@omw-context player
--[[
    states/roll.lua

    Landing roll. While airborne and holding forward, double-tap Jump (two
    full press+release cycles inside a one-second budget). That arms a
    one-second window and applies a Fortify Agility bonus; touch down inside
    the window and the landing becomes a recovery roll, refunding part of
    the fall damage.

    This is the "Roll" state the original states-not-finished/air.lua draft
    referenced but never built.

    ENTRY is owned by states/airborne.lua, not by this file - see the
    "LANDING ROLL" block there. The arming, the tap counting and the Fortify
    all live up there; this state is entered only at touchdown, because
    state_manager plays a state's animation on ENTRY and entering while
    airborne would fire pwroll1 mid-fall.

    Exits to Sprint when forward is still held so momentum chains, otherwise
    to Idle.

    ANIMATION: "pwroll1", start/stop keys, registered in playerAnim.lua's
    GROUPS and ONE_SHOT_STATES. This file never calls the animation API
    itself - core/state_manager.lua's setState() choke point drives it.

    NO RAYCASTS, no teleports, no temporary objects, no engine overrides.
    This state only reads stats and adjusts health.
]]--

local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')

local RollState = BaseState.new("Roll")

-- ==============================================
-- CONFIGURATION
-- ==============================================
local ROLL_DURATION = 0.45      -- recovery window before handing back to
                                 -- Idle/Sprint. Long enough to read as a
                                 -- deliberate action, short enough not to
                                 -- feel like a stun.

-- Fraction of the fall damage refunded, scaled by Acrobatics. A character
-- with 0 Acrobatics gets MIN, one at 100+ gets MAX. Never a full refund -
-- a roll should reward skill, not delete falling as a threat.
local REFUND_MIN = 0.25
local REFUND_MAX = 0.75
local REFUND_SKILL_CAP = 100.0

-- Engine fall damage is applied by OpenMW itself, and its ordering relative
-- to this state's first frame isn't guaranteed. Rather than assume, watch
-- for the health drop across a short window and refund once when it shows
-- up. If no drop ever appears (a fall too short to hurt), nothing is
-- refunded and the roll is purely cosmetic/momentum.
local DAMAGE_WATCH_WINDOW = 0.25

-- ==============================================
-- ENTRY DATA (set by states/airborne.lua)
-- ==============================================
local pendingHealthBefore = nil

function RollState.setLandingData(healthBefore)
    pendingHealthBefore = healthBefore
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local GROUND_GRACE = 0.20   -- how long to wait for isGrounded to catch up
                             -- with the animation's land key before giving
                             -- up and treating this as a genuine mid-air
                             -- entry

local timeInState = 0
local healthBefore = nil
local refundApplied = false
local groundConfirmed = false

local function refundFraction()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / REFUND_SKILL_CAP))
    return REFUND_MIN + (REFUND_MAX - REFUND_MIN) * t
end

function RollState:enter(syncData)
    timeInState = 0
    refundApplied = false
    groundConfirmed = syncData and syncData.isGrounded or false

    healthBefore = pendingHealthBefore
    pendingHealthBefore = nil
end

function RollState:exit()
    healthBefore = nil
    refundApplied = false
end

function RollState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- 1. Damage refund - watch for the engine's fall damage to land, then
    -- give part of it back. Done once.
    if not refundApplied and healthBefore and timeInState <= DAMAGE_WATCH_WINDOW then
        local hp = types.Actor.stats.dynamic.health(mwSelf)
        local lost = healthBefore - hp.current

        if lost > 0 then
            -- Don't resurrect: if the fall was fatal, leave it fatal.
            if hp.current > 0 then
                local refund = lost * refundFraction()
                hp.current = math.min(hp.base, hp.current + refund)
            end
            refundApplied = true
        end
    end

    -- 2. Interrupt: if the ground vanishes again (rolled off a ledge),
    -- don't hold the player in a recovery animation mid-air.
    --
    -- GRACE: airborne.lua can enter this state off the vanilla jump group's
    -- land/stop text key, which fires slightly BEFORE the polled isGrounded
    -- flips. Without a grace window this check saw "not grounded" on frame
    -- one, bailed straight back to Airborne, and state_manager's stopCurrent
    -- cancelled pwroll1 before it was visible - the state would appear in
    -- the console with no animation. Only start honouring the check once the
    -- ground has actually been confirmed at least once.
    if syncData.isGrounded then
        groundConfirmed = true
    elseif groundConfirmed or timeInState > GROUND_GRACE then
        return "Airborne"
    end

    -- 3. Recovery window over - momentum preservation, matching the
    -- Vault/Mantle convention: holding forward hands to Sprint, which
    -- bounces straight back to Idle on its own if the sprint key isn't
    -- actually held (see states/sprint.lua).
    if timeInState >= ROLL_DURATION then
        if inputData.moveVector.y > 0 then
            return "Idle"
        end
        return "Idle"
    end

    return nil
end

return RollState
