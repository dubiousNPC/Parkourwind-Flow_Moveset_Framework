---@omw-context player
-- Mantle. Climbs onto a waist-to-head surface.
local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local core = require('openmw.core') 
local ui = require('openmw.ui')
local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local Settings = require('settings')
local Sensor = require('core/sensor') 
local EngineSync = require('core/engine_sync')

local MantleState = BaseState.new("Mantle")

local DEST_HEAD_PROBE = 60.0
local DEST_FLOOR_PROBE = 200.0
local DEST_FLOOR_TOLERANCE = 60.0
local DEST_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

-- Configuration
local MIN_DURATION = 0.35
local CLIMB_SPEED_UNITS_PER_SEC = 200.0 -- Adjust speed scaling
local LANDING_BUFFER = 35.0
local LEDGE_PUSH_IN = 45.0   -- how far PAST the detected ledge edge to finish, so the
local TIMEOUT_MAX = 2.0

-- Camera "Heave" Config
local CAM_PITCH_DIP = 5.0 -- Degrees to look down during effort
local CAM_ROLL_MAG = 2.0  -- Degrees to roll during effort

-- Internal State
local targetPos = nil
local timeInState = 0
local totalDuration = 0
local startPitch = 0
local startRoll = 0

-- Helpers
local function applyFatigueCost()
    local encumb = types.Actor.getEncumbrance(mwSelf)
    local cap = types.Actor.getCapacity(mwSelf)
    local ratio = 0
    if cap > 0 then ratio = encumb / cap end
    local cost = 20.0 * (1.0 + ratio)
    local dyn = types.Actor.stats.dynamic.fatigue(mwSelf)
    dyn.current = math.max(0, dyn.current - cost)
end

-- State Interface

local BLOCK_DURATION = 0.35
local BLOCK_RETRY_RADIUS = 40.0
local blockedUntil = 0
local blockedPos = nil

function MantleState.isBlocked(candidate)
    if core.getRealTime() >= blockedUntil then return false end
    if not (blockedPos and candidate) then return true end
    return (candidate - blockedPos):length() < BLOCK_RETRY_RADIUS
end

local function refuse(state)
    blockedPos = Sensor.data.targetPos
    blockedUntil = core.getRealTime() + BLOCK_DURATION
    state.abort = true
end

local destinationVouched = false

function MantleState.vouchDestination()
    destinationVouched = true
end

function MantleState:enter(syncData)
    self.abort = false
    if Sensor.data.interaction ~= "Mantle" then
        if Settings.debugMode() then
            print("[FLOW][mantle] refused: no Mantle target from sensor")
        end
        self.abort = true
        return
    end

    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("Mantle", Sensor.getDebugString(), "MANTLE TRIGGERED")
    
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
    EngineSync.suspendTeleportDetection(true)
    
    local startPos = mwSelf.position
    local rawLedge = Sensor.data.targetPos
    
    -- Safety Check: Ensure target exists
    if not rawLedge then
        if Settings.debugMode() then
            print("[FLOW][mantle] refused: sensor target missing")
        end
        self.abort = true
        return
    end
    
    local toLedge = rawLedge - startPos
    local pushDir = util.vector3(toLedge.x, toLedge.y, 0)
    if pushDir:length() > 1.0 then
        pushDir = pushDir:normalize()
    else
        local yaw = mwSelf.rotation:getYaw()
        pushDir = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
    end

    targetPos = rawLedge + util.vector3(0, 0, LANDING_BUFFER) + pushDir * LEDGE_PUSH_IN
    
    if targetPos.z <= startPos.z then
        if Settings.debugMode() then
            print("[FLOW][mantle] refused: target at or below start height")
        end
        refuse(self)
        return
    end
    
    local DEST_HEAD_PROBE = 90.0
    local DEST_FLOOR_PROBE = 200.0
    local DEST_FLOOR_TOLERANCE = 60.0
    local DEST_RAY_OPTS = {
        ignore = mwSelf,
        collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
    }

    -- Skip the destination probes when the caller has vouched for the ledge.
    if destinationVouched then
        destinationVouched = false
    else

    local destTop = targetPos + util.vector3(0, 0, DEST_HEAD_PROBE)
    local floorRes = nearby.castRay(destTop, targetPos - util.vector3(0, 0, DEST_FLOOR_PROBE),
                                    DEST_RAY_OPTS)
    if not floorRes.hit or (targetPos.z - floorRes.hitPos.z) > DEST_FLOOR_TOLERANCE then
        if Settings.debugMode() then
            print("[FLOW][mantle] refused: no floor under destination")
        end
        refuse(self)
        return
    end
    if nearby.castRay(targetPos, destTop, DEST_RAY_OPTS).hit then
        if Settings.debugMode() then
            print("[FLOW][mantle] refused: no headroom above destination")
        end
        refuse(self)
        return
    end

    end  -- destinationVouched

    local heightDiff = math.abs(targetPos.z - startPos.z)
    totalDuration = math.max(MIN_DURATION, heightDiff / CLIMB_SPEED_UNITS_PER_SEC)
    
    -- 2. Define geometry
    local risePos = util.vector3(startPos.x, startPos.y, targetPos.z)
    
    -- 3. Visuals: Camera & Animation
    startPitch = camera.getPitch()
    startRoll = camera.getRoll()
    
    
    -- 4. Execute
    core.sendGlobalEvent('FLOW_Mantle_Start', {
        actor = mwSelf,
        startPos = startPos,
        risePos = risePos,
        targetPos = targetPos,
        cageFrom = 1,   -- phase-gated in the backend: phase 2 only, never the
                         -- vertical rise up the wall face

        duration = totalDuration -- Send explicit duration to sync physics
    })
    
    applyFatigueCost()
    timeInState = 0
    self.abort = false
end

function MantleState:exit()
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    EngineSync.suspendTeleportDetection(false)
    core.sendGlobalEvent('FLOW_Mantle_Cancel', { actor = mwSelf })
    
    -- Reset Camera
    camera.setExtraPitch(0)
    camera.setExtraRoll(0)
end

function MantleState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end
    
    timeInState = timeInState + dt
    
    -- 1. Procedural Camera Animation (The "Heave")
    local progress = timeInState / totalDuration
    if progress <= 1.0 then
        -- Sine wave: 0 -> 1 -> 0
        local heave = math.sin(progress * math.pi) 
        
        -- Pitch down (chin tuck) + Roll (exertion)
        local extraPitch = math.rad(CAM_PITCH_DIP * heave)
        local extraRoll = math.rad(CAM_ROLL_MAG * heave * 0.5) -- Slight roll
        
        camera.setExtraPitch(extraPitch)
        camera.setExtraRoll(extraRoll)
    end

    if timeInState >= totalDuration + 0.06 then
        if inputData.moveVector.y > 0 then
            return "Idle"
        else
            return "Idle"
        end
    end
    
    -- Failsafe timeout
    if timeInState > TIMEOUT_MAX then
        return "Airborne"
    end

    return nil
end

return MantleState