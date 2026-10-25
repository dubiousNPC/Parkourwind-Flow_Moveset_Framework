---@omw-context player
-- Cosmetic airborne poses: Skydive, and the botched-move fall.
--
-- These are NOT states. Airborne stays active and keeps resolving the priority
-- ladder, so a skydive can still be interrupted by a vault, a mantle or a
-- ledge. Nothing here moves the actor: no teleport, no lerp.
--
-- Dive lived here until v0.82; see states/optional/dive_pose.lua.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local Anim = require('scripts/Flow/playerAnim')
local Owned = require('scripts/Flow/core/owned')
local Settings = require('scripts/Flow/settings')

local AirPose = {}

local SKYDIVE_ACROBATICS = 250
local SKYDIVE_JUMP = 150
local LATERAL_DEADZONE = 0.35

local mode = nil          -- nil | "Skydive" | "Falling"
local phase = nil
local elapsed = 0
local skydiveBoosted = false
local skydiveReleased = false
local landingPending = false

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

function AirPose.active()
    return mode
end

-- Latched when a released skydive touches down, because update() clears the
-- pose on the same frame Airborne wants to read it.
function AirPose.takeSkydiveLanding()
    local pending = landingPending
    landingPending = false
    return pending
end

function AirPose.clear()
    applySkydiveBoost(false)
    if mode then Anim.clearPose() end
    mode, phase = nil, nil
    elapsed = 0
    skydiveReleased = false
end

local function start(name)
    AirPose.clear()
    mode = name
    elapsed = 0
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

local function updateSkydive(dt, inputData)
    -- Jump cancels, handing the player back to ordinary jump controls.
    if inputData.jumpPressed then
        AirPose.clear()
        return
    end

    -- skydive1 is the windup; `skydive` is a separate looping group, so the
    -- hand-over is a group change rather than a key change on one clip.
    if phase == "entry" then
        if elapsed >= math.max(0.5, Settings.skydiveWindup()) then
            skydiveReleased = true
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
        if mode == "Skydive" and skydiveReleased then landingPending = true end
        AirPose.clear()
        return
    end

    elapsed = elapsed + dt

    if mode == "Skydive" then updateSkydive(dt, inputData) end
end

function AirPose.debugString()
    if not mode then return "" end
    return string.format("%s/%s %.1f%s", mode, tostring(phase), elapsed,
        skydiveReleased and " REL" or "")
end

return AirPose
