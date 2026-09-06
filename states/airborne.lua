---@omw-context player
local BaseState = require('states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local input = require('openmw.input')
local async = require('openmw.async')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local RollState = require('states/roll')
local InputManager = require('core/input')
local VaultState = require('states/vault')

local AirborneState = BaseState.new("Airborne")

-- ==============================================
-- LANDING ROLL
-- ==============================================
-- Sequence: airborne -> hold forward -> tap Jump -> armed, with a Fortify
-- Agility bonus, until touchdown -> land and roll -> back to running.
--
-- ONE mid-air tap, matching surfAnimations. The jump press that launches the
-- jump does not count: Idle is still the active state on that frame, so
-- isActive is false and the handler ignores it. That is the same filtering
-- surfAnimations gets from its animation.isPlaying("jump") gate, and it is
-- what makes the gesture read as "jump, then tap" rather than needing a
-- tracked sequence.
--
-- INPUT: an engine trigger handler, not polled state. Every previous
-- version reconstructed press/release edges by comparing
-- input.isActionPressed(ACTION.Jump) against the last frame's value, and it
-- was never reliable - a tap completed inside a single frame is simply
-- invisible to polling, and the release half of each cycle fought the
-- jump-HELD gate that Vault/Mantle/LedgeHang depend on.
--
-- input.registerTriggerHandler receives the engine's own input event
-- instead, so no press can be dropped between frames and nothing needs to
-- be reconstructed. This is the method ErnGlider/surfAnimations uses for
-- the same gesture; its handler body is gated on being mid-jump, which is
-- also proof the Jump trigger does fire while airborne.
--
-- Costs nothing per frame - the handler runs only when the key is actually
-- pressed.
--
-- The arm does NOT expire: the gesture behaves identically on a short hop
-- and a long fall.
--
-- Arming lives here rather than in roll.lua because state_manager plays a
-- state's animation on ENTRY - entering Roll while still in the air would
-- fire pwroll1 mid-fall. Roll is therefore still entered at touchdown; only
-- the arming and the Fortify happen up here.
--
-- Cost while airborne is a few boolean/number comparisons per frame and
-- nothing at all while grounded. No raycasts, no allocations.
local AGILITY_BONUS = 70

-- How far below hand height the ledge lip may still be and count as
-- grabbable. Pure forgiveness margin - at 0 the grab can never move the
-- player downward at all, which reads as slightly too strict in play.
local LEDGE_GRAB_TOLERANCE = 20

-- Forward stick/key threshold at the moment of the tap, mirroring
-- surfAnimations' deadzone treatment of pself.controls.movement.
local FORWARD_DEADZONE = 0.1

local armed = false
local armTimer = 0
local isActive = false          -- is Airborne the current state? gates the
                                 -- module-scope trigger handler, which fires
                                 -- regardless of which state is running
local agilityApplied = false

-- NOTE: activeEffects:modify() on a fortify effect is cosmetic on its own -
-- the OpenMW docs are explicit that fortify-attribute active effects "have
-- no practical effect of their own, and must be paired with explicitly
-- modifying the target stat". So the stat modifier is the part that does
-- the work; the activeEffects entry exists so it also reads as a real
-- Fortify Agility in the magic menu rather than an unexplained stat jump.
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

-- =============================================================================
-- JUMP TRIGGER HANDLER
--
-- Registered once at module scope and fires for every Jump input event, in
-- any state - hence the isActive gate. A single mid-air tap with forward
-- held arms the roll.
--
-- Note this needs NO release edge, which is why it also fixes the conflict
-- the polled version had: completing the old gesture meant letting go of
-- jump, and Vault/LedgeHang/Mantle are gated on jump being HELD. The player
-- can now hold jump throughout and keep all three available.
--
-- DIRECTION READ: uses InputManager's cached moveVector, NOT a live
-- mwSelf.controls.movement read. This handler runs via async:callback at an
-- unspecified point relative to onUpdate, so a direct controls read can catch
-- the value before the engine has populated it for this frame - which
-- presented as "holding forward makes the roll fail", the exact opposite of
-- what the gate intends. InputManager samples once per frame at a known
-- point, so the cached value is at worst one frame old and always coherent.
--
-- surfAnimations reads controls.movement live and gets away with it because
-- its FORWARD branch deliberately does nothing - a bad read there just falls
-- through to its glider default. FLOW needs the read to be correct to arm at
-- all, so it cannot rely on the same assumption.
-- =============================================================================
input.registerTriggerHandler("Jump", async:callback(function()
    -- Input triggers can still fire while the world is paused, but main.lua
    -- now runs on onUpdate, which does not. Without this guard a Jump press
    -- in a menu could bank taps against a stale isActive/moveVector snapshot
    -- and pre-arm a roll from outside gameplay.
    -- NOTE THE PARENTHESES. core.isWorldPaused is a FUNCTION; referencing it
    -- without calling yields the function object, which is truthy, so
    -- `if core.isWorldPaused then return end` returned on every single
    -- invocation and the roll could never arm. This one missing pair of
    -- brackets accounted for the entire "Roll never fires" symptom.
    if core.isWorldPaused() then return end
    if not isActive or armed then return end

    -- Forward must be held at the tap.
    if InputManager.intents.moveVector.y <= FORWARD_DEADZONE then return end

    armed = true
    armTimer = 0
    applyAgility(true)
end))

-- =============================================================================
-- LANDING FAST PATH (vanilla 'jump' text keys)
--
-- syncData.isGrounded is still the authority for landing - it drives seven
-- call sites across the mod and is known to work. This handler is purely an
-- EARLIER signal: the engine fires the jump group's land/stop text key on
-- the exact frame the animation says the feet are down, which can precede
-- the polled isGrounded flip.
--
-- Deliberately additive rather than a replacement. The exact text-key names
-- in a given animation set are not guaranteed ('jump: land' vs 'jump: stop'
-- vs neither, and replacer .kf files vary), and if landing detection
-- depended solely on a key that never fires, the player would be stranded
-- in Airborne permanently. Suffix-matched so it tolerates both spellings;
-- if it never fires, behaviour is exactly what it was before.
-- =============================================================================
local landedSignal = false

-- The `if` above is the guard: addTextKeyHandler is optional across versions,
-- so its ABSENCE is tested directly. No pcall - if the registration itself
-- fails that is a bug worth seeing, not a silently lost landing fast path.
if I.AnimationController and I.AnimationController.addTextKeyHandler then
    I.AnimationController.addTextKeyHandler('jump', function(groupname, key)
            -- Naive suffix matching on 'stop' is wrong: the vanilla jump
            -- group also emits 'jump: loop stop', which fires when the
            -- falling loop ends and is NOT reliably touchdown. Accept the
            -- land key, and the final stop key, but never the loop's.
            if string.sub(key, -4) == 'land' then
                landedSignal = true
            elseif string.sub(key, -4) == 'stop' and string.sub(key, -9) ~= 'loop stop' then
                landedSignal = true
            end
    end)
end

-- Only called when the debug HUD is on, so the string build costs nothing
-- in a normal session.
function AirborneState.getRollDebug()
    if armed then
        return string.format("ROLL: ARMED %.2f%s", armTimer,
            landedSignal and " LANDKEY" or "")
    end
    return string.format("ROLL: idle fwd=%.2f", InputManager.intents.moveVector.y)
end

-- Health sampled while still airborne, i.e. before the engine applies fall
-- damage. states/roll.lua compares against this to work out how much was
-- actually lost, without having to assume when the engine applies it.
local healthBeforeLanding = nil

function AirborneState:enter(syncData)
    isActive = true
    healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
    -- Fresh airborne period starts unarmed.
    armed = false
    armTimer = 0
    landedSignal = false
end

-- Safety net: the Fortify is normally removed on landing or on timeout, but
-- if this state is left by any other route (death, forced reset, a hand-off
-- to Vault/Mantle/LedgeHang mid-arm) the bonus must not be left stranded on
-- the actor.
function AirborneState:exit()
    isActive = false
    applyAgility(false)
end

function AirborneState:update(dt, syncData, inputData)
    -- 1. Obstacle Interaction (Mid-Air) - jump-gated, matching Idle
    if inputData.jump then
        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked() then
            return "Vault"
        end

        -- B. Ledge Hang (High/Overhead obstacles)
        if SensorExt.data.interaction == "LedgeHang" and SensorExt.data.targetPos then
            -- Geometry check, replacing the old smoothed-velocity gate
            -- ("only grab if vertical velocity < 150"). That was asking
            -- "am I rising fast?" as a proxy for the question it actually
            -- cared about: "is this lip still above me, or have I already
            -- gone past it?" Position answers that exactly and with no
            -- smoothing lag - and the lip position is already sitting in
            -- SensorExt.data from the scan that just reported the hang.
            --
            -- Requiring the lip to be above hand height means the grab can
            -- only ever pull the player UP, never yank them back down to a
            -- ledge they have already cleared.
            local handsZ = mwSelf.position.z + SensorExt.GRAB_HEIGHT - LEDGE_GRAB_TOLERANCE
            if SensorExt.data.targetPos.z > handsZ then
                return "LedgeHang"
            end
        end

        -- C. Mantling (Medium obstacles)
        if Sensor.data.interaction == "Mantle" then
            return "Mantle"
        end
    end

    -- Touchdown. isGrounded remains the authority for leaving this state;
    -- the animation key is honoured ONLY when a roll is armed, i.e. as a
    -- latency shortcut for the one transition where a frame matters. Scoped
    -- this way, a text key that fires at the wrong moment (a replacer .kf
    -- with different keys, an unexpected 'stop') can at worst start a roll a
    -- little early - it can never pull the player out of the air into Idle.
    local touchedDown = syncData.isGrounded or (landedSignal and armed)

    -- 1b. Airborne bookkeeping. Tap counting itself happens in the trigger
    -- handler above, not here - this only tracks the pre-impact health
    -- sample and ages the debug timer.
    if not touchedDown then
        healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
        if armed then
            armTimer = armTimer + dt   -- debug readout only; the arm never expires
        end
    end

    -- 2. Landing Logic
    if touchedDown then
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

    return nil
end

return AirborneState