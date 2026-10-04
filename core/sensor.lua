---@omw-context player
-- Vault/Mantle obstacle detector. Primary probe is I.SharedRay.
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local Settings = require('settings')
local Body = require('core/body')

-- Height bands: vault 25-50%, mantle 51-80%, walljump 80-110%, hang 110-130%.
local VAULT_MIN_FRAC  = 0.25
local VAULT_MAX_FRAC  = 0.50
local MANTLE_MAX_FRAC = 0.80

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

    VAULT_MAX_DEPTH = 170,  -- how far past the obstacle face to aim the landing

    -- Beam/thin object handling (fence rails, etc.)
    BEAM_PROBE_DEPTH = 3.0,
    BEAM_WIDTH_CHECK = 15.0,
    BEAM_CENTER_BIAS = 10.0,

    data = {
        interaction = "None",
        -- Set when a top surface was found but sits above the Mantle band.
        -- WallJump reads this: a top that exists but is out of reach.
        tooHigh = false,
        targetPos = nil,
        wallDist = 0,
        objHeight = 0,
        debugReason = "",
    },

    lastKnownObject = "None",
    lastKnownAngle = 0.0,
}

function Sensor.minVaultHeight()  return Body.frac(VAULT_MIN_FRAC)  end
function Sensor.maxHurdleHeight() return Body.frac(VAULT_MAX_FRAC)  end
function Sensor.maxMantleHeight() return Body.frac(MANTLE_MAX_FRAC) end

local function getForwardVector(rot)
    local yaw = rot:getYaw()
    return util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
end

local RAY_OPTS = { ignore = self.object }
local LOW_SCAN_OFFSETS = { 0, Sensor.LOW_SCAN_SIDE_OFFSET, -Sensor.LOW_SCAN_SIDE_OFFSET }
local PROBE_OFFSETS = { 10, 30 }
local SWEEP_RAY_OPTS = {
    radius = 15,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

local function getObjectName(obj)
    if not Settings.debugMode() then return "" end
    if not obj then return "Terrain" end
    local name = nil
    if obj.type and obj.type.record then
        local record = obj.type.record(obj)
        if record then name = record.name end
    end
    if not name or name == "" then name = obj.recordId end
    return name
end

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

function Sensor.registerSharedRay()
    if not I.SharedRay then
        print("[FLOW:Sensor] I.SharedRay not found - make sure SharedRay is bundled and registered in the omwscripts file.")
        return
    end

    if not I.SharedRay.requestDistance then
        print("[FLOW:Sensor] The SharedRay copy that claimed the interface has no " ..
              "requestDistance (version " .. tostring(I.SharedRay.version) ..
              "). Another mod's build won the registration; FLOW will use whatever " ..
              "distance it casts at.")
        return
    end

    I.SharedRay.requestDistance(Sensor.MAX_REACH)
end

function Sensor.update(dt, inputIntents, syncData)
    Sensor.data.interaction = "None"
    Sensor.data.tooHigh = false
    Sensor.data.targetPos = nil
    Sensor.data.wallDist = 0
    Sensor.data.objHeight = 0
    Sensor.data.debugReason = ""

    if not (Settings.stateEnabled("Vault") or Settings.stateEnabled("Mantle")) then
        Sensor.data.debugReason = "Disabled"
        return
    end

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)

    local dynamicReach = Sensor.BASE_REACH + (syncData.forwardVelocity * Sensor.VELOCITY_FACTOR)
    dynamicReach = math.min(dynamicReach, Sensor.MAX_REACH)

    local wallPos, wallNormal, wallDist, source

    local rayGet = I.SharedRay and (I.SharedRay.getUnclipped or I.SharedRay.get)
    if rayGet then
        local ray = rayGet()
        if ray and ray.hit and ray.hitPos and ray.hitNormal
           and ray.hitNormal.z < Sensor.WALKABLE_SLOPE_Z then

            local dist = ray.distance
            if type(dist) ~= "number" then
                dist = (ray.hitPos - self.object.position):length()
            end

            if dist <= dynamicReach then
                wallPos, wallNormal, wallDist = ray.hitPos, ray.hitNormal, dist
                source = getObjectName(ray.hitObject)
            end
        end
    end

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

    local topHit = nil
    local isThinBeam = false

    for i = 1, #PROBE_OFFSETS do
        local depth = PROBE_OFFSETS[i]
        local probeOrigin = wallPos + (intoWall * depth)
        local topOrigin = util.vector3(probeOrigin.x, probeOrigin.y, pos.z + 230)
        local topDest = util.vector3(probeOrigin.x, probeOrigin.y, pos.z + Sensor.minVaultHeight())
        topHit = nearby.castRay(topOrigin, topDest, RAY_OPTS)
        if topHit.hit then break end
    end

    if not topHit or not topHit.hit then
        local microOrigin = wallPos + (intoWall * Sensor.BEAM_PROBE_DEPTH)
        local topOrigin = util.vector3(microOrigin.x, microOrigin.y, pos.z + 230)
        local topDest = util.vector3(microOrigin.x, microOrigin.y, pos.z + Sensor.minVaultHeight())
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

    if relativeHeight < Sensor.minVaultHeight() then
        Sensor.data.debugReason = "Too Low"
        return
    end

    local ceilingHit = nearby.castRay(topHit.hitPos, topHit.hitPos + util.vector3(0, 0, Sensor.HEAD_CLEARANCE), RAY_OPTS)
    if ceilingHit.hit then
        Sensor.data.debugReason = "Ceiling Blocked"
        return
    end

    if relativeHeight > Sensor.maxMantleHeight() then
        Sensor.data.tooHigh = true
        Sensor.data.debugReason = "Too High (see LedgeHang)"
        return
    end

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

    local rawLanding = wallPos + (intoWall * Sensor.VAULT_MAX_DEPTH)
    local candidateLandPos = util.vector3(rawLanding.x, rawLanding.y, pos.z)

    local sweepStart = topHit.hitPos + util.vector3(0, 0, 50)
    local sweepRes = nearby.castRay(sweepStart, candidateLandPos, SWEEP_RAY_OPTS)
    local isThick = sweepRes.hit

    local vaultHeight = relativeHeight <= Sensor.maxHurdleHeight()

    if not isThick and not isThinBeam then
        local navPos = nearby.findNearestNavMeshPosition(candidateLandPos, {
            searchAreaHalfExtents = util.vector3(50, 50, 50)
        })

        if not vaultHeight then
            Sensor.data.interaction = "Mantle"
            Sensor.data.targetPos = topHit.hitPos
            Sensor.data.debugReason = "Thin/High"
        elseif navPos then
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
        elseif not vaultHeight then
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
