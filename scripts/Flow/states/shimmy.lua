---@omw-context player
-- Shimmy. Lateral steps along a held ledge, carried by the backend.
--
-- Not engine sideMovement: in THIRD person the engine moves the actor by the
-- movement clip's speed, and while pwshimmy* holds the legs there is none.
-- Measured: the step stood still for ~0.7 s, then `walkright` took over and
-- lurched 47 units in two frames before the snap pulled it back to 30. First
-- person moved because .1st movement does not depend on that clip. A backend
-- Glide (straight line, no gravity) moves both views the same.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local Anim = require('scripts/Flow/playerAnim')
local Geom = require('scripts/Flow/core/geom')

-- Same traits as LedgeHang, so a step costs no Levitate or override churn.
local ShimmyState = BaseState.new("Shimmy", {
    overrides = "all", suspend = true, anim = "oneshot", teleports = true,
})

local STEP_DISTANCE = 30.0   -- units per step, roughly a hitbox width
local STEP_TIME = 0.5        -- seconds per step; pwshimmy* (1.07 s) is played to fit it
local STEP_TIMEOUT = 2.0

local LIP_PROBE_UP = 30.0    -- start the lip probe this far above the lip
local LIP_PROBE_DOWN = 40.0  -- and end it this far below
local BODY_CLEARANCE = 25.0  -- lateral clearance the torso needs to exist

local RAY_OPTS = { ignore = mwSelf }

local function lateralVector(wallNormal)
    local flat = Geom.flat(wallNormal)
    return flat and util.vector3(-flat.y, flat.x, 0)
end

-- payload { lip, normal, dir } from LedgeHang. Refuses when the next 30 units
-- have no body room or no lip.
function ShimmyState:canEnter(payload)
    if not (payload and payload.lip and payload.normal) then return nil end
    local lateral = lateralVector(payload.normal)
    if not lateral then return nil end

    local pos = mwSelf.position
    local offset = lateral * (STEP_DISTANCE * payload.dir)

    if nearby.castRay(pos, pos + offset + (lateral * (BODY_CLEARANCE * payload.dir)), RAY_OPTS).hit then
        return nil
    end

    local stepLip = payload.lip + offset
    local lipRes = nearby.castRay(
        util.vector3(stepLip.x, stepLip.y, stepLip.z + LIP_PROBE_UP),
        util.vector3(stepLip.x, stepLip.y, stepLip.z - LIP_PROBE_DOWN), RAY_OPTS)
    if not lipRes.hit then return nil end
    if lipRes.hitNormal and lipRes.hitNormal.z < 0.7 then return nil end

    return { dir = payload.dir, normal = payload.normal, lip = lipRes.hitPos,
             startPos = pos, endPos = pos + offset }
end

local timeInState = 0
local step = nil
local climbQueued = false

function ShimmyState:enter(plan)
    SkillCheck.attempt("Shimmy")
    timeInState = 0
    step = plan
    climbQueued = false
    Anim.setVariant(plan.dir < 0 and "left" or "right")
    Anim.fitNext(STEP_TIME)
    core.sendGlobalEvent('FLOW_Glide_Start', {
        actor = mwSelf,
        velocity = (plan.endPos - plan.startPos) / STEP_TIME,
        gravity = 0,
        maxDuration = STEP_TIME,
    })
end

function ShimmyState:exit()
    core.sendGlobalEvent('FLOW_Move_Cancel', { actor = mwSelf })
    mwSelf.controls.sideMovement = 0
    step = nil
end

function ShimmyState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- A PRESS: the grab was made with jump held. See ledge_hang.lua.
    -- With a direction held it is a boost, as from the hang. Without one it
    -- is the hang's climb, kept until the step lands: a step now lasts
    -- STEP_TIME, and a climb pressed during it used to become a WallBoost
    -- off the wall.
    if inputData.jumpPressed then
        if math.abs(inputData.moveVector.x) > 0.1 then
            return "WallBoost", { normal = step.normal, dir = step.dir }
        end
        climbQueued = true
    end

    if inputData.crouch then
        return "Airborne"
    end

    mwSelf.controls.sideMovement = 0
    mwSelf.controls.movement = 0
    mwSelf.controls.jump = false

    local travelled = (mwSelf.position - step.startPos):length()
    if travelled >= STEP_DISTANCE - 1 or timeInState >= STEP_TIME + 0.1 or timeInState >= STEP_TIMEOUT then
        if travelled < STEP_DISTANCE * 0.5 then
            core.sendGlobalEvent('FLOW_SnapTo', {
                actor = mwSelf, position = step.endPos, rotation = mwSelf.rotation,
            })
        end
        if climbQueued then
            return "Mantle", { ledge = step.lip, vouched = true }
        end
        return "LedgeHang", { lip = step.lip, normal = step.normal, dir = step.dir }
    end
end

return ShimmyState
