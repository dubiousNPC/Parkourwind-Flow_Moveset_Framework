---@omw-context player
-- WallRun + LedgeHang detection. Owns its own rays and .data.
local nearby = require('openmw.nearby')
local self = require('openmw.self')
local util = require('openmw.util')
local Settings = require('settings')
local Body = require('core/body')

-- Overhead ledges. HANDS_FRAC is where the hands reach, 110% of actor height.
-- The probe spans well above and below it: this runs ONLY while airborne, from
-- the player's CURRENT feet, so a window measured from the band alone travels
-- upward with the jump and a 30-unit span passes a given lip in two frames.
local HANDS_FRAC = 1.10
local PROBE_ABOVE = 0.20   -- ceiling 130% of height, the design limit
local PROBE_BELOW = 0.25   -- floor 85%, so a lip is caught while rising to it

local LIP_PROBE_RISE = 4.0

local WALL_PROBE_DROP = 0.15   -- as a fraction of height, below the hands

local SensorExt = {
    SIDE_REACH = 100,
    WALL_RUN_MIN_SPEED = 150,
    WALL_MAX_Z_NORMAL = 0.6,
    WALL_ALIGN_THRESHOLD = 0.3,
    WAIST_H = 70,

    GRAB_REACH = 90,
    LIP_CHECK_DEPTH = 10,
    LIP_PROBE_RISE = LIP_PROBE_RISE,

    data = {
        interaction = "None",   -- "None" or "LedgeHang"
        targetPos = nil,
        wallDist = 0,
        wallNormal = nil,
        debugReason = "",
        wallRun = { side = "None", normal = nil, runVector = nil, dist = 0 },
    }
}

-- Hands height, and the floor/ceiling of what they can catch.
function SensorExt.grabMinHeight() return Body.frac(HANDS_FRAC) end
function SensorExt.grabFloorHeight() return Body.frac(HANDS_FRAC - PROBE_BELOW) end
function SensorExt.grabMaxHeight() return Body.frac(HANDS_FRAC + PROBE_ABOVE) end

-- Height the forward wall ray is cast at. NOT the catch height.
function SensorExt.wallProbeHeight() return Body.frac(HANDS_FRAC - WALL_PROBE_DROP) end

-- From just above the band ceiling down to the band floor.
function SensorExt.ledgeDrop()
    return (SensorExt.grabMaxHeight() + LIP_PROBE_RISE) - SensorExt.grabFloorHeight()
end

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

    if not Settings.stateEnabled("LedgeHang") then
        SensorExt.data.debugReason = "Disabled"
        return
    end

    if syncData.isGrounded then return end

    local pos = self.object.position
    local rot = self.object.rotation
    local forward = getForwardVector(rot)
    local right = getRightVector(rot)

    local wallProbePos = pos + util.vector3(0, 0, SensorExt.wallProbeHeight())
    local grabTarget = wallProbePos + (forward * SensorExt.GRAB_REACH)

    local wallRes = nearby.castRay(wallProbePos, grabTarget, WORLD_RAY_OPTS)

    local lipDist = SensorExt.GRAB_REACH * 0.8
    if wallRes.hit then
        local distToWall = (wallRes.hitPos - wallProbePos):length()
        lipDist = distToWall + SensorExt.LIP_CHECK_DEPTH
    end

    local lipOriginZ = pos.z + SensorExt.grabMaxHeight() + SensorExt.LIP_PROBE_RISE
    local lipFlat = pos + (forward * lipDist)
    local lipOrigin = util.vector3(lipFlat.x, lipFlat.y, lipOriginZ)
    local lipDest = lipOrigin - util.vector3(0, 0, SensorExt.ledgeDrop())

    local lipRes = nearby.castRay(lipOrigin, lipDest, WORLD_RAY_OPTS)

    if lipRes.hit then
        local slope = lipRes.hitNormal:dot(util.vector3(0, 0, 1))

        if slope > 0.7 then
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
