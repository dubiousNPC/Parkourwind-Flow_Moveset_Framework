---@omw-context player
-- Skydive. A sustained fall from real height: skydive1's windup, then its own
-- loop keys as the idle, with steering on the movement keys. See README.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local Anim = require('scripts/Flow/playerAnim')
local Owned = require('scripts/Flow/core/owned')
local BaseState = require('scripts/Flow/states/base_state')
local Settings = require('scripts/Flow/settings')
local SkillCheck = require('scripts/Flow/core/skill_check')

local SkydiveState = BaseState.new("Skydive")

-- skydive1's windup is 10s of clip, longer than any fall here; see README.
local WINDUP_CLIP = 10.0

-- Air below needed before a fall counts as a skydive. One ray per check.
local MIN_CLEARANCE = 1400.0

local ACROBATICS_BONUS = 250
local JUMP_BONUS = 150

-- Forward dive. Teleports are paid only while the key is held.
local DIVE_FORWARD = 700.0
local DIVE_DOWN = 450.0
local GLIDE_REFRESH = 0.25
local GLIDE_GRAVITY = 120.0

local LATERAL_DEADZONE = 0.35

-- Ground coming up: hand back so Roll and LedgeHang still get their chance.
local CLEARANCE_RECHECK = 0.30

local timeInState = 0
local inLoop = false
local boosted = false
local variant = nil
local glideTimer = 0
local gliding = false
local clearanceTimer = 0

local DOWN_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

-- Public: Airborne asks before paying for the transition.
function SkydiveState.hasClearance()
    local pos = mwSelf.position
    local res = nearby.castRay(pos, pos - util.vector3(0, 0, MIN_CLEARANCE), DOWN_RAY_OPTS)
    return not res.hit
end

local function applyBoost(enable)
    if enable == boosted then return end
    local sign = enable and 1 or -1
    Owned.skill('acrobatics', sign * ACROBATICS_BONUS)
    Owned.effect(core.magic.EFFECT_TYPE.Jump, sign * JUMP_BONUS)
    boosted = enable
end

local function stopGlide()
    if not gliding then return end
    gliding = false
    core.sendGlobalEvent('FLOW_Move_Cancel', { actor = mwSelf })
end

local function driveForward()
    local yaw = mwSelf.rotation:getYaw()
    local fwd = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
    core.sendGlobalEvent('FLOW_Glide_Start', {
        actor = mwSelf,
        velocity = fwd * DIVE_FORWARD - util.vector3(0, 0, DIVE_DOWN),
        gravity = GLIDE_GRAVITY,
        maxDuration = GLIDE_REFRESH * 2,
    })
    gliding = true
    glideTimer = 0
end

local function setVariant(name)
    if variant == name then return end
    variant = name
    Anim.setVariant(name)
    Anim.replay(true)
end

function SkydiveState:enter(syncData)
    timeInState = 0
    inLoop = false
    variant = nil
    gliding = false
    glideTimer = 0
    clearanceTimer = 0

    if SkillCheck.evaluate("Skydive") ~= "ok" then
        self.abort = true
        return
    end
    self.abort = false

    variant = "entry"
    Anim.setVariant("entry")
end

function SkydiveState:exit()
    applyBoost(false)
    stopGlide()
    variant = nil
    inLoop = false
end

function SkydiveState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end

    timeInState = timeInState + dt

    if syncData.isGrounded then return "Idle" end

    clearanceTimer = clearanceTimer + dt
    if clearanceTimer >= CLEARANCE_RECHECK then
        clearanceTimer = 0
        if not SkydiveState.hasClearance() then return "Airborne" end
    end

    -- The windup is the entry clip's own length, scaled to the setting.
    if not inLoop then
        local windup = math.max(0.5, Settings.skydiveWindup())
        if timeInState >= windup then
            inLoop = true
            applyBoost(true)
            setVariant("loop")
        end
        return nil
    end

    local lateral = inputData.moveVector.x
    local forward = inputData.moveVector.y

    if forward > 0.1 then
        setVariant("forward")
        glideTimer = glideTimer + dt
        if not gliding or glideTimer >= GLIDE_REFRESH then driveForward() end
    elseif lateral > LATERAL_DEADZONE then
        stopGlide()
        setVariant("right")
    elseif lateral < -LATERAL_DEADZONE then
        stopGlide()
        setVariant("left")
    else
        stopGlide()
        setVariant("loop")
    end

    return nil
end

function SkydiveState.getDebug()
    return string.format("SKY: %s t=%.1f%s", variant or "-", timeInState,
        gliding and " glide" or "")
end

return SkydiveState
