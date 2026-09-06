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

local SensorExt = {
    SIDE_REACH = 100,
    WALL_RUN_MIN_SPEED = 150,
    WALL_MAX_Z_NORMAL = 0.6,
    WALL_ALIGN_THRESHOLD = 0.3,
    WAIST_H = 70,

    GRAB_REACH = 90,
    GRAB_HEIGHT = 135,
    LEDGE_DROP = 60,
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

    if syncData.isGrounded then return end

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)
    local right = getRightVector(rot)

    -- =================================================================
    -- LEDGE HANG FALLBACK
    -- =================================================================
    local headPos = pos + util.vector3(0, 0, SensorExt.GRAB_HEIGHT)
    local grabTarget = headPos + (forward * SensorExt.GRAB_REACH)

    local wallRes = nearby.castRay(headPos, grabTarget, WORLD_RAY_OPTS)

    local lipDist = SensorExt.GRAB_REACH * 0.8
    if wallRes.hit then
        local distToWall = (wallRes.hitPos - headPos):length()
        lipDist = distToWall + SensorExt.LIP_CHECK_DEPTH
    end

    local lipOrigin = headPos + (forward * lipDist) + util.vector3(0, 0, 40)
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
