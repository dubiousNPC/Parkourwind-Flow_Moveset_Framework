---@omw-context player
-- Mantle. Climbs onto a waist-to-head surface.
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local core = require('openmw.core')
local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local Settings = require('scripts/Flow/settings')
local Sensor = require('scripts/Flow/core/sensor')
local Geom = require('scripts/Flow/core/geom')
local Refusal = require('scripts/Flow/core/refusal')

local MantleState = BaseState.new("Mantle", {
    overrides = "all", teleports = true, anim = "oneshot",
})

local DEST_HEAD_PROBE = 90.0
local DEST_FLOOR_PROBE = 200.0
local DEST_FLOOR_TOLERANCE = 60.0
local DEST_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

local MIN_DURATION = 0.58   -- pwmantle 0.4s at speed .7; shorter cuts the clip
local CLIMB_SPEED_UNITS_PER_SEC = 200.0
local LANDING_BUFFER = 35.0
local LEDGE_PUSH_IN = 45.0   -- distance past the ledge edge to finish
local TIMEOUT_MAX = 2.0
local COMPLETION_GRACE = 0.06

local CAM_PITCH_DIP = 5.0    -- degrees
local CAM_ROLL_MAG = 2.0     -- degrees

local refusal = Refusal.new(0.35, 40.0)

local timeInState = 0
local totalDuration = 0

local function refuse(ledge, why)
    refusal:block(ledge)
    if Settings.debugMode() then print("[FLOW][mantle] refused: " .. why) end
    return nil
end

-- payload: { ledge = pos, vouched = bool } from LedgeHang, else the Sensor.
-- A vouched ledge was already validated as a hang and skips the destination
-- probes.
function MantleState:canEnter(payload)
    local ledge, vouched
    if payload and payload.ledge then
        ledge, vouched = payload.ledge, payload.vouched
    elseif Sensor.data.interaction == "Mantle" then
        ledge = Sensor.data.targetPos
    end
    if not ledge then return nil end
    if not vouched and refusal:blocks(ledge) then return nil end

    local startPos = mwSelf.position
    local pushDir = Geom.flat(ledge - startPos) or Geom.forward(mwSelf)
    local targetPos = ledge + util.vector3(0, 0, LANDING_BUFFER) + pushDir * LEDGE_PUSH_IN

    if targetPos.z <= startPos.z then return refuse(ledge, "target at or below start height") end

    if not vouched then
        local ok, why = Geom.standable(targetPos, DEST_HEAD_PROBE, DEST_FLOOR_PROBE,
                                       DEST_FLOOR_TOLERANCE, DEST_RAY_OPTS)
        if not ok then return refuse(ledge, why) end
    end

    return {
        startPos = startPos,
        risePos = util.vector3(startPos.x, startPos.y, targetPos.z),
        targetPos = targetPos,
        duration = math.max(MIN_DURATION, (targetPos.z - startPos.z) / CLIMB_SPEED_UNITS_PER_SEC),
    }
end

function MantleState:enter(plan)
    SkillCheck.attempt("Mantle")
    totalDuration = plan.duration
    timeInState = 0
    core.sendGlobalEvent('FLOW_Mantle_Start', {
        actor = mwSelf,
        startPos = plan.startPos,
        risePos = plan.risePos,
        targetPos = plan.targetPos,
        duration = plan.duration,
    })
end

function MantleState:exit()
    core.sendGlobalEvent('FLOW_Mantle_Cancel', { actor = mwSelf })
    camera.setExtraPitch(0)
    camera.setExtraRoll(0)
end

function MantleState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- Camera heave: 0 -> 1 -> 0 over the climb.
    local progress = timeInState / totalDuration
    if progress <= 1.0 then
        local heave = math.sin(progress * math.pi)
        camera.setExtraPitch(math.rad(CAM_PITCH_DIP * heave))
        camera.setExtraRoll(math.rad(CAM_ROLL_MAG * heave * 0.5))
    end

    if timeInState >= totalDuration + COMPLETION_GRACE then
        if SkillCheck.botched() then return "Stumble" end
        return "Idle"
    end

    if timeInState > TIMEOUT_MAX then
        return "Airborne"
    end
end

return MantleState
