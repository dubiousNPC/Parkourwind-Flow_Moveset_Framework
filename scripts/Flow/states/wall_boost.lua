---@omw-context player
-- WallBoost. 45-degree launch away from a ledge.
--
-- The arc is ballistic at ENGINE gravity, so the hand-off to Airborne carries
-- on the same curve, and it is ray-checked here before launch: the backend
-- cannot raycast, and it moves the actor by teleport, which passes through
-- anything. A hit shortens the flight to stop short of it.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local Owned = require('scripts/Flow/core/owned')
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local Anim = require('scripts/Flow/playerAnim')
local Body = require('scripts/Flow/core/body')
local Geom = require('scripts/Flow/core/geom')

local WallBoostState = BaseState.new("WallBoost", {
    overrides = "movement", teleports = true, anim = "oneshot",
})

-- OpenMW's Constants::GravityConst (8.96) x UnitsPerMeter (69.99).
local GRAVITY = 627.2

local APEX_HEIGHT = 160.0     -- peak height above the launch point
local MIN_STATE_TIME = 0.52   -- hands off to Airborne after this; exit cancels the
                              -- animation, and pwboostbk* is 0.5s
local ARC_SAMPLES = 6
local HIT_MARGIN = 0.05       -- seconds of flight given up before a hit
local MIN_FLIGHT = 0.12       -- shorter than this is not a boost

local ACROBATICS_BONUS = 40

local ARC_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
        + nearby.COLLISION_TYPE.Door,
}

local function arcAt(start, v0, t)
    return start + v0 * t - util.vector3(0, 0, 0.5 * GRAVITY * t * t)
end

-- First time along the arc at which the body would hit something, or nil.
-- Two heights: waist and crown.
local function firstHit(start, v0, flight)
    local waist = util.vector3(0, 0, Body.frac(0.5))
    local crown = util.vector3(0, 0, Body.frac(0.95))
    local prevT, prev = 0, start
    for i = 1, ARC_SAMPLES do
        local t = flight * i / ARC_SAMPLES
        local p = arcAt(start, v0, t)
        if nearby.castRay(prev + waist, p + waist, ARC_RAY_OPTS).hit
           or nearby.castRay(prev + crown, p + crown, ARC_RAY_OPTS).hit then
            return prevT
        end
        prevT, prev = t, p
    end
    return nil
end

local boostApplied = false

local function applyAcrobatics(enable)
    if enable == boostApplied then return end
    Owned.skill('acrobatics', enable and ACROBATICS_BONUS or -ACROBATICS_BONUS)
    boostApplied = enable
end

-- payload { normal, dir } from LedgeHang or Shimmy.
function WallBoostState:canEnter(payload)
    local flat = payload and payload.normal and Geom.flat(payload.normal)
    if not flat then return nil end

    local speed = math.sqrt(2 * GRAVITY * APEX_HEIGHT)
    local v0 = flat * speed + util.vector3(0, 0, speed)
    local start = mwSelf.position

    local flight = MIN_STATE_TIME
    local hitT = firstHit(start, v0, flight)
    if hitT then flight = hitT - HIT_MARGIN end
    if flight < MIN_FLIGHT then return nil end

    return { start = start, velocity = v0, flight = flight, dir = payload.dir or 1 }
end

local timeInState = 0

function WallBoostState:enter(plan)
    SkillCheck.attempt("WallBoost")
    timeInState = 0
    Anim.setVariant(plan.dir < 0 and "left" or "right")
    applyAcrobatics(true)

    core.sendGlobalEvent('FLOW_Boost_Start', {
        actor = mwSelf,
        startPos = plan.start,
        velocity = plan.velocity,
        gravity = GRAVITY,
        duration = plan.flight,
    })
end

function WallBoostState:exit()
    applyAcrobatics(false)
    core.sendGlobalEvent('FLOW_Boost_Cancel', { actor = mwSelf })
end

function WallBoostState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState < MIN_STATE_TIME then return nil end

    if syncData.isGrounded then
        if SkillCheck.botched() then return "Stumble" end
        return "Idle"
    end

    return "Airborne"
end

return WallBoostState
