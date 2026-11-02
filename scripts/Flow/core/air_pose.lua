---@omw-context player
-- Cosmetic airborne poses: Skydive, and the botched-move fall.
--
-- These are NOT states. Airborne stays active and keeps resolving the priority
-- ladder, so a skydive can still be interrupted by a vault, a mantle or a
-- ledge. Nothing here moves the actor: no teleport, no lerp.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local Anim = require('scripts/Flow/playerAnim')
local Owned = require('scripts/Flow/core/owned')
local Settings = require('scripts/Flow/settings')

local AirPose = {}

-- Water entry ends a skydive. No ray: the cell carries a flat water level and
-- position.z is the feet, so the compare is free and fires at the surface,
-- before isSwimming turns true.
local SKYDIVE_ACROBATICS = 250
local SKYDIVE_JUMP = 150
local LATERAL_DEADZONE = 0.35

local mode = nil          -- nil | "Skydive" | "Falling"
local phase = nil
local shown = nil         -- "<mode>/<variant>" actually handed to Anim
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

-- Keyed on what was PLAYED, not on mode/phase: start() sets mode before the
-- first pose, so a nil variant (Falling) compared equal and never played.
local function pose(name, variant, looping)
    local key = name .. "/" .. tostring(variant)
    if shown == key then return end
    shown = key
    phase = variant
    Anim.setPose(name, variant, looping)
end

function AirPose.active()
    return mode
end

function AirPose.inWater()
    if types.Actor.isSwimming(mwSelf) then return true end
    local cell = mwSelf.cell
    -- `hasWater and waterLevel` is FALSE in a dry cell, not nil, and a nil
    -- test let that through to a number-vs-boolean compare that threw every
    -- airborne frame in a waterless interior.
    if not (cell and cell.hasWater and cell.waterLevel) then return false end
    return mwSelf.position.z <= cell.waterLevel
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
    mode, phase, shown = nil, nil, nil
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
