---@omw-context player
-- Per-frame actor state. See docs/velocity_getter_research.md.
local self = require('openmw.self')
local types = require('openmw.types')

local GROUND_CONFIRM = 0.15

local EngineSync = {
    TELEPORT_SPEED = 3000.0,

    data = {
        forwardVelocity = 0,
        isGrounded = true,
        groundedTime = 0,
        landings = 0,
    },

    prevPos = nil,
    initialized = false,

    suspended = false
}

function EngineSync.init()
    EngineSync.prevPos = self.object.position
    EngineSync.initialized = true
end

function EngineSync.suspendTeleportDetection(suspend)
    EngineSync.suspended = suspend
end

local function updateGround(dt)
    local data = EngineSync.data
    data.isGrounded = types.Actor.isOnGround(self.object)
    if not data.isGrounded then
        data.groundedTime = 0
        return
    end
    local before = data.groundedTime
    data.groundedTime = before + dt
    if before < GROUND_CONFIRM and data.groundedTime >= GROUND_CONFIRM then
        data.landings = data.landings + 1
    end
end

function EngineSync.update(dt)
    if not EngineSync.initialized then EngineSync.init() end

    local currentPos = self.object.position

    if not EngineSync.prevPos or dt <= 0 then
        EngineSync.prevPos = currentPos
        return
    end

    updateGround(dt)

    local dx = currentPos.x - EngineSync.prevPos.x
    local dy = currentPos.y - EngineSync.prevPos.y
    EngineSync.prevPos = currentPos

    local speed = math.sqrt(dx * dx + dy * dy) / dt
    if speed > EngineSync.TELEPORT_SPEED and not EngineSync.suspended then
        EngineSync.data.forwardVelocity = 0
        return
    end

    EngineSync.data.forwardVelocity = speed
end

return EngineSync
