---@omw-context player
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local BaseState = require('states/base_state')
local Body = require('core/body')

local WallJumpState = BaseState.new("WallJump")

-- Rise clears the 80-110% band that Mantle refuses and LedgeHang cannot reach.
local BASE_RISE_FRAC = 1.05
local RISE_SKILL_GAIN = 0.35
local RISE_SKILL_CAP = 100.0

local HOP_DURATION = 0.30
local STATE_DURATION = 0.50   -- outlasts the hop so pwwalljump1 stays visible

local ACROBATICS_BONUS = 40

local timeInState = 0
local boostApplied = false

local function applyJumpFortify(enable)
    if enable == boostApplied then return end
    local sign = enable and 1 or -1

    local skill = types.NPC.stats.skills.acrobatics(mwSelf)
    skill.modifier = skill.modifier + (sign * ACROBATICS_BONUS)

    local fx = types.Actor.activeEffects(mwSelf)
    if fx then
        fx:modify(sign * ACROBATICS_BONUS, core.magic.EFFECT_TYPE.Jump)
    end

    boostApplied = enable
end

local function riseHeight()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / RISE_SKILL_CAP))
    return Body.frac(BASE_RISE_FRAC) * (1.0 + RISE_SKILL_GAIN * t)
end

function WallJumpState:enter(syncData)
    timeInState = 0

    -- Read before the fortify is applied, or the rise compounds it.
    local rise = riseHeight()

    applyJumpFortify(true)

    core.sendGlobalEvent('FLOW_Hop_Start', {
        actor = mwSelf,
        rise = rise,
        duration = HOP_DURATION,
    })
end

function WallJumpState:exit()
    applyJumpFortify(false)
    core.sendGlobalEvent('FLOW_Hop_Cancel', { actor = mwSelf })
end

function WallJumpState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState >= HOP_DURATION and syncData.isGrounded then
        return "Idle"
    end

    if timeInState >= STATE_DURATION then
        return "Airborne"
    end

    return nil
end

return WallJumpState
