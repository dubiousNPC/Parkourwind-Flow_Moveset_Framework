---@omw-context player
-- Landing roll. Committed action; see README.
local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local I = require('openmw.interfaces')

local RollState = BaseState.new("Roll")

local ROLL_DURATION = 0.45      -- recovery window before handing back to

local REFUND_MIN = 0.25
local REFUND_MAX = 0.75
local REFUND_SKILL_CAP = 100.0

local DAMAGE_WATCH_WINDOW = 0.25

local pendingHealthBefore = nil

function RollState.setLandingData(healthBefore)
    pendingHealthBefore = healthBefore
end

local FORWARD_DRIVE = 1.0

local function interrupted()
    return not types.Actor.canMove(mwSelf)
end

local INTERRUPT_GRACE = 0.1

local timeInState = 0
local healthBefore = nil
local refundApplied = false

local function refundFraction()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / REFUND_SKILL_CAP))
    return REFUND_MIN + (REFUND_MAX - REFUND_MIN) * t
end

function RollState:enter(syncData)
    timeInState = 0
    refundApplied = false

    healthBefore = pendingHealthBefore
    pendingHealthBefore = nil

    I.Controls.overrideMovementControls(true)
end

function RollState:exit()
    healthBefore = nil
    refundApplied = false
    I.Controls.overrideMovementControls(false)
end

function RollState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState > INTERRUPT_GRACE and interrupted() then
        return "Idle"
    end

    mwSelf.controls.movement = FORWARD_DRIVE
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.jump = false

    mwSelf.controls.run = true

    if not refundApplied and healthBefore and timeInState <= DAMAGE_WATCH_WINDOW then
        local hp = types.Actor.stats.dynamic.health(mwSelf)
        local lost = healthBefore - hp.current

        if lost > 0 then
            -- Don't resurrect: if the fall was fatal, leave it fatal.
            if hp.current > 0 then
                local refund = lost * refundFraction()
                hp.current = math.min(hp.base, hp.current + refund)
            end
            refundApplied = true
        end
    end

    if timeInState >= ROLL_DURATION then
        return "Idle"
    end

    return nil
end

return RollState
