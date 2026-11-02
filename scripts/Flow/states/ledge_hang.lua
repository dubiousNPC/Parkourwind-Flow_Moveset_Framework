---@omw-context player
-- LedgeHang. Holds an overhead ledge; routes to Shimmy, WallBoost and Mantle.
local BaseState = require('scripts/Flow/states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local SensorExt = require('scripts/Flow/core/optional/sensor_ext')
local Geom = require('scripts/Flow/core/geom')

local LedgeHangState = BaseState.new("LedgeHang", {
    overrides = "all", suspend = true, anim = "loop",
})

local KICK_RAY_OPTS = { ignore = mwSelf }

local LIP_SANITY_RANGE = 300
local LEDGE_AIM_DROP = 34   -- how far below level still counts as looking up

local HANG_OFFSET_Z = 125
local WALL_OFFSET = 35
local KICK_FORCE_BACK = 350
local KNEE_CHECK_DIST = 60
local CLIMB_COOLDOWN = 0.3

local wallNormal = nil
local timeInState = 0
local lip = nil
local lastDir = 0   -- last shimmy step on this ledge; the kick turns that way

local function snapTo(pos, rot)
    core.sendGlobalEvent('FLOW_SnapTo', { actor = mwSelf, position = pos, rotation = rot })
end

-- Camera aimed at or above the lip. SharedRay is camera-aimed, so no pitch sign.
local function lookingAtLedge()
    local get = I.SharedRay and (I.SharedRay.getUnclipped or I.SharedRay.get)
    if not get then return true end
    local ray = get()
    if not (ray and ray.hit and ray.hitPos) then return true end
    -- Look DIRECTION, camera to what the camera hit: sign-free, and it does not
    -- care how far away the hit is. Comparing the hit's absolute Z to the lip
    -- rejected any shot that landed on the wall below it, which is most of them.
    return (ray.hitPos.z - camera.getPosition().z) > -LEDGE_AIM_DROP
end

-- payload from Shimmy: { lip, normal, dir }. Otherwise a fresh grab from
-- SensorExt, gated on reach and aim.
function LedgeHangState:canEnter(payload)
    if payload and payload.lip then
        if (payload.lip - mwSelf.position):length() > LIP_SANITY_RANGE then return nil end
        return { lip = payload.lip, normal = payload.normal, dir = payload.dir or 0 }
    end

    local d = SensorExt.data
    if d.interaction ~= "LedgeHang" or not d.targetPos then return nil end
    -- The bottom of what the hands can catch: not the hands height, and not the
    -- lower wall-probe height.
    if d.targetPos.z <= mwSelf.position.z + SensorExt.grabFloorHeight() then return nil end
    if not lookingAtLedge() then return nil end
    return { lip = d.targetPos, normal = d.wallNormal, dir = 0 }
end

function LedgeHangState:enter(plan)
    timeInState = 0
    lip = plan.lip
    lastDir = plan.dir
    wallNormal = plan.normal or -Geom.forward(mwSelf)

    local hangPos = lip - util.vector3(0, 0, HANG_OFFSET_Z) + (wallNormal * WALL_OFFSET)
    local lookDir = -wallNormal
    snapTo(hangPos, util.transform.rotateZ(math.atan2(lookDir.x, lookDir.y)))
end

function LedgeHangState:exit()
    lip = nil
end

function LedgeHangState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    local lateralInput = inputData.moveVector.x
    local lateral = math.abs(lateralInput) > 0.1
    local dir = (lateralInput > 0) and 1 or -1

    -- Discrete actions take a fresh PRESS. The grab itself is made with jump
    -- held, so reading held jump here chained grab -> Shimmy -> WallBoost, or
    -- grab -> Mantle 0.3s later, without the player asking for either.
    if inputData.jumpPressed then
        if inputData.moveVector.y < 0 then
            local forward = Geom.forward(mwSelf)
            local kneePos = mwSelf.position + util.vector3(0, 0, 30)
            local res = nearby.castRay(kneePos, kneePos + (forward * KNEE_CHECK_DIST), KICK_RAY_OPTS)

            local turnSign = (lastDir < 0) and -1 or 1
            local awayRot = util.transform.rotateZ(mwSelf.rotation:getYaw() + (turnSign * math.pi * 0.5))

            if res.hit then
                snapTo(mwSelf.position + (-forward * (KICK_FORCE_BACK * 0.15)) + util.vector3(0, 0, 20), awayRot)
            else
                -- Nothing to push off, but still turn to face the fall.
                snapTo(mwSelf.position, awayRot)
            end
            return "Airborne"
        end

        if lateral then
            return "WallBoost", { normal = wallNormal, dir = dir }
        end

        if timeInState > CLIMB_COOLDOWN then
            return "Mantle", { ledge = lip, vouched = true }
        end
    end

    if lateral then
        return "Shimmy", { lip = lip, normal = wallNormal, dir = dir }
    end

    if inputData.crouch then
        snapTo(mwSelf.position + (-Geom.forward(mwSelf) * 20))
        return "Airborne"
    end
end

return LedgeHangState
