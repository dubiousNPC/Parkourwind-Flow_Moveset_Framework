---@omw-context player
--[[
    core/sensor.lua (LITE)

    Vault/Mantle obstacle detector. Primary detection is I.SharedRay - a
    single shared, engine-amortized ray per frame - instead of casting our
    own rays every frame. Because that ray follows the CAMERA, it reliably
    misses low obstacles you're not looking directly at (a knee-height
    curb, a fence rail) while running - exactly the "quickly pass low
    obstacles" case this mod cares most about. So when SharedRay doesn't
    find anything usable, we fall back to a small, narrow, SHORT-range scan
    (3 rays: center + two close side offsets) cast from the player's own
    body at knee height, in the player's own facing direction - not a
    revival of the old 9-ray waist/shin double-fan, just enough to catch
    "there's a low thing right in front of me" regardless of where the
    camera's pointed. It only runs when SharedRay's single ray misses, so
    worst case per frame is still "1 shared ray + up to 3 short own rays",
    far below the original fan scan.

    Beyond that: the handful of follow-up probes (top-surface height,
    ceiling clearance, thin-beam centering, landing-clear sweep) run ONLY
    once something's actually been detected, never continuously - unchanged
    either way.

    WallRun and LedgeHang detection used to live in this file (the SIDE
    SCAN and LEDGE HANG FALLBACK sections). They've moved to
    core/optional/sensor_ext.lua and are not loaded by default - see
    states/optional/README.md.
]]--

local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local Settings = require('settings')

local Sensor = {
    -- Detection reach (SharedRay is cast far beyond this; we just clip to it)
    BASE_REACH = 70,
    VELOCITY_FACTOR = 0.20,
    MAX_REACH = 160,

    -- Knee-height fallback scan (only fires when SharedRay misses)
    LOW_SCAN_HEIGHT = 25,       -- roughly shin/knee height above player origin
    LOW_SCAN_REACH = 55,        -- deliberately short - "don't faceplant into a curb", not a long-range aim
    LOW_SCAN_SIDE_OFFSET = 14,  -- narrow: just wide enough not to miss a dead-ahead hurdle, not a body-width fan

    -- Thresholds
    WALKABLE_SLOPE_Z = 0.65,
    MIN_VAULT_ANGLE = 78.0,
    VAULT_ALIGNMENT_THRESHOLD = -0.65,

    HEAD_CLEARANCE = 120,   -- raised alongside the bigger Vault apex: only offer the move
                            -- when there's genuinely room overhead for the new arc
    MIN_VAULT_HEIGHT = 25,
    MAX_HURDLE_HEIGHT = 60,
    MAX_MANTLE_HEIGHT = 110,  -- above this, hand off to LedgeHang's own detection instead

    VAULT_MAX_DEPTH = 170,  -- how far past the obstacle face to aim the landing

    -- Beam/thin object handling (fence rails, etc.)
    BEAM_PROBE_DEPTH = 3.0,
    BEAM_WIDTH_CHECK = 15.0,
    BEAM_CENTER_BIAS = 10.0,

    data = {
        interaction = "None",
        targetPos = nil,
        wallDist = 0,
        objHeight = 0,
        debugReason = "",
    },

    lastKnownObject = "None",
    lastKnownAngle = 0.0,
}

local function getForwardVector(rot)
    local yaw = rot:getYaw()
    return util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
end

