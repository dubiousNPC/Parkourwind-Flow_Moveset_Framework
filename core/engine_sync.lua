---@omw-context player
--[[
    core/engine_sync.lua

    types.Actor gives runSpeed/walkSpeed - capability stats derived from the
    Speed attribute, NOT current motion - so this module synthesises what FLOW
    actually consumes by differencing position across frames.

    CORRECTION, AND AN OPEN QUESTION. This header used to say OpenMW exposes no
    velocity getter at all. That is wrong: types.Actor.getCurrentSpeed() exists,
    in the official API and in the Cod3x annotations, with no context
    restriction. It is not used here, and the differencing below is deliberately
    unchanged, because its SEMANTICS could not be established - the entire
    official description is "Current speed", and whether that means horizontal
    or 3D, measured velocity or intended locomotion speed, decides both whether
    the swap is safe and whether it is worth anything.

    Do not "simplify" this module by dropping in getCurrentSpeed without
    settling that first. If it includes the vertical component it silently
    retunes the Vault/Mantle detection reach during any fall, via
    core/sensor.lua's dynamicReach. See docs/velocity_getter_research.md - it
    records what is known, the four-reading experiment that answers it, and the
    five-file blast radius if the answer is favourable.

    Only what is consumed is computed. Removed over successive passes, each
    for the same reason - no reader:
        isSwimming, isFalling, isAscending, velocity (vector)
            - existed only for a debug string nobody called. isSwimming in
              particular cost a types.Actor.isSwimming() engine call every
              frame for nothing.
        verticalVelocity (and the whole 3-frame smoothing buffer behind it)
            - its only consumer was airborne.lua's LedgeHang catchability
              gate, which now answers the same question geometrically
              (is the lip still above hand height?) using the lip position
              the sensor already computed. That is exact and lag-free,
              where the smoothed velocity was an approximation that lagged
              reality by ~1.5 frames.

    Current consumers:
        isGrounded      - idle, sprint, roll, airborne, sensor_ext
        forwardVelocity - sensor (dynamic reach), sensor_ext (gating)
        position        - nothing external; kept for the frame diff

    NOTE for reviving states/optional/wall_run.lua: it reads
    syncData.verticalVelocity on entry to seed its launch arc. That field no
    longer exists. Either restore a RAW (unsmoothed) vertical component here
    or have WallRun derive its own - see the comment at that call site.
]]--

local self = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')

local EngineSync = {
    TELEPORT_THRESHOLD = 10.0,

    data = {
        position = util.vector3(0,0,0),
        forwardVelocity = 0,
        isGrounded = true
    },

    prevPos = nil,
    initialized = false,

    -- Set true by Vault/Mantle on enter(), false on exit(). Every
    -- per-tick position change during one of those states IS an
    -- intentional scripted teleport, not the kind of external/other-mod
    -- teleport TELEPORT_THRESHOLD exists to catch - so while suspended,
    -- large per-frame deltas are trusted and isGrounded keeps updating
    -- normally instead of being skipped for the frame. Without this,
    -- whichever state a boost hands off to could inherit a stale
    -- isGrounded value from before the boost started.
    suspended = false
}

function EngineSync.init()
    print("[FLOW] EngineSync Initializing...")
    EngineSync.prevPos = self.object.position
    EngineSync.initialized = true
end

function EngineSync.suspendTeleportDetection(suspend)
    EngineSync.suspended = suspend
end

function EngineSync.update(dt)
    if not EngineSync.initialized then EngineSync.init() end

    local currentPos = self.object.position

    if not EngineSync.prevPos or dt <= 0 then
        EngineSync.prevPos = currentPos
        return
    end

    local delta = currentPos - EngineSync.prevPos

    -- Squared-length comparison: avoids a sqrt every frame on a value only
    -- ever used as a threshold test.
    local distSq = delta:length2()

    if distSq > (EngineSync.TELEPORT_THRESHOLD * EngineSync.TELEPORT_THRESHOLD)
       and not EngineSync.suspended then
        EngineSync.data.forwardVelocity = 0
        EngineSync.prevPos = currentPos
        return
    end

    local invDt = 1.0 / dt
    local vx, vy = delta.x * invDt, delta.y * invDt

    -- Inlined 2D magnitude - avoids constructing a throwaway vector2 every
    -- frame just to call :length() on it.
    EngineSync.data.forwardVelocity = math.sqrt(vx * vx + vy * vy)

    EngineSync.data.isGrounded = types.Actor.isOnGround(self.object)

    EngineSync.data.position = currentPos
    EngineSync.prevPos = currentPos
end

return EngineSync
