---@omw-context global
--[[
    global/flow_amf_backend.lua

    Global-script side of FLOW. Local (player) scripts cannot call
    GameObject:teleport() - that is a global-script-only method - so every
    state that needs to physically move the player sends an event here and
    this file performs the move.

    MOVEMENT MODEL: straight per-tick teleports along a precomputed path,
    exactly as in the original working build. This deliberately does NOT
    run a per-tick collision "cage" (the six-raycast bounding-box clamp
    ported from Hookshot's tpWithCollision).

    That cage was tried here and removed again, twice, for two separate
    reasons - recording both so it doesn't get reintroduced a third time:

      1. Applied to the whole move, it clamps to ~0. Vault/Mantle both
         BEGIN flush against the exact obstacle they are meant to cross,
         so a forward/upward ray from the cage hits it on tick one and
         allows zero distance. Symptom: state fires, animation plays,
         player doesn't move.

      2. Applied with Hookshot-style grace frames + a stuck-failsafe, it
         still killed the move - because Hookshot measures its
         stuck threshold over a 50ms window (PREV_POS_UPDATE_DT), not
         per tick. Reusing its 3-5 unit threshold per TICK meant a normal
         Vault (~2-3 units of travel per frame at 60fps) counted as
         "stuck" within a few frames and self-cancelled almost
         immediately. Same visible symptom as (1), different cause.

    These paths do not need per-tick collision anyway: their endpoints are
    validated before the move ever starts (Vault raycast-profiles the path
    and computes an apex clearing the highest point on it; Mantle's target
    comes from the Sensor's own top-surface probe plus a landing buffer).
    If clipping shows up, the fix belongs in that pre-validation, not in
    per-tick clamping that cancels the movement it is meant to protect.
]]--

local core = require('openmw.core')
local util = require('openmw.util')
local types = require('openmw.types')
local storage = require('openmw.storage')
local world = require('openmw.world')

local ActiveMoves = {}

-- =============================================================================
-- NO COLLISION CAGE HERE - AND IT CANNOT LIVE HERE
--
-- A previous version added `require('openmw.nearby')` to this file for a
-- per-tick cage. openmw.nearby is a LOCAL-script module; it does not exist in
-- the global context. The require failed at load with
--     Can't start Global[global/flow_amf_backend.lua];
--     Lua error: module not found: openmw.nearby
-- which meant this ENTIRE SCRIPT never started. Every FLOW_Vault_Start,
-- FLOW_Mantle_Start and FLOW_SnapTo event went to a handler that did not
-- exist, so Vault, Mantle and Shimmy fired their states and played their
-- animations while nothing ever moved the player. LedgeHang appeared to
-- survive only because its Levitate effect is applied player-side.
--
-- Raycasting is not available in this context at all, so any collision work
-- must be done PLAYER-SIDE before a move starts - which is where the
-- destination validation in vault.lua/mantle.lua already lives. Do not
-- reintroduce a require of openmw.nearby, openmw.camera, or openmw.input in
-- this file.
-- =============================================================================

local function bezier(t, p0, p1, p2)
    local u = 1 - t
    local tt = t * t
    local uu = u * u
    return (p0 * uu) + (p1 * 2 * u * t) + (p2 * tt)
end

-- =============================================================================
-- MOVE HANDLERS
-- =============================================================================

local function onMantleStart(data)
    local id = data.actor.id
    ActiveMoves[id] = {
        type = "Mantle",
        actor = data.actor,
        cageFrom = data.cageFrom,
        startPos = data.startPos,
        risePos = data.risePos,
        targetPos = data.targetPos,
        duration = data.duration,
        phase = 1,
        progress = 0
    }
end

local function onVaultStart(data)
    local id = data.actor.id
    ActiveMoves[id] = {
        type = "Vault",
        actor = data.actor,
        cageFrom = data.cageFrom,
        startPos = data.startPos,
        apexPos = data.apexPos,
        landPos = data.landPos,
        duration = data.duration,
        progress = 0
    }
end

-- Ballistic launch: an initial velocity integrated against gravity every
-- tick, rather than a lerp to a precomputed point. Used by WallBoost (the
-- double-jump reimplementation). Ends on landing, on a real collision, or at
-- maxDuration - not on a fixed timer, so the arc resolves naturally.
--
-- Gravity matches Hookshot's derived value so the two mods' fall speeds agree
-- rather than each inventing its own.
local M_TO_UNITS = 400
local GRAVITY = 9.80665 * M_TO_UNITS

local function onBoostStart(data)
    local id = data.actor.id
    -- v0 needed to reach apexHeight: v = sqrt(2*g*h). Derived here so GRAVITY
    -- lives in exactly one place.
    local v0z = math.sqrt(2 * GRAVITY * data.apexHeight)
    local push = data.pushVelocity or util.vector3(0, 0, 0)

    ActiveMoves[id] = {
        type = "Boost",
        actor = data.actor,
        velocity = util.vector3(push.x, push.y, v0z),
        maxDuration = data.maxDuration or 1.5,
        elapsed = 0,
    }
end

local function onMoveCancel(data)
    if data.actor then
        ActiveMoves[data.actor.id] = nil
    end
end

-- Instant teleport (used by LedgeHang's initial grab-snap). Direct, for
-- the same reason as above - the snap target is a ledge lip the Sensor
-- has already validated, and running a cage against the wall the player
-- is grabbing clamps the snap to nothing.
local function onSnapTo(data)
    local actor = data.actor
    if actor and actor:isValid() then
        local cell = data.cell or actor.cell
        local rot = data.rotation or actor.rotation

        actor:teleport(cell, data.position, {
            rotation = rot,
            onGround = false
        })
    end
end

local function onUpdate(dt)
    for id, move in pairs(ActiveMoves) do
        local actor = move.actor

        if not actor:isValid() then
            ActiveMoves[id] = nil
        else
            local nextPos
            if move.type == "Mantle" then
                local phase1Dur = move.duration * 0.7
                local phase2Dur = move.duration * 0.3

                local currentDur = (move.phase == 1) and phase1Dur or phase2Dur

                move.progress = move.progress + (dt / currentDur)

                local currentStart = (move.phase == 1) and move.startPos or move.risePos
                local currentDest  = (move.phase == 1) and move.risePos or move.targetPos

                if move.progress >= 1.0 then
                    nextPos = currentDest
                    if move.phase == 1 then
                        move.phase = 2
                        move.progress = 0
                    else
                        ActiveMoves[id] = nil
                    end
                else
                    -- Simple Linear Interpolation for stability
                    nextPos = currentStart + (currentDest - currentStart) * move.progress
                end
            elseif move.type == "Boost" then
                move.elapsed = move.elapsed + dt
                move.velocity = move.velocity - util.vector3(0, 0, GRAVITY * dt)
                nextPos = actor.position + move.velocity * dt

                -- Ground detection is done PLAYER-side (states/wall_boost.lua
                -- watches syncData.isGrounded and cancels), because raycasting
                -- is unavailable in a global script - see the note at the top
                -- of this file.

                if move.elapsed >= move.maxDuration then
                    ActiveMoves[id] = nil
                end

            elseif move.type == "Vault" then
                move.progress = move.progress + (dt / move.duration)
                if move.progress >= 1.0 then
                    nextPos = move.landPos
                    ActiveMoves[id] = nil
                else
                    nextPos = bezier(move.progress, move.startPos, move.apexPos, move.landPos)
                end
            end

            if nextPos then
                actor:teleport(actor.cell, nextPos, { onGround = false, rotation = actor.rotation })
            end
        end
    end
end

return {
    interfaceName = "FLOW_AMF_Global",
    interface = { version = 1 },
    engineHandlers = {
        onUpdate = onUpdate
    },
    eventHandlers = {
        FLOW_Mantle_Start = onMantleStart,
        FLOW_Vault_Start = onVaultStart,
        FLOW_Mantle_Cancel = onMoveCancel,
        FLOW_Vault_Cancel = onMoveCancel,
        FLOW_SnapTo = onSnapTo,
        FLOW_Boost_Start = onBoostStart,
        FLOW_Boost_Cancel = onMoveCancel,
    }
}
