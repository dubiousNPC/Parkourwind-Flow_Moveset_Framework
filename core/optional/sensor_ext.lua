---@omw-context player
--[[
    core/optional/sensor_ext.lua

    WallRun + LedgeHang detection. Split into two independent functions so
    each can be called (or not) on its own:

      SensorExt.updateWallRun(dt, intents, syncData)   - side-scan, only
        needed if states/optional/wall_run.lua is re-enabled. NOT called
        by default - fully dormant otherwise.

      SensorExt.updateLedgeHang(dt, intents, syncData) - ledge-lip probe,
        called every frame while airborne by main.lua since LedgeHang is
        back in the default state set (states/ledge_hang.lua).

      SensorExt.update(...)  - convenience wrapper that calls both, for
        when WallRun is also re-enabled.

    Owns its own raycasts and its own `.data` table, entirely separate
    from core/sensor.lua - states/optional/wall_run.lua and
    states/ledge_hang.lua read from THIS module, not core Sensor.
]]--

local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')
local Settings = require('settings')

-- =============================================================================
-- LEDGE HANG BAND
--
-- Overhead ledges, 120% - 140% of player height, measured up from the feet.
-- Expressed as fractions for the same reason core/sensor.lua does it: the move
-- is defined by the player's reach, not by a unit number.
--
-- THIS BAND USED TO BE AN ACCIDENT. Nothing declared it. It fell out of three
-- constants that were each tuned for something else - a cast height of 135, a
-- probe that started 40 above it and a 60-unit drop - which multiplied out to a
-- catch window of 115 to 175, i.e. 90% to 137% of player height.
--
-- That window sat far too low. Its FLOOR was 90% of height, which is chest
-- height - only five units above the old Mantle ceiling of 110 - so a hang was
-- being offered for obstacles a Mantle had just declined by a hair, and the two
-- detectors effectively met in the middle of the torso. Its CEILING was 137%,
-- so a genuinely overhead ledge at 140% fell outside it altogether. Both ends
-- were wrong in the same direction, which is why "each should catch higher" was
-- the accurate description of the symptom.
--
-- The window is now declared first and the probe geometry derived from it. With
-- LIP_PROBE_RISE below the real band is 120% - 143%; the extra 3% is the probe
-- needing to start above the highest lip it can accept.
--
-- The 100% - 120% gap between this and Mantle is deliberate; see the band note
-- in core/sensor.lua.
local PLAYER_HEIGHT = 128.0
local GRAB_MIN_FRAC = 1.00
local GRAB_MAX_FRAC = 1.20

local GRAB_MIN_HEIGHT = PLAYER_HEIGHT * GRAB_MIN_FRAC   -- 153.6
local GRAB_MAX_HEIGHT = PLAYER_HEIGHT * GRAB_MAX_FRAC   -- 179.2

-- The downward lip probe has to START above the highest catchable lip, or a ray
-- beginning exactly on a surface is a coin flip. Small, so the real band is
-- [GRAB_MIN_HEIGHT, GRAB_MAX_HEIGHT + 4].
local LIP_PROBE_RISE = 4.0

-- The forward ray looks for the WALL under the lip, so it is cast below the
-- band floor. Cast it AT the floor and a lip sitting exactly there puts the ray
-- level with its own edge, which grazes or misses depending on float luck.
local WALL_PROBE_DROP = 10.0

local SensorExt = {
    SIDE_REACH = 100,
    WALL_RUN_MIN_SPEED = 150,
    WALL_MAX_Z_NORMAL = 0.6,
    WALL_ALIGN_THRESHOLD = 0.3,
    WAIST_H = 70,

    PLAYER_HEIGHT = PLAYER_HEIGHT,

    GRAB_REACH = 90,

    -- Derived. Edit the fractions above, not these.
    GRAB_MIN_HEIGHT = GRAB_MIN_HEIGHT,
    GRAB_MAX_HEIGHT = GRAB_MAX_HEIGHT,

    -- Height the forward wall ray is cast at. This is NOT the catch height -
    -- that is the band above. It kept the old name so states/airborne.lua's
    -- reach comparison did not silently change meaning, but that comparison now
    -- reads GRAB_MIN_HEIGHT instead, which is the number it always meant.
    GRAB_HEIGHT = GRAB_MIN_HEIGHT - WALL_PROBE_DROP,

    -- How far the lip probe falls: from just above the band ceiling to the band
    -- floor. Everything it can hit is inside the band, which is what makes the
    -- band real rather than nominal.
    LEDGE_DROP = (GRAB_MAX_HEIGHT + LIP_PROBE_RISE) - GRAB_MIN_HEIGHT,

    LIP_PROBE_RISE = LIP_PROBE_RISE,
    LIP_CHECK_DEPTH = 10,

    data = {
        interaction = "None",   -- "None" or "LedgeHang"
        targetPos = nil,
        wallDist = 0,
        wallNormal = nil,
        debugReason = "",
        wallRun = { side = "None", normal = nil, runVector = nil, dist = 0 },
    }
}

-- Hoisted to avoid rebuilding identical option tables on every cast - see
-- the equivalent block in core/sensor.lua. self.object is fixed for the
-- lifetime of a player local script and castRay only reads these.
local RAY_OPTS = { ignore = self.object }
local WORLD_RAY_OPTS = {
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap,
    ignore = self.object
}

local function getForwardVector(rot)
    local yaw = rot:getYaw()
    return util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
end

