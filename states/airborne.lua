---@omw-context player
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

-- =============================================================================
-- ROLL FALL GATE
--
-- A roll now needs a real fall behind it. Below this, a tap arms nothing, so
-- hopping on the spot or clearing a step cannot produce a landing roll.
--
-- Measured as time AIRBORNE, not time descending. "One second falling" is the
-- requirement, and airborne time is the honest way to meet it: descent time
-- would need a vertical velocity, which engine_sync deliberately no longer
-- computes (its 3-frame smoothing buffer was removed when the LedgeHang gate
-- stopped needing it), and re-adding a smoothed velocity to answer a threshold
-- question would undo that. A jump that has been in the air a second has
-- always either peaked or never left the ground far.
local ROLL_MIN_AIR_TIME = 1.0

-- =============================================================================
-- WALL JUMP WINDOW AND REACH
--
-- The second jump has to come SOON after the first, which is what makes this a
-- double-jump off a wall rather than a free mid-fall boost available at any
-- height. It also separates this gesture from the Roll's cleanly: a wall jump
-- is only offered in the first WALL_JUMP_WINDOW seconds airborne and the Roll
-- only after ROLL_MIN_AIR_TIME, so one tap can never satisfy both and no
-- priority rule between them is needed.
local WALL_JUMP_WINDOW = 0.45

-- Extra reach past the player's own half-width when testing for wall contact.
-- Small on purpose: "in contact with the wall" should mean touching it, and a
-- generous reach lets the player jump off a wall they are visibly clear of.
local WALL_CONTACT_MARGIN = 14.0

-- Height up the body to cast from. Torso, so a knee-high crate is not a wall
-- and a chest-high railing is.
local WALL_CONTACT_HEIGHT = 70.0

local armed = false
local timeAirborne = 0          -- seconds since this airborne period began;
                                 -- gates both the Roll and the WallJump
local wallJumpUsed = false      -- one wall jump per airborne period. NOT reset
                                 -- in enter(): WallJump hands back to Airborne,
                                 -- which would re-enter this state and re-arm
                                 -- the move, giving an unlimited wall climb.
                                 -- Cleared on touchdown instead.
local isActive = false          -- is Airborne the current state? gates the
                                 -- module-scope trigger handler, which fires
                                 -- regardless of which state is running
local wallJumpRequested = false -- set by the trigger handler, consumed by
                                 -- update(). A handler cannot return a state
                                 -- name; only update() can.
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
-- WALL CONTACT
--
-- Called ONLY from the Jump trigger handler, never per frame. That is the whole
-- performance argument for this feature: wall detection is a question you only
-- need answered at the instant the player asks for a wall jump, so there is no
-- per-frame side-scan and no always-on sensor to pay for. The cost while
-- airborne stays what it was - a couple of additions.
--
-- Acrobatics Expansion answers the same question with eight rays fanned across
-- the WORLD axes at a fixed height and a flat 50-unit reach. Four
-- player-relative rays with an early return is strictly less work for a better
-- answer: forward is tested first because a player who just jumped into a wall
-- is almost always facing it, so the common case costs ONE ray, and the reach
-- is derived from the actor's own width rather than a constant that is too
-- generous for a Bosmer and too tight for a Nord.
--
-- getBoundingBox() is the idea worth taking from that mod. It returns the real
-- axis-aligned box in world coordinates, so halfSize.x is this character's
-- actual half-width - beast races, scaled bodies and any future body mod all
-- come out right without a table of per-race numbers.
local WALL_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door
                    + nearby.COLLISION_TYPE.HeightMap
}

