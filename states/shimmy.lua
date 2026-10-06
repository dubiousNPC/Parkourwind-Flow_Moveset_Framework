---@omw-context player
-- Shimmy. Engine-driven lateral steps along a held ledge.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')
local BaseState = require('states/base_state')
local Anim = require('playerAnim')
local WallBoostState = require('states/wall_boost')
local Settings = require('settings')
local Owned = require('core/owned')

local ShimmyState = BaseState.new("Shimmy")

local STEP_DISTANCE = 30.0   -- units per step, roughly a hitbox width

local SIDE_DRIVE = 1.0

local STEP_TIMEOUT = 2.0

local LIP_PROBE_UP = 30.0    -- start the lip probe this far above the lip
local LIP_PROBE_DOWN = 40.0  -- and end it this far below
local BODY_CLEARANCE = 25.0  -- lateral clearance the torso needs to exist

local RAY_OPTS = { ignore = mwSelf }

local pendingDir = 0          -- -1 = left, +1 = right
local pendingWallNormal = nil
local pendingLip = nil        -- lip probeStep found for the destination

function ShimmyState.setStep(dir, wallNormal, lipPos)
    pendingDir = dir
    pendingWallNormal = wallNormal
    pendingLip = lipPos
end

local resultLip = nil
local resultNormal = nil

function ShimmyState.consumeResultLip()
    local lip, normal = resultLip, resultNormal
    resultLip, resultNormal = nil, nil
    return lip, normal
end

function ShimmyState.lateralVector(wallNormal)
    local flat = util.vector3(wallNormal.x, wallNormal.y, 0)
    if flat:length() < 0.01 then return nil end
    flat = flat:normalize()
    -- Perpendicular in the XY plane.
    return util.vector3(-flat.y, flat.x, 0)
end

function ShimmyState.probeStep(playerPos, lipPos, wallNormal, dir)
    if not Settings.stateEnabled("Shimmy") then return nil end

    if not playerPos or not lipPos then return nil end

    local lateral = ShimmyState.lateralVector(wallNormal)
    if not lateral then return nil end

    local offset = lateral * (STEP_DISTANCE * dir)

    local clearFrom = playerPos
    local clearTo   = playerPos + offset + (lateral * (BODY_CLEARANCE * dir))
    local clearRes  = nearby.castRay(clearFrom, clearTo, RAY_OPTS)
    if clearRes.hit then return nil end

    local stepLip = lipPos + offset
    local probeTop    = util.vector3(stepLip.x, stepLip.y, stepLip.z + LIP_PROBE_UP)
    local probeBottom = util.vector3(stepLip.x, stepLip.y, stepLip.z - LIP_PROBE_DOWN)
    local lipRes = nearby.castRay(probeTop, probeBottom, RAY_OPTS)
    if not lipRes.hit then return nil end

    if lipRes.hitNormal and lipRes.hitNormal:dot(util.vector3(0, 0, 1)) < 0.7 then
        return nil
    end

    return lipRes.hitPos
end

local timeInState = 0
local dir = 0
local startPos = nil
local endPos = nil
local wallNormal = nil
local lastStepDir = 0

function ShimmyState.clearLastDirection()
    lastStepDir = 0
end

-- Direction of the last step on this ledge, kept after the step ends.
function ShimmyState.lastDirection()
    return lastStepDir
end

local GRAVITY_MAGNITUDE = 200

local suspensionApplied = false

local function applySuspension(enable)
    if enable == suspensionApplied then
        I.Controls.overrideMovementControls(enable)
        I.Controls.overrideCombatControls(enable)
        return
    end
    suspensionApplied = enable
    Owned.effect(core.magic.EFFECT_TYPE.Levitate, enable and GRAVITY_MAGNITUDE or -GRAVITY_MAGNITUDE)
    I.Controls.overrideMovementControls(enable)
    I.Controls.overrideCombatControls(enable)
end

function ShimmyState:enter(syncData)
    timeInState = 0
    dir = pendingDir
    lastStepDir = dir
    wallNormal = pendingWallNormal

    local variant = dir < 0 and "left" or "right"
    Anim.setVariant(variant)

    startPos = mwSelf.position
    local lateral = ShimmyState.lateralVector(wallNormal)
    endPos = lateral and (startPos + lateral * (STEP_DISTANCE * dir)) or startPos

    -- Held until exit, then handed to LedgeHang.
    resultLip = pendingLip
    resultNormal = wallNormal

    applySuspension(true)

    pendingDir = 0
    pendingWallNormal = nil
    pendingLip = nil
end

function ShimmyState:exit()
    mwSelf.controls.sideMovement = 0
    applySuspension(false)
    startPos = nil
    endPos = nil
    dir = 0
end

function ShimmyState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if inputData.jump and Settings.stateEnabled("WallBoost") then
        WallBoostState.setLaunch(wallNormal, dir)
        resultLip, resultNormal = nil, nil
        return "WallBoost"
    end

    if inputData.crouch then
        resultLip, resultNormal = nil, nil
        return "Airborne"
    end

    if not startPos or not endPos then
        return "LedgeHang"
    end

    mwSelf.controls.sideMovement = dir * SIDE_DRIVE
    mwSelf.controls.movement = 0
    mwSelf.controls.jump = false

    local travelled = (mwSelf.position - startPos):length()
    if travelled >= STEP_DISTANCE or timeInState >= STEP_TIMEOUT then
        if travelled < STEP_DISTANCE * 0.5 and endPos then
            core.sendGlobalEvent('FLOW_SnapTo', {
                actor = mwSelf,
                position = endPos,
                rotation = mwSelf.rotation,
            })
        end
        return "LedgeHang"
    end

    return nil
end

return ShimmyState