local function getRightVector(rot)
    local yaw = rot:getYaw()
    return util.transform.rotateZ(yaw):apply(util.vector3(1, 0, 0))
end

function SensorExt.updateWallRun(dt, inputIntents, syncData)
    SensorExt.data.wallRun.side = "None"

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)
    local right = getRightVector(rot)

    -- =================================================================
    -- WALL RUN SIDE SCAN
    -- =================================================================
    if syncData.forwardVelocity > SensorExt.WALL_RUN_MIN_SPEED or not syncData.isGrounded then
        local function checkSide(directionVec, sideName)
            local startPos = pos + util.vector3(0, 0, SensorExt.WAIST_H)
            local endPos = startPos + (directionVec * SensorExt.SIDE_REACH)

            local res = nearby.castRay(startPos, endPos, WORLD_RAY_OPTS)

            if res.hit then
                if math.abs(res.hitNormal.z) < SensorExt.WALL_MAX_Z_NORMAL then
                    local wallNormal = res.hitNormal
                    local up = util.vector3(0, 0, 1)
                    local runDir = (sideName == "Right") and wallNormal:cross(up) or up:cross(wallNormal)

                    if forward:dot(runDir) > SensorExt.WALL_ALIGN_THRESHOLD then
                        SensorExt.data.wallRun.side = sideName
                        SensorExt.data.wallRun.normal = wallNormal
                        SensorExt.data.wallRun.runVector = runDir
                        SensorExt.data.wallRun.dist = (res.hitPos - startPos):length()
                        return true
                    end
                end
            end
            return false
        end

        if not checkSide(right, "Right") then checkSide(right * -1, "Left") end
    end
end

function SensorExt.updateLedgeHang(dt, inputIntents, syncData)
    SensorExt.data.interaction = "None"
    SensorExt.data.targetPos = nil
    SensorExt.data.wallDist = 0
    SensorExt.data.debugReason = ""
    SensorExt.data.wallNormal = nil

    -- Same placement rule as core/sensor.lua's early-out: after the resets, so
    -- a stale lip cannot outlive the toggle being switched off. This is the more
    -- expensive of the two savings - main.lua calls this EVERY airborne frame,
    -- and a hit costs the wall ray, the lip probe and three clearance casts.
    if not Settings.stateEnabled("LedgeHang") then
        SensorExt.data.debugReason = "Disabled"
        return
    end

    if syncData.isGrounded then return end

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)
    local right = getRightVector(rot)

    -- =================================================================
    -- LEDGE HANG FALLBACK
    -- =================================================================
    -- Cast for the wall UNDER the band, then find the lip by dropping through
    -- the band from just above it. Both heights come from the band constants at
    -- the top of the file, so the catch window is exactly what they declare.
    local wallProbePos = pos + util.vector3(0, 0, SensorExt.GRAB_HEIGHT)
    local grabTarget = wallProbePos + (forward * SensorExt.GRAB_REACH)

    local wallRes = nearby.castRay(wallProbePos, grabTarget, WORLD_RAY_OPTS)

    local lipDist = SensorExt.GRAB_REACH * 0.8
    if wallRes.hit then
        local distToWall = (wallRes.hitPos - wallProbePos):length()
        lipDist = distToWall + SensorExt.LIP_CHECK_DEPTH
    end

    -- Start just above the band ceiling and fall to the band floor. The rise is
    -- measured from the band, NOT from the wall-probe height - that is what the
    -- old hard-coded `+ 40` did, which is how the window ended up 20 units
    -- below where anyone thought it was.
    local lipOriginZ = pos.z + SensorExt.GRAB_MAX_HEIGHT + SensorExt.LIP_PROBE_RISE
    local lipFlat = pos + (forward * lipDist)
    local lipOrigin = util.vector3(lipFlat.x, lipFlat.y, lipOriginZ)
    local lipDest = lipOrigin - util.vector3(0, 0, SensorExt.LEDGE_DROP)

    local lipRes = nearby.castRay(lipOrigin, lipDest, WORLD_RAY_OPTS)

    if lipRes.hit then
        local slope = lipRes.hitNormal:dot(util.vector3(0, 0, 1))

        if slope > 0.7 then
            -- Unrolled: the offsets depend on the runtime `right` vector so
            -- they can't be hoisted, but building a 3-entry table per call
            -- just to iterate it can be avoided entirely.
            local isClear = true
            local lipHit = lipRes.hitPos
            local up80 = util.vector3(0, 0, 80)
            local sideOff = right * 25
            for i = 1, 3 do
                local cStart
                if i == 1 then cStart = lipHit
                elseif i == 2 then cStart = lipHit + sideOff
                else cStart = lipHit - sideOff end
                local cRes = nearby.castRay(cStart, cStart + up80, RAY_OPTS)
                if cRes.hit then isClear = false; break end
            end

            if isClear then
                SensorExt.data.interaction = "LedgeHang"
                SensorExt.data.targetPos = lipRes.hitPos
                SensorExt.data.wallDist = (lipRes.hitPos - pos):length()
                SensorExt.data.debugReason = "Hangable"

                if wallRes.hit then
                    SensorExt.data.wallNormal = wallRes.hitNormal
                else
                    SensorExt.data.wallNormal = -forward
                end
            end
        end
    end
end

-- Convenience: both passes, for when WallRun is also re-enabled.
function SensorExt.update(dt, inputIntents, syncData)
    SensorExt.updateWallRun(dt, inputIntents, syncData)
    SensorExt.updateLedgeHang(dt, inputIntents, syncData)
end

return SensorExt