local function wallContact()
    local box = mwSelf:getBoundingBox()
    -- halfSize.x and .y are equal for an upright capsule; max() is defence
    -- against a box that is not, at the cost of one comparison.
    local halfWidth = math.max(box.halfSize.x, box.halfSize.y)
    local reach = halfWidth + WALL_CONTACT_MARGIN

    local pos = mwSelf.position
    local origin = util.vector3(pos.x, pos.y, pos.z + WALL_CONTACT_HEIGHT)

    local yaw = mwSelf.rotation:getYaw()
    local fwd = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
    local right = util.vector3(-fwd.y, fwd.x, 0)

    -- Forward, then the two sides, then behind. Ordered by likelihood so the
    -- early return does the most good.
    for i = 1, 4 do
        local dir
        if i == 1 then dir = fwd
        elseif i == 2 then dir = right
        elseif i == 3 then dir = -right
        else dir = -fwd end

        local res = nearby.castRay(origin, origin + dir * reach, WALL_RAY_OPTS)
        -- A walkable surface is a floor or a ramp, not a wall. Same slope
        -- threshold core/sensor.lua uses to qualify a vaultable face, so the
        -- two detectors agree about what counts as vertical.
        if res.hit and res.hitNormal and res.hitNormal.z < Sensor.WALKABLE_SLOPE_Z then
            return true
        end
    end

    return false
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
    if not isActive then return end

    -- WALL JUMP, first. The two gestures are separated by time rather than by
    -- priority - this branch can only fire inside WALL_JUMP_WINDOW and the Roll
    -- only after ROLL_MIN_AIR_TIME - so the order here is presentation, not a
    -- tie-break. The raycast is last in the chain deliberately: every cheap
    -- reason to refuse is checked before anything is cast.
    if not wallJumpUsed
       and not wallJumpRequested
       and timeAirborne <= WALL_JUMP_WINDOW
       and Settings.stateEnabled("WallJump")
       and wallContact() then
        wallJumpUsed = true
        wallJumpRequested = true
        return
    end

    if armed then return end

    -- Arming has a side effect on the actor - a Fortify Agility that lasts
    -- until touchdown - so this is checked here rather than relying on the
    -- state manager refusing the Roll transition later. Refusing at the
    -- transition would leave the fortify applied for the whole descent and
    -- removed by exit() with no roll to show for it.
    if not Settings.stateEnabled("Roll") then return end

    -- A real fall has to be underway. This is the gate that stops a hop or a
    -- single step down from offering a landing roll.
    if timeAirborne < ROLL_MIN_AIR_TIME then return end

    -- Forward must be held at the tap.
    if InputManager.intents.moveVector.y <= FORWARD_DEADZONE then return end

    armed = true
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
    -- Air time is shown on both branches because it is now the gate for both
    -- moves: a wall jump is only offered below WALL_JUMP_WINDOW and a roll only
    -- above ROLL_MIN_AIR_TIME, so "why did nothing happen" is almost always
    -- answered by this number.
    local wj = wallJumpUsed and " WJ-used"
        or (timeAirborne <= WALL_JUMP_WINDOW and " WJ-ready" or "")

    if armed then
        return string.format("ROLL: ARMED air=%.2f%s%s", timeAirborne,
            landedSignal and " LANDKEY" or "", wj)
    end
    return string.format("ROLL: idle air=%.2f fwd=%.2f%s", timeAirborne,
        InputManager.intents.moveVector.y, wj)
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
    timeAirborne = 0
    wallJumpRequested = false
    landedSignal = false

    -- wallJumpUsed is deliberately NOT cleared here. WallJump exits back into
    -- this state, so clearing it on entry would re-arm the move at the top of
    -- every wall jump and turn the feature into an unlimited vertical climb.
    -- Touchdown clears it - see update().
    --
    -- Resetting timeAirborne here does mean a wall jump restarts the Roll's
    -- fall clock, which is correct: after the launch the player is falling from
    -- a new apex, and that fall is the one the roll should be measured against.
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
    timeAirborne = timeAirborne + dt

    -- 0. Wall jump, decided in the trigger handler on the keypress. Consumed
    -- before anything else so a wall jump is not lost to a Vault or a LedgeHang
    -- that happens to be detected on the same frame - the player pressed jump
    -- next to a wall and this is the move they asked for.
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
            --
            -- Measured against GRAB_MIN_HEIGHT, the floor of sensor_ext's catch
            -- band, not against GRAB_HEIGHT. GRAB_HEIGHT is where the WALL ray
            -- is cast, which sits deliberately below the band; reading it here
            -- measured hands 10 units lower than they are and let the grab
            -- reach very slightly downwards.
            --
            -- The band makes this check nearly redundant - updateLedgeHang runs
            -- in the same tick from the same position and cannot report a lip
            -- below its own floor. It is kept because it is two comparisons,
            -- and because it is the only line that would notice if the band
            -- floor were ever lowered past the point where a grab pulls down.
            local handsZ = mwSelf.position.z + SensorExt.GRAB_MIN_HEIGHT - LEDGE_GRAB_TOLERANCE
            if SensorExt.data.targetPos.z > handsZ then
                return "LedgeHang"
            end
        end

        -- C. Mantling (Medium obstacles)
        if Sensor.data.interaction == "Mantle" and not MantleState.isBlocked(Sensor.data.targetPos) then
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

    -- 1b. Airborne bookkeeping. Arming happens in the trigger handler above,
    -- not here; this only keeps the pre-impact health sample fresh so
    -- states/roll.lua can work out how much the engine took off.
    --
    -- The arm timer that used to be aged here is gone. It existed only to feed
    -- the debug string, which now reports timeAirborne - the number that
    -- actually gates both moves - so the old one was incrementing a value
    -- nothing read.
    if not touchedDown then
        healthBeforeLanding = types.Actor.stats.dynamic.health(mwSelf).current
    end

    -- 2. Landing Logic
    if touchedDown then
        landedSignal = false
        -- Feet on the ground: the wall jump is available again. This is the
        -- only place it is cleared, which is what makes it one per airborne
        -- period rather than one per entry into this state.
        wallJumpUsed = false
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