---@omw-context player
-- Cosmetic airborne poses: Dive, Skydive, and the botched-move fall.
--
-- These are NOT states. Airborne stays active and keeps resolving the priority
-- ladder, so a dive or a skydive can still be interrupted by a vault, a mantle,
-- a ledge or a wall jump. Nothing here moves the actor: no teleport, no lerp.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local Anim = require('scripts/Flow/playerAnim')
local Owned = require('scripts/Flow/core/owned')
local Settings = require('scripts/Flow/settings')

local AirPose = {}

-- dbsdive: lead-in 0.633s, then a 0.333s tumble loop, then a 1.0s resolve.
local DIVE_LEAD = 0.633
local DIVE_RESOLVE = 1.00
local DIVE_SPEED_BONUS = 40
local DIVE_SPEED_DURATION = 0.80

-- Ground close enough to resolve out of the tumble.
local GROUND_NEAR = 260.0
local GROUND_CHECK_INTERVAL = 0.15

local SKYDIVE_ACROBATICS = 250
local SKYDIVE_JUMP = 150
local LATERAL_DEADZONE = 0.35

local GROUND_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

local divePending = false

local mode = nil          -- nil | "Dive" | "Skydive" | "Falling"
local phase = nil
local elapsed = 0
local groundTimer = 0
local groundNear = false
local speedApplied = false
local skydiveBoosted = false

local function distanceToGround(limit)
    local pos = mwSelf.position
    local res = nearby.castRay(pos, pos - util.vector3(0, 0, limit), GROUND_RAY_OPTS)
    return res.hit
end

local function applySpeed(enable)
    if enable == speedApplied then return end
    Owned.attribute('speed', enable and DIVE_SPEED_BONUS or -DIVE_SPEED_BONUS)
    speedApplied = enable
end

local function applySkydiveBoost(enable)
    if enable == skydiveBoosted then return end
    local sign = enable and 1 or -1
    Owned.skill('acrobatics', sign * SKYDIVE_ACROBATICS)
    Owned.effect(core.magic.EFFECT_TYPE.Jump, sign * SKYDIVE_JUMP)
    skydiveBoosted = enable
end

local function pose(name, variant, looping)
    if mode == name and phase == variant then return end
    phase = variant
    Anim.setPose(name, variant, looping)
end

-- Roll sets this when a jump lands in its final window; Airborne takes it.
function AirPose.requestDive()
    divePending = true
end

function AirPose.takeDiveRequest()
    local pending = divePending
    divePending = false
    return pending
end

function AirPose.active()
    return mode
end

function AirPose.clear()
    applySpeed(false)
    applySkydiveBoost(false)
    if mode then Anim.clearPose() end
    mode, phase = nil, nil
    elapsed = 0
    groundTimer = 0
    groundNear = false
end

local function start(name)
    AirPose.clear()
    mode = name
    elapsed = 0
end

function AirPose.startDive()
    start("Dive")
    applySpeed(true)
    pose("Dive", "lead", false)
end

function AirPose.startSkydive()
    start("Skydive")
    pose("Skydive", "entry", false)
end

function AirPose.showFalling()
    if mode == "Falling" then return end
    start("Falling")
    pose("Falling", nil, true)
end

local function updateGroundNear(dt)
    groundTimer = groundTimer + dt
    if groundTimer < GROUND_CHECK_INTERVAL then return end
    groundTimer = 0
    groundNear = distanceToGround(GROUND_NEAR)
end

local function updateDive(dt)
    if elapsed >= DIVE_SPEED_DURATION then applySpeed(false) end

    if phase == "lead" then
        if elapsed >= DIVE_LEAD then pose("Dive", "loop", true) end
        return
    end

    if phase == "loop" then
        updateGroundNear(dt)
        if groundNear then pose("Dive", "land", false) end
        return
    end

    if phase == "land" and elapsed >= DIVE_LEAD + DIVE_RESOLVE then
        AirPose.clear()
    end
end

local function updateSkydive(dt, inputData)
    -- Jump cancels, handing the player back to ordinary jump controls.
    if inputData.jumpPressed then
        AirPose.clear()
        return
    end

    local windup = math.max(0.5, Settings.skydiveWindup())
    if phase == "entry" then
        if elapsed >= windup then
            applySkydiveBoost(true)
            pose("Skydive", "loop", true)
        end
        return
    end

    local lateral = inputData.moveVector.x
    if inputData.moveVector.y > 0.1 then
        pose("Skydive", "forward", true)
    elseif lateral > LATERAL_DEADZONE then
        pose("Skydive", "right", true)
    elseif lateral < -LATERAL_DEADZONE then
        pose("Skydive", "left", true)
    else
        pose("Skydive", "loop", true)
    end
end

function AirPose.update(dt, syncData, inputData)
    if not mode then return end

    if syncData.isGrounded then
        AirPose.clear()
        return
    end

    elapsed = elapsed + dt

    if mode == "Dive" then
        updateDive(dt)
    elseif mode == "Skydive" then
        updateSkydive(dt, inputData)
    end
end

function AirPose.debugString()
    if not mode then return "" end
    return string.format("%s/%s %.1f", mode, tostring(phase), elapsed)
end

return AirPose
