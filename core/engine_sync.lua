---@omw-context player
-- Per-frame actor state. See docs/velocity_getter_research.md.
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

    local distSq = delta:length2()

    if distSq > (EngineSync.TELEPORT_THRESHOLD * EngineSync.TELEPORT_THRESHOLD)
       and not EngineSync.suspended then
        EngineSync.data.forwardVelocity = 0
        EngineSync.prevPos = currentPos
        return
    end

    local invDt = 1.0 / dt
    local vx, vy = delta.x * invDt, delta.y * invDt

    EngineSync.data.forwardVelocity = math.sqrt(vx * vx + vy * vy)

    EngineSync.data.isGrounded = types.Actor.isOnGround(self.object)

    EngineSync.data.position = currentPos
    EngineSync.prevPos = currentPos
end

return EngineSync
