---@omw-context player
-- Vault. Hurdles a knee-to-waist obstacle.
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local Sensor = require('scripts/Flow/core/sensor')
local Geom = require('scripts/Flow/core/geom')
local Refusal = require('scripts/Flow/core/refusal')

local VaultState = BaseState.new("Vault", {
    overrides = "all", teleports = true, anim = "oneshot",
})

local PROFILE_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

local VAULT_BASE_DURATION = 0.45
local DISTANCE_SCALING = 500.0

local PROFILE_STEPS = 5             -- rays along the trajectory
local PEAK_SAFETY_CLEARANCE = 55.0  -- feet clearance over the obstacle peak
local AIR_DROP_HEIGHT = 45.0        -- release height above the target
local MIN_APEX_RISE = 80.0          -- minimum apex above the start

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

local COMPLETION_GRACE = 0.06

local refusal = Refusal.new(0.35, 40.0)

local timeInState = 0
local estimatedDuration = 0.5

-- Plans the arc from the Sensor's target, or refuses. Nothing is committed.
function VaultState:canEnter()
    local rawLandPos = Sensor.data.targetPos
    if Sensor.data.interaction ~= "Vault" or not rawLandPos then return nil end
    if refusal:blocks(rawLandPos) then return nil end

    local startPos = mwSelf.position

    -- Profile the path for its highest point, then release above the landing.
    local highestZ = math.max(startPos.z, rawLandPos.z)
    local pathVec = rawLandPos - startPos
    for i = 1, PROFILE_STEPS do
        local scanXY = startPos + (pathVec * (i / (PROFILE_STEPS + 1)))
        local origin = util.vector3(scanXY.x, scanXY.y, startPos.z + PROFILE_SCAN_CEILING)
        local dest = util.vector3(scanXY.x, scanXY.y, startPos.z - PROFILE_SCAN_FLOOR)
        local res = nearby.castRay(origin, dest, PROFILE_RAY_OPTS)
        if res.hit and res.hitPos.z > highestZ then highestZ = res.hitPos.z end
    end

    if (highestZ - startPos.z) > MAX_VAULTABLE_RISE then
        refusal:block(rawLandPos); return nil
    end

    -- apexPos is a Bezier CONTROL point; see README.
    local requiredPeak = highestZ + PEAK_SAFETY_CLEARANCE
    local apexZ = 2 * requiredPeak - 0.5 * startPos.z - 0.5 * rawLandPos.z
    apexZ = math.max(apexZ, startPos.z + MIN_APEX_RISE)

    local spanXY = util.vector3(pathVec.x, pathVec.y, 0):length()
    if spanXY > APEX_DIST_REFERENCE then
        apexZ = apexZ + math.min(APEX_DIST_BONUS_MAX, (spanXY - APEX_DIST_REFERENCE) * APEX_DIST_GAIN)
    end

    local midPoint = (startPos + rawLandPos) * 0.5

    local probeZ = startPos.z + (apexZ - startPos.z) * CLEARANCE_PROBE_Z
    if nearby.castRay(util.vector3(startPos.x, startPos.y, probeZ),
                      util.vector3(rawLandPos.x, rawLandPos.y, probeZ), PROFILE_RAY_OPTS).hit then
        refusal:block(rawLandPos); return nil
    end

    if not Geom.standable(rawLandPos, DEST_HEAD_PROBE, DEST_FLOOR_PROBE, DEST_FLOOR_TOLERANCE,
                          PROFILE_RAY_OPTS) then
        refusal:block(rawLandPos); return nil
    end

    return {
        startPos = startPos,
        apexPos = util.vector3(midPoint.x, midPoint.y, apexZ),
        landPos = rawLandPos + util.vector3(0, 0, AIR_DROP_HEIGHT),
        duration = math.max(0.25, VAULT_BASE_DURATION + (pathVec:length() / DISTANCE_SCALING)),
    }
end

function VaultState:enter(plan)
    SkillCheck.attempt("Vault")
    estimatedDuration = plan.duration
    timeInState = 0
    core.sendGlobalEvent('FLOW_Vault_Start', {
        actor = mwSelf,
        startPos = plan.startPos,
        apexPos = plan.apexPos,
        landPos = plan.landPos,
        duration = plan.duration,
    })
end

function VaultState:exit()
    core.sendGlobalEvent('FLOW_Vault_Cancel', { actor = mwSelf })
end

function VaultState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState >= estimatedDuration + COMPLETION_GRACE then
        if SkillCheck.botched() then return "Stumble" end
        return "Idle"
    end
end

return VaultState
