---@omw-context player
-- Vault. Hurdles a knee-to-waist obstacle.
local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local I = require('openmw.interfaces')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local Sensor = require('core/sensor')
local EngineSync = require('core/engine_sync')

local VaultState = BaseState.new("Vault")

local PROFILE_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

-- Configuration
local VAULT_BASE_DURATION = 0.45 
local DISTANCE_SCALING = 500.0   

-- [NEW] Physics Safety Config
local PROFILE_STEPS = 5          -- How many raycasts to perform along the trajectory
local PEAK_SAFETY_CLEARANCE = 55.0 -- Height feet must clear the obstacle peak
local AIR_DROP_HEIGHT = 45.0     -- Height above target to release player (Physics takes over)
local MIN_APEX_RISE = 110.0      -- Floor on apex height above the start, so even a low
                                 -- obstacle produces a readable hop rather than a shuffle

local PROFILE_SCAN_CEILING = 600.0  -- how far above the player to start each probe
local PROFILE_SCAN_FLOOR = 50.0     -- how far below the player to end it

local MAX_VAULTABLE_RISE = 150.0

local CLEARANCE_PROBE_Z = 0.65      -- fraction of the apex rise to probe at

local DEST_FLOOR_PROBE = 220.0   -- how far below landPos to look for a floor
local DEST_HEAD_PROBE = 90.0     -- headroom needed above landPos
local DEST_FLOOR_TOLERANCE = 60.0 -- how far the found floor may sit below landPos

local APEX_DIST_REFERENCE = 120.0 -- distance at which no extra lift is added
local APEX_DIST_GAIN = 0.12       -- extra lift per unit beyond that
local APEX_DIST_BONUS_MAX = 30.0  -- hard ceiling on the extra lift

local DESCENT_CAGE_START = 0.55  -- progress fraction after which the cage applies

local BLOCK_DURATION = 0.35

local BLOCK_RETRY_RADIUS = 40.0
local blockedPos = nil
local blockedUntil = 0

-- Internals
local targetPos = nil
local timeInState = 0
local estimatedDuration = 0.5

function VaultState.isBlocked(candidate)
    if core.getRealTime() >= blockedUntil then return false end
    if not (blockedPos and candidate) then return true end
    return (candidate - blockedPos):length() < BLOCK_RETRY_RADIUS
end

function VaultState:enter(syncData)
    self.abort = false
    -- 1. Sanity Check
    if Sensor.data.interaction ~= "Vault" or not Sensor.data.targetPos then
        self.abort = true
        return
    end
    
    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("Vault", Sensor.getDebugString(), "VAULT TRIGGERED")

    local startPos = mwSelf.position
    local rawLandPos = Sensor.data.targetPos
    
    -- [NEW] Strategy: "The Profilometer" & "Air Drop"
    
    local highestZ = math.max(startPos.z, rawLandPos.z)
    local pathVec = rawLandPos - startPos
    
    for i = 1, PROFILE_STEPS do
        local t = i / (PROFILE_STEPS + 1)
        local scanXY = startPos + (pathVec * t)
        
        local origin = util.vector3(scanXY.x, scanXY.y, startPos.z + PROFILE_SCAN_CEILING)
        local dest = util.vector3(scanXY.x, scanXY.y, startPos.z - PROFILE_SCAN_FLOOR)
        
        local res = nearby.castRay(origin, dest, PROFILE_RAY_OPTS)
        
        if res.hit and res.hitPos.z > highestZ then
            highestZ = res.hitPos.z
        end
    end

    if (highestZ - startPos.z) > MAX_VAULTABLE_RISE then
        blockedPos = Sensor.data.targetPos
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end
    
    
    local requiredPeak = highestZ + PEAK_SAFETY_CLEARANCE
    local apexZ = 2 * requiredPeak - 0.5 * startPos.z - 0.5 * rawLandPos.z
    
    -- Clamp Apex to be at least a minimum jump height relative to start
    apexZ = math.max(apexZ, startPos.z + MIN_APEX_RISE)

    local spanXY = util.vector3(rawLandPos.x - startPos.x, rawLandPos.y - startPos.y, 0):length()
    if spanXY > APEX_DIST_REFERENCE then
        local bonus = math.min(APEX_DIST_BONUS_MAX,
                               (spanXY - APEX_DIST_REFERENCE) * APEX_DIST_GAIN)
        apexZ = apexZ + bonus
    end

    local midPoint = (startPos + rawLandPos) * 0.5
    local apexPos = util.vector3(midPoint.x, midPoint.y, apexZ)

    local probeZ = startPos.z + (apexZ - startPos.z) * CLEARANCE_PROBE_Z
    local probeStart = util.vector3(startPos.x, startPos.y, probeZ)
    local probeEnd = util.vector3(rawLandPos.x, rawLandPos.y, probeZ)

    if nearby.castRay(probeStart, probeEnd, PROFILE_RAY_OPTS).hit then
        blockedPos = Sensor.data.targetPos
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end

    local destTop = rawLandPos + util.vector3(0, 0, DEST_HEAD_PROBE)
    local destFloorEnd = rawLandPos - util.vector3(0, 0, DEST_FLOOR_PROBE)

    local floorRes = nearby.castRay(destTop, destFloorEnd, PROFILE_RAY_OPTS)
    if not floorRes.hit then
        blockedPos = Sensor.data.targetPos
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end

    if (rawLandPos.z - floorRes.hitPos.z) > DEST_FLOOR_TOLERANCE then
        blockedPos = Sensor.data.targetPos
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end

    -- Headroom: refuse if the player would materialise inside a ceiling.
    local headRes = nearby.castRay(rawLandPos, destTop, PROFILE_RAY_OPTS)
    if headRes.hit then
        blockedPos = Sensor.data.targetPos
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end

    local safeLandPos = rawLandPos + util.vector3(0, 0, AIR_DROP_HEIGHT)

    -- 3. Duration Calculation
    local dist = (rawLandPos - startPos):length()
    estimatedDuration = math.max(0.25, VAULT_BASE_DURATION + (dist / DISTANCE_SCALING))

    -- 4. Take Control
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
    EngineSync.suspendTeleportDetection(true)

    -- 5. Trigger Global Physics
    core.sendGlobalEvent('FLOW_Vault_Start', {
        actor = mwSelf,
        startPos = startPos,
        apexPos = apexPos,
        landPos = safeLandPos, -- Send the Air Drop position
        cageFrom = DESCENT_CAGE_START,
        duration = estimatedDuration
    })

    timeInState = 0
    self.abort = false
end

function VaultState:exit()
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    EngineSync.suspendTeleportDetection(false)
    core.sendGlobalEvent('FLOW_Vault_Cancel', { actor = mwSelf })
end

local COMPLETION_GRACE = 0.06

function VaultState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end
    
    timeInState = timeInState + dt
    
    -- 1. Completion Check
    if timeInState >= estimatedDuration + COMPLETION_GRACE then
        if inputData.moveVector.y > 0 then
            return "Idle"
        else
            return "Idle"
        end
    end

    return nil
end

return VaultState