---@omw-context player
--[[
    states/roll.lua

    Landing roll. Fall for at least a second, hold forward, tap Jump once in
    mid-air. That arms the roll and applies a Fortify Agility bonus; touch down
    and the landing becomes a recovery roll, refunding part of the fall damage.

    This is the "Roll" state the original states-not-finished/air.lua draft
    referenced but never built.

    ENTRY is owned by states/airborne.lua, not by this file - see the "LANDING
    ROLL" block there. The arming, the one-second fall gate and the Fortify all
    live up there; this state is entered only at touchdown, because
    state_manager plays a state's animation on ENTRY and entering while airborne
    would fire pwroll1 mid-fall.

    A COMMITTED ACTION. Once it starts:
      * it runs to ROLL_DURATION - only a knockdown, paralysis or death cuts it
        short, and the ground going away does not (rolling off a ledge finishes
        the roll),
      * the player travels forward on their own facing, not on the stick,
      * jump does nothing.
    All three come from one movement override - see the COMMITMENT block below.

    Always exits to Idle. Idle re-derives everything on its next tick, so an
    interrupted or ledge-bound roll still ends up in Airborne immediately.

    ANIMATION: "pwroll1", start/stop keys, registered in playerAnim.lua's
    GROUPS and ONE_SHOT_STATES. This file never calls the animation API
    itself - core/state_manager.lua's setState() choke point drives it.

    NO RAYCASTS, no teleports, no temporary objects. It reads stats, adjusts
    health, and holds one movement override for its duration - which is why
    "Roll" has to appear in main.lua's OVERRIDE_STATES.
]]--

local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local I = require('openmw.interfaces')

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

-- =============================================================================
-- COMMITMENT
--
-- The roll is a COMMITTED action: once it starts it runs to completion, the
-- player travels forward through it, and jump does nothing until it ends. Only
-- being knocked down or killed cuts it short.
--
-- HOW ALL THREE ARE ONE MECHANISM. I.Controls.overrideMovementControls(true)
-- suppresses the jump key AND stops the engine writing to self.controls, which
-- means this state must then write the movement itself. That single call is
-- therefore what makes the roll unjumpable, and writing controls.movement = 1
-- under it is what carries the player forward - engine-driven, so the camera
-- interpolates it, rather than the per-frame teleporting that made Shimmy
-- judder before it was rewritten the same way.
--
-- main.lua's OVERRIDE_STATES set must list "Roll" or its per-tick safety net
-- releases the override immediately, leaving the roll jumpable and stationary.
-- That set is the one place overrides are asserted from, and a state holding
-- one without being listed there is a bug the safety net will hide.
local FORWARD_DRIVE = 1.0

-- The interrupt set, in one call. types.Actor.canMove() returns false for a
-- dead, paralyzed OR knocked-down actor, which is exactly the list the roll is
-- allowed to be cut short by - and cheaper and more honest than testing
-- isDead() and getKnockedDown() separately and still missing paralysis.
local function interrupted()
    return not types.Actor.canMove(mwSelf)
end

-- Don't honour the interrupt for the first fraction of a second.
--
-- NOT the same thing as the ground grace this file used to have, which gated a
-- bail-out that no longer exists. This gates only the interrupt, and it is here
-- because of how this state is ENTERED: airborne.lua can hand over on the jump
-- animation's land text key, a frame or two before the engine has finished
-- resolving the landing. canMove() is documented as false for dead, paralyzed
-- and knocked-down actors, and a landing actor should be none of those - but if
-- it reads false for even one frame on entry, the roll ends on frame one, the
-- animation is cancelled before it is visible, and the symptom is "Roll does
-- nothing", which has cost this project several sessions to diagnose before.
--
-- One comparison to remove that entire failure mode. A knockdown genuinely
-- landing inside this window is still caught 0.1s later.
local INTERRUPT_GRACE = 0.1

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local timeInState = 0
local healthBefore = nil
local refundApplied = false

local function refundFraction()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / REFUND_SKILL_CAP))
    return REFUND_MIN + (REFUND_MAX - REFUND_MIN) * t
end

function RollState:enter(syncData)
    timeInState = 0
    refundApplied = false

    healthBefore = pendingHealthBefore
    pendingHealthBefore = nil

    -- Takes the jump key away and hands movement to this state. Released in
    -- exit(), which state_manager calls on every transition out, including the
    -- interrupted ones.
    I.Controls.overrideMovementControls(true)
end

function RollState:exit()
    healthBefore = nil
    refundApplied = false
    I.Controls.overrideMovementControls(false)
end

function RollState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- 0. The only permitted interrupt. Checked first so a knockdown mid-roll
    -- does not also get a refund applied on the same frame, and so the
    -- override is released by exit() before the engine starts the knockdown
    -- animation - a knocked-down actor with movement still overridden is how
    -- you get stuck on the floor.
    if timeInState > INTERRUPT_GRACE and interrupted() then
        return "Idle"
    end

    -- 0b. Forward transport. Written every frame because the override stops the
    -- engine populating self.controls at all, so a single write in enter()
    -- would be overwritten to zero on the next tick.
    --
    -- The direction is the character's own facing, not the input: the roll
    -- commits to where the player was already going, and reading the stick here
    -- would let them steer mid-roll or, by releasing it, stand still through
    -- the animation. sideMovement is pinned to zero for the same reason.
    mwSelf.controls.movement = FORWARD_DRIVE
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.jump = false

    -- Run speed, not walk. A roll is a fast recovery, and at walking pace the
    -- forward travel reads as a shuffle under the animation. Safe to set here:
    -- main.lua's throttle gate reads self.controls.run, but only while the
    -- active state is Idle, which it is not for the duration of this state.
    mwSelf.controls.run = true

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

    -- 2. NO GROUND CHECK. There used to be one here: if isGrounded went false
    -- mid-roll the state bailed to Airborne, so rolling off a ledge cut the
    -- animation. That is now explicitly unwanted - the roll is uninterruptible
    -- except by knockdown or death - and it was fragile anyway, needing a
    -- GROUND_GRACE window because airborne.lua can enter this state off the
    -- jump group's land text key a frame or two before the polled isGrounded
    -- catches up. Running to ROLL_DURATION needs no grace and no proxy for
    -- "have the feet actually landed"; the timer is the authority.
    --
    -- Rolling off a ledge therefore finishes the roll and hands to Idle, which
    -- sees !isGrounded on its first tick and returns Airborne immediately. One
    -- extra frame in Idle, and the animation is never cut.

    -- 3. Recovery window over. Always to Idle: Sprint no longer exists as a
    -- state (vanilla's run flag replaced it), so there is nothing to chain
    -- momentum into, and Idle re-derives everything on its next tick anyway -
    -- Airborne if the ground went away, Vault or Mantle if the roll ended
    -- facing something climbable.
    if timeInState >= ROLL_DURATION then
        return "Idle"
    end

    return nil
end

return RollState
