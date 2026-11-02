---@omw-context player
-- Ladder climb. Detects ladder statics by recordId.
--
-- The climb itself is a backend move (FLOW_Climb_Start / _Cancel), sent once
-- per direction change rather than one SnapTo event per frame. Every frame
-- while moving, the state re-checks what the backend cannot: that a ladder is
-- still in front, and, going up, that there is room overhead.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local BaseState = require('scripts/Flow/states/base_state')
local Anim = require('scripts/Flow/playerAnim')
local Body = require('scripts/Flow/core/body')
local Geom = require('scripts/Flow/core/geom')

local LadderState = BaseState.new("Ladder", {
    overrides = "all", suspend = true, anim = "loop",
})

local CLIMB_SPEED = 110.0      -- units/sec, up or down
local DETECT_REACH = 95.0      -- how far ahead to look for a ladder
local DETECT_HEIGHT = 70.0     -- cast from roughly chest height
local WALL_OFFSET = 28.0       -- how far to sit off the ladder face
local TOP_CLEARANCE = 40.0     -- headroom needed before stepping off the top
local EXIT_PUSH = 45.0         -- how far forward to place the player on exit
local GRIP_REACH = WALL_OFFSET + 30.0   -- re-probe reach while on the ladder
local HEAD_MARGIN = 12.0       -- crown clearance kept while climbing
local PROBE_INTERVAL = 0.1     -- entry probe rate while walking forward

local LADDER_IDS = {
    "ladder",
    "_lad_",
}

local RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door,
}

local function looksLikeLadder(obj)
    if not obj then return false end
    local id = obj.recordId
    if type(id) ~= "string" then return false end
    id = string.lower(id)
    for i = 1, #LADDER_IDS do
        if string.find(id, LADDER_IDS[i], 1, true) then return true end
    end
    return false
end

local nextProbe = 0

-- Offered by Idle every frame forward is held; probes at most PROBE_INTERVAL.
function LadderState:canEnter()
    local now = core.getRealTime()
    if now < nextProbe then return nil end
    nextProbe = now + PROBE_INTERVAL

    local origin = mwSelf.position + util.vector3(0, 0, DETECT_HEIGHT)
    local res = nearby.castRay(origin, origin + Geom.forward(mwSelf) * DETECT_REACH, RAY_OPTS)
    if not (res.hit and looksLikeLadder(res.hitObject)) then return nil end
    local flat = Geom.flat(res.hitNormal)
    if not flat then return nil end
    return { pos = res.hitPos, flat = flat }
end

local flat = nil      -- unit XY normal out of the ladder face
local climbDir = 0    -- what the backend is currently doing
local lastInput = 0

local function setClimb(dir)
    if dir == climbDir then return end
    climbDir = dir
    if dir == 0 then
        core.sendGlobalEvent('FLOW_Climb_Cancel', { actor = mwSelf })
    else
        core.sendGlobalEvent('FLOW_Climb_Start', { actor = mwSelf, speed = CLIMB_SPEED * dir })
    end
end

local function setClipFor(dir)
    if dir > 0 then Anim.setVariant("up")
    elseif dir < 0 then Anim.setVariant("down")
    else Anim.setVariant("idle") end
    Anim.replay()
end

local function ladderAhead(pos)
    local origin = pos + util.vector3(0, 0, DETECT_HEIGHT)
    local res = nearby.castRay(origin, origin - flat * GRIP_REACH, RAY_OPTS)
    return res.hit and looksLikeLadder(res.hitObject)
end

function LadderState:enter(plan)
    flat = plan.flat
    climbDir = 0
    lastInput = 0
    -- Without this the first clip came from pairs() order over the variants.
    Anim.setVariant("idle")

    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = util.vector3(plan.pos.x, plan.pos.y, mwSelf.position.z) + flat * WALL_OFFSET,
        rotation = util.transform.rotateZ(math.atan2(flat.x, flat.y) + math.pi),
    })
end

function LadderState:exit()
    setClimb(0)
    flat = nil
end

function LadderState:update(dt, syncData, inputData)
    -- Drop off deliberately.
    if inputData.crouch then return "Airborne" end

    local input = 0
    if inputData.moveVector.y > 0.1 then input = 1
    elseif inputData.moveVector.y < -0.1 then input = -1 end

    if input ~= lastInput then
        lastInput = input
        setClipFor(input)
    end

    local pos = mwSelf.position
    local dir = input

    if dir > 0 then
        local headOrigin = pos + util.vector3(0, 0, DETECT_HEIGHT + TOP_CLEARANCE)
        if not nearby.castRay(headOrigin, headOrigin - flat * EXIT_PUSH, RAY_OPTS).hit then
            -- Nothing above the lip: step off onto the top.
            core.sendGlobalEvent('FLOW_SnapTo', {
                actor = mwSelf,
                position = pos + util.vector3(0, 0, TOP_CLEARANCE) - flat * EXIT_PUSH,
                rotation = mwSelf.rotation,
            })
            return "Idle"
        end
        -- A wall that carries on past the ladder is not climbable, and a
        -- teleport climb would go straight through a ceiling.
        local crown = pos + util.vector3(0, 0, Body.height())
        if not ladderAhead(pos)
           or nearby.castRay(crown, crown + util.vector3(0, 0, HEAD_MARGIN + CLIMB_SPEED * dt), RAY_OPTS).hit then
            dir = 0
        end
    elseif dir < 0 then
        if syncData.isGrounded then return "Idle" end
        -- The ladder ends above the floor: let go.
        if not ladderAhead(pos) then return "Airborne" end
    end

    setClimb(dir)
end

return LadderState