-- =============================================================================
-- HOISTED CONSTANTS
--
-- These were previously rebuilt on every call, inside the hottest loop in
-- the mod: a fresh RAY_OPTS for each of the 7 castRay call
-- sites, plus the two offset lists. That's 9+ table allocations per sensor
-- update, every update, purely to hand the same constant data to the engine.
-- self.object is fixed for the lifetime of a player local script and
-- castRay only reads the options table, so a single shared table is safe.
-- =============================================================================
local RAY_OPTS = { ignore = self.object }
local LOW_SCAN_OFFSETS = { 0, Sensor.LOW_SCAN_SIDE_OFFSET, -Sensor.LOW_SCAN_SIDE_OFFSET }
local PROBE_OFFSETS = { 10, 30 }
-- Landing sweep uses a thick (radius) cast and deliberately does NOT ignore
-- the player, so it needs its own options table.
local SWEEP_RAY_OPTS = {
    radius = 15,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

-- Resolving an object's display name costs a pcall plus a record lookup, and
-- the ONLY consumer is Sensor.lastKnownObject, which is read solely by
-- getDebugString(). When the debug HUD is off, that work is pure waste on the
-- critical path - so skip it entirely.
local function getObjectName(obj)
    if not Settings.debugMode() then return "" end
    if not obj then return "Terrain" end
    local name = nil
    if obj.type and obj.type.record then
        -- No pcall: `obj.type and obj.type.record` above already establishes
        -- the method exists for this object type - the only real failure mode.
        local record = obj.type.record(obj)
        if record then name = record.name end
    end
    if not name or name == "" then name = obj.recordId end
    return name
end

-- Short, narrow, player-facing fallback for low obstacles the camera-aimed
-- SharedRay doesn't happen to be looking at. Only called when SharedRay
-- misses. Returns hitPos, hitNormal, distance, sourceLabel or nil.
local function tryLowScan(pos, forward, maxReach)
    local reach = math.min(Sensor.LOW_SCAN_REACH, maxReach)
    if reach <= 0 then return nil end

    local right = util.vector3(-forward.y, forward.x, 0)
    local originZ = pos.z + Sensor.LOW_SCAN_HEIGHT

    for i = 1, #LOW_SCAN_OFFSETS do
        local off = LOW_SCAN_OFFSETS[i]
        local origin = util.vector3(pos.x, pos.y, originZ) + (right * off)
        local dest = origin + (forward * reach)
        local res = nearby.castRay(origin, dest, RAY_OPTS)
        if res.hit and res.hitNormal.z < Sensor.WALKABLE_SLOPE_Z then
            return res.hitPos, res.hitNormal, (res.hitPos - origin):length(), getObjectName(res.hitObject)
        end
    end
    return nil
end

-- Call once (main.lua's onActive) so the shared cast is guaranteed to
-- reach at least our MAX_REACH, regardless of what any other SharedRay
-- consumer requests.
function Sensor.registerSharedRay()
    if not I.SharedRay then
        print("[FLOW:Sensor] I.SharedRay not found - make sure SharedRay is bundled and registered in the omwscripts file.")
        return
    end
    I.SharedRay.requestDistance(Sensor.MAX_REACH)
end

function Sensor.update(dt, inputIntents, syncData)
    Sensor.data.interaction = "None"
    Sensor.data.targetPos = nil
    Sensor.data.wallDist = 0
    Sensor.data.objHeight = 0
    Sensor.data.debugReason = ""

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)

    local dynamicReach = Sensor.BASE_REACH + (syncData.forwardVelocity * Sensor.VELOCITY_FACTOR)
    dynamicReach = math.min(dynamicReach, Sensor.MAX_REACH)

    local wallPos, wallNormal, wallDist, source

    -- Primary: SharedRay (camera-aimed, free/shared)
    if I.SharedRay then
        -- SharedRay results are a live view owned by SharedRay - read what
        -- we need immediately, never hold onto the table itself.
        local ray = I.SharedRay.getUnclipped()
        if ray.hit and ray.hitPos and ray.hitNormal
           and ray.distance <= dynamicReach
           and ray.hitNormal.z < Sensor.WALKABLE_SLOPE_Z then
            wallPos, wallNormal, wallDist = ray.hitPos, ray.hitNormal, ray.distance
            source = getObjectName(ray.hitObject)
        end
    end

    -- Fallback: knee-height scan from the player's own body (only spent
    -- when SharedRay didn't find anything usable)
    if not wallPos then
        wallPos, wallNormal, wallDist, source = tryLowScan(pos, forward, dynamicReach)
    end

    if not wallPos then
        Sensor.data.debugReason = I.SharedRay and "Clear" or "NoSharedRay"
        return
    end

    Sensor.data.wallDist = wallDist
    Sensor.lastKnownObject = source
    Sensor.lastKnownAngle = math.deg(math.acos(wallNormal.z))

    local intoWall = util.vector3(forward.x, forward.y, 0):normalize()
    local wallRight = wallNormal:cross(util.vector3(0, 0, 1)):normalize()

    local facingDot = forward:dot(wallNormal)
    if facingDot > Sensor.VAULT_ALIGNMENT_THRESHOLD then
        Sensor.data.debugReason = "Bad Angle"
        return
    end

    local wallAngle = math.deg(math.acos(wallNormal.z))

    -- =================================================================
    -- TOP SURFACE PROBE (unchanged 2-pass strategy: normal depth, then a
    -- shallow "thin beam" retry if the first pass found nothing to stand on)
    -- =================================================================
    local topHit = nil
    local isThinBeam = false

    for i = 1, #PROBE_OFFSETS do
        local depth = PROBE_OFFSETS[i]
        local probeOrigin = wallPos + (intoWall * depth)
        local topOrigin = util.vector3(probeOrigin.x, probeOrigin.y, pos.z + 230)
        local topDest = util.vector3(probeOrigin.x, probeOrigin.y, pos.z + Sensor.MIN_VAULT_HEIGHT)
        topHit = nearby.castRay(topOrigin, topDest, RAY_OPTS)
        if topHit.hit then break end
    end

    if not topHit or not topHit.hit then
        local microOrigin = wallPos + (intoWall * Sensor.BEAM_PROBE_DEPTH)
        local topOrigin = util.vector3(microOrigin.x, microOrigin.y, pos.z + 230)
        local topDest = util.vector3(microOrigin.x, microOrigin.y, pos.z + Sensor.MIN_VAULT_HEIGHT)
        topHit = nearby.castRay(topOrigin, topDest, RAY_OPTS)
        if topHit.hit then isThinBeam = true end
    end

    if not topHit or not topHit.hit then
        Sensor.data.debugReason = "NoTop"
        return
    end

    local surfaceZ = topHit.hitPos.z
    local relativeHeight = surfaceZ - pos.z
    Sensor.data.objHeight = relativeHeight

    if relativeHeight < Sensor.MIN_VAULT_HEIGHT then
        Sensor.data.debugReason = "Too Low"
        return
    end

    local ceilingHit = nearby.castRay(topHit.hitPos, topHit.hitPos + util.vector3(0, 0, Sensor.HEAD_CLEARANCE), RAY_OPTS)
    if ceilingHit.hit then
        Sensor.data.debugReason = "Ceiling Blocked"
        return
    end

    -- Anything tall enough to need LedgeHang is skipped here rather than
    -- force-mantled - LedgeHang has its own separate detection pipeline
    -- (core/optional/sensor_ext.lua's updateLedgeHang, called from
    -- states/airborne.lua) that picks up where this leaves off.
    if relativeHeight > Sensor.MAX_MANTLE_HEIGHT then
        Sensor.data.debugReason = "Too High (see LedgeHang)"
        return
    end

    -- =================================================================
    -- CENTER ADJUSTMENT (thin beams only)
    -- =================================================================
    local adjustedTargetPos = topHit.hitPos
    local centerDebug = ""

    if isThinBeam then
        local origin = topHit.hitPos + util.vector3(0, 0, 10)
        local leftPoint = origin - (wallRight * Sensor.BEAM_WIDTH_CHECK)
        local rightPoint = origin + (wallRight * Sensor.BEAM_WIDTH_CHECK)

        local leftLand = nearby.castRay(leftPoint, leftPoint - util.vector3(0, 0, 20), RAY_OPTS)
        local rightLand = nearby.castRay(rightPoint, rightPoint - util.vector3(0, 0, 20), RAY_OPTS)

        if leftLand.hit and not rightLand.hit then
            adjustedTargetPos = adjustedTargetPos - (wallRight * Sensor.BEAM_CENTER_BIAS)
            centerDebug = " (Auto-L)"
        elseif rightLand.hit and not leftLand.hit then
            adjustedTargetPos = adjustedTargetPos + (wallRight * Sensor.BEAM_CENTER_BIAS)
            centerDebug = " (Auto-R)"
        else
            centerDebug = " (Beam)"
        end
    end

    -- =================================================================
    -- VAULT vs MANTLE
    -- =================================================================
    local rawLanding = wallPos + (intoWall * Sensor.VAULT_MAX_DEPTH)
    local candidateLandPos = util.vector3(rawLanding.x, rawLanding.y, pos.z)

    local sweepStart = topHit.hitPos + util.vector3(0, 0, 50)
    local sweepRes = nearby.castRay(sweepStart, candidateLandPos, SWEEP_RAY_OPTS)
    local isThick = sweepRes.hit

    if not isThick and not isThinBeam then
        local navPos = nearby.findNearestNavMeshPosition(candidateLandPos, {
            searchAreaHalfExtents = util.vector3(50, 50, 50)
        })

        if navPos then
            if wallAngle < Sensor.MIN_VAULT_ANGLE then
                Sensor.data.interaction = "Mantle"
                Sensor.data.targetPos = topHit.hitPos
                Sensor.data.debugReason = "Slope"
            else
                Sensor.data.interaction = "Vault"
                Sensor.data.targetPos = navPos
                Sensor.data.debugReason = "OK (Thin)"
            end
        else
            Sensor.data.interaction = "Mantle"
            Sensor.data.targetPos = topHit.hitPos
            Sensor.data.debugReason = "Thin/NoNav"
        end
    else
        Sensor.data.interaction = "Mantle"
        Sensor.data.targetPos = adjustedTargetPos

        if isThinBeam then
            Sensor.data.debugReason = "Beam" .. centerDebug
        elseif relativeHeight > Sensor.MAX_HURDLE_HEIGHT then
            Sensor.data.debugReason = "Thick/High"
        else
            Sensor.data.interaction = "Vault"
            local t = wallPos + (intoWall * 120)
            Sensor.data.targetPos = util.vector3(t.x, t.y, surfaceZ)
            Sensor.data.debugReason = "Hurdle"
        end
    end
end

function Sensor.getDebugString()
    local str

    if Sensor.data.interaction == "Vault" then
        str = string.format("INT: VAULT (%s) | H: %.0f", Sensor.data.debugReason, Sensor.data.objHeight)
    elseif Sensor.data.interaction == "Mantle" then
        local reason = Sensor.data.debugReason ~= "" and Sensor.data.debugReason or "Default"
        str = string.format("INT: MANTLE [%s] | H: %.0f", reason, Sensor.data.objHeight)
    elseif Sensor.data.wallDist > 0 then
        str = string.format("INT: WALL | D: %.0f", Sensor.data.wallDist)
    else
        str = Sensor.data.debugReason ~= "" and ("INT: CLEAR [" .. Sensor.data.debugReason .. "]") or "INT: CLEAR"
    end

    str = str .. string.format("\n[Mem] %s @ %.1f°", Sensor.lastKnownObject, Sensor.lastKnownAngle)

    return str
end

return Sensor
