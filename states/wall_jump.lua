---@omw-context player
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local Owned = require('core/owned')
local BaseState = require('states/base_state')
local Body = require('core/body')

local WallJumpState = BaseState.new("WallJump")

-- Rise clears the 80-110% band that Mantle refuses and LedgeHang cannot reach.
local BASE_RISE_FRAC = 1.05
local RISE_SKILL_GAIN = 0.35
local RISE_SKILL_CAP = 100.0

local BRACE_DURATION = 0.10   -- plant against the wall before the launch
local HOP_DURATION = 0.55     -- ~490 u/s initial, close to a vanilla jump
local STATE_DURATION = BRACE_DURATION + HOP_DURATION + 0.10

-- Gravity keeps accumulating while the hop drives Z absolutely, so without
-- this the actor drops at full accumulated speed the instant it ends - the
-- "sudden teleport" feel. Levitate holds that off; removed on exit.
local LEVITATE_MAG = 200

local ACROBATICS_BONUS = 40

local timeInState = 0
local boostApplied = false
local levitating = false
local hopSent = false
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
    local t = math.min(1.0, math.max(0.0, acro / RISE_SKILL_CAP))
    return Body.frac(BASE_RISE_FRAC) * (1.0 + RISE_SKILL_GAIN * t)
end

function WallJumpState:enter(syncData)
    timeInState = 0
    hopSent = false

    -- Read before the fortify is applied, or the rise compounds it.
    pendingRise = riseHeight()

    applyJumpFortify(true)
    applyLevitate(true)
end

function WallJumpState:exit()
    applyJumpFortify(false)
    applyLevitate(false)
    core.sendGlobalEvent('FLOW_Hop_Cancel', { actor = mwSelf })
end

function WallJumpState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- Brace first, then launch.
    if not hopSent and timeInState >= BRACE_DURATION then
        hopSent = true
        core.sendGlobalEvent('FLOW_Hop_Start', {
            actor = mwSelf,
            rise = pendingRise,
            duration = HOP_DURATION,
        })
    end

    if timeInState >= BRACE_DURATION + HOP_DURATION and syncData.isGrounded then
        return "Idle"
    end

    if timeInState >= STATE_DURATION then
        return "Airborne"
    end

    return nil
end

return WallJumpState
