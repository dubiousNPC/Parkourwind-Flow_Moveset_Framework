---@omw-context player
-- WallJump. Two beats: a braced pause against the wall, then a boost if the
-- player presses jump again during it. See README.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local Owned = require('scripts/Flow/core/owned')
local BaseState = require('scripts/Flow/states/base_state')
local Body = require('scripts/Flow/core/body')
local Anim = require('scripts/Flow/playerAnim')
local SensorExt = require('scripts/Flow/core/optional/sensor_ext')
local SkillCheck = require('scripts/Flow/core/skill_check')

local WallJumpState = BaseState.new("WallJump")

-- The brace IS the input window. pwwalljump1 is 0.333s, launch clips 0.5s.
local BRACE_DURATION = 0.333
local LAUNCH_DURATION = 0.50
local STATE_TAIL = 0.10

local RISE_FRAC = 1.05
local RISE_SKILL_GAIN = 0.35
local SKILL_CAP = 100.0

-- Lateral launch: an arc away from the wall rather than a vertical hop.
local LATERAL_APEX = 120.0
local LATERAL_SPEED = 420.0
local LATERAL_DEADZONE = 0.35
local YAW_FULL = math.rad(35)   -- camera swing that counts as full lateral intent

local LEVITATE_MAG = 200
local ACROBATICS_BONUS = 40

local timeInState = 0
local braceSent = false
local launched = false
local launchDir = nil
local boostApplied = false
local levitating = false
local entryYaw = 0
local wallNormal = nil
local pendingRise = 0

local function applyLevitate(enable)
    if enable == levitating then return end
    Owned.effect(core.magic.EFFECT_TYPE.Levitate, enable and LEVITATE_MAG or -LEVITATE_MAG)
    levitating = enable
end

local function applyJumpFortify(enable)
    if enable == boostApplied then return end
    local amount = enable and ACROBATICS_BONUS or -ACROBATICS_BONUS
    Owned.skill('acrobatics', amount)
    Owned.effect(core.magic.EFFECT_TYPE.Jump, amount)
    boostApplied = enable
end

local function riseHeight()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / SKILL_CAP))
    return Body.frac(RISE_FRAC) * (1.0 + RISE_SKILL_GAIN * t)
end

local function rightVector()
    return util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(1, 0, 0))
end

local function yawDelta()
    local d = mwSelf.rotation:getYaw() - entryYaw
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return d
end

-- "up" unless steering sideways AND the wall is on the other side.
local function resolveLaunch(inputData)
    local lateral = inputData.moveVector.x
    if math.abs(lateral) < LATERAL_DEADZONE then
        lateral = yawDelta() / YAW_FULL
    end
    if math.abs(lateral) < LATERAL_DEADZONE then return "up" end
    if not wallNormal then return "up" end

    -- wallNormal points out of the wall, so a positive dot puts the wall left.
    local away = rightVector():dot(wallNormal)
    if math.abs(away) < 0.2 then return "up" end
    if (lateral > 0) == (away > 0) then
        return lateral > 0 and "right" or "left"
    end
    return "up"
end

function WallJumpState.setWallNormal(normal)
    wallNormal = normal
end

function WallJumpState:enter(syncData)
    timeInState = 0
    braceSent = false
    launched = false
    launchDir = nil
    entryYaw = mwSelf.rotation:getYaw()
    self.abort = false
    SkillCheck.attempt("WallJump")

    -- Read before the fortify, or the rise compounds it.
    pendingRise = riseHeight()

    -- Side detection is WallRun's: one ray per side, cast once, here only.
    SensorExt.updateWallRun(0, nil, syncData)
    if SensorExt.data.wallRun.side ~= "None" then
        wallNormal = SensorExt.data.wallRun.normal
    end

    applyJumpFortify(true)
    applyLevitate(true)
    I.Controls.overrideMovementControls(true)

    Anim.setVariant("brace")
end

function WallJumpState:exit()
    applyJumpFortify(false)
    applyLevitate(false)
    I.Controls.overrideMovementControls(false)
    wallNormal = nil
    core.sendGlobalEvent('FLOW_Move_Cancel', { actor = mwSelf })
end

local function launch(dir)
    launched = true
    launchDir = dir
    if dir == "up" then
        core.sendGlobalEvent('FLOW_Hop_Start', {
            actor = mwSelf, rise = pendingRise, duration = LAUNCH_DURATION,
        })
    else
        local push = rightVector() * ((dir == "right") and LATERAL_SPEED or -LATERAL_SPEED)
        core.sendGlobalEvent('FLOW_Boost_Start', {
            actor = mwSelf,
            apexHeight = LATERAL_APEX,
            pushVelocity = push,
            maxDuration = LAUNCH_DURATION,
        })
    end

    Anim.setVariant(dir)
    Anim.replay(true)
end

function WallJumpState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end

    timeInState = timeInState + dt
    mwSelf.controls.jump = false

    if not braceSent then
        braceSent = true
        core.sendGlobalEvent('FLOW_Brace_Start', {
            actor = mwSelf, duration = BRACE_DURATION,
        })
    end

    if not launched then
        -- The second press. jumpPressed is an edge, so holding does nothing.
        if inputData.jumpPressed and timeInState <= BRACE_DURATION then
            launch(resolveLaunch(inputData))
        elseif timeInState > BRACE_DURATION then
            return "Airborne"   -- braced and let go; no boost earned
        end
        return nil
    end

    if timeInState >= BRACE_DURATION + LAUNCH_DURATION and syncData.isGrounded then
        return "Idle"
    end

    if timeInState >= BRACE_DURATION + LAUNCH_DURATION + STATE_TAIL then
        return "Airborne"
    end

    return nil
end

function WallJumpState.getLaunchDebug()
    return launchDir or (launched and "?" or "brace")
end

return WallJumpState
