---@omw-context global
-- Movement backend. Global context: teleport only, no raycasts.
local util = require('openmw.util')

local ActiveMoves = {}

local function bezier(t, p0, p1, p2)
    local u = 1 - t
    local tt = t * t
    local uu = u * u
    return (p0 * uu) + (p1 * 2 * u * t) + (p2 * tt)
end

local function onMantleStart(data)
    local id = data.actor.id
    ActiveMoves[id] = {
        type = "Mantle",
        actor = data.actor,
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
        startPos = data.startPos,
        apexPos = data.apexPos,
        landPos = data.landPos,
        duration = data.duration,
        progress = 0
    }
end

local M_TO_UNITS = 400
local GRAVITY = 9.80665 * M_TO_UNITS

local function onBoostStart(data)
    local id = data.actor.id
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

-- Vertical-only hop: drives Z on a curve, leaves X/Y to the engine.
local function onHopStart(data)
    local id = data.actor.id
    ActiveMoves[id] = {
        type = "Hop",
        actor = data.actor,
        startZ = data.actor.position.z,
        rise = data.rise,
        duration = data.duration,
        elapsed = 0,
    }
end

local function onMoveCancel(data)
    if data.actor then
        ActiveMoves[data.actor.id] = nil
    end
end

local MAX_SNAP_DISTANCE = 600

local function onSnapTo(data)
    local actor = data.actor
    if not (actor and actor:isValid()) then return end

    local pos = data.position
    if not pos then
        print("[FLOW:Backend] SnapTo refused: nil position")
        return
    end

    local dist = (pos - actor.position):length()
    if dist > MAX_SNAP_DISTANCE then
        print(string.format(
            "[FLOW:Backend] SnapTo refused: %.0f units is beyond MAX_SNAP_DISTANCE (%d) - " ..
            "almost certainly a stale or cross-cell coordinate",
            dist, MAX_SNAP_DISTANCE))
        return
    end

    local cell = data.cell or actor.cell
    local rot = data.rotation or actor.rotation

    actor:teleport(cell, pos, {
        rotation = rot,
        onGround = false
    })
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
                    nextPos = currentStart + (currentDest - currentStart) * move.progress
                end
            elseif move.type == "Hop" then
                move.elapsed = move.elapsed + dt
                local t = math.min(1.0, move.elapsed / move.duration)
                local p = actor.position
                -- X/Y read live, so engine movement and collision still apply.
                nextPos = util.vector3(p.x, p.y, move.startZ + move.rise * t * (2 - t))
                if t >= 1.0 then ActiveMoves[id] = nil end

            elseif move.type == "Boost" then
                move.elapsed = move.elapsed + dt
                move.velocity = move.velocity - util.vector3(0, 0, GRAVITY * dt)
                nextPos = actor.position + move.velocity * dt

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
        FLOW_Hop_Start = onHopStart,
        FLOW_Hop_Cancel = onMoveCancel,
    }
}
