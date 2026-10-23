---@omw-context player
-- Landing roll. Committed action; see README.
local BaseState = require('scripts/Flow/states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local I = require('openmw.interfaces')
local Settings = require('scripts/Flow/settings')
local AirPose = require('scripts/Flow/core/air_pose')

local RollState = BaseState.new("Roll")

local ROLL_DURATION = 1.07   -- pwroll1's own length, read from the .kf

local REFUND_MIN = 0.25
local REFUND_MAX = 0.75
local REFUND_SKILL_CAP = 100.0

local DAMAGE_WATCH_WINDOW = 0.25

-- Jump inside this much of the end carries into a Dive.
local DIVE_WINDOW = 0.30

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
local diveArmed = false

local function refundFraction()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local t = math.min(1.0, math.max(0.0, acro / REFUND_SKILL_CAP))
    return REFUND_MIN + (REFUND_MAX - REFUND_MIN) * t
end

function RollState:enter(syncData)
    timeInState = 0
    refundApplied = false
    diveArmed = false

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

    if not diveArmed and inputData.jumpPressed
       and timeInState >= ROLL_DURATION - DIVE_WINDOW then
        diveArmed = true
    end

    mwSelf.controls.movement = FORWARD_DRIVE
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.run = true

    -- Jump is suppressed for the whole roll but the dive: there the press goes
    -- straight to the engine, so the dive is a native jump with no teleport.
    mwSelf.controls.jump = diveArmed

    -- Hand over the moment the feet leave the ground, so the pose starts with
    -- the jump rather than whenever the clip happens to run out.
    if diveArmed and not syncData.isGrounded then
        AirPose.requestDive()
        return "Airborne"
    end

    if not refundApplied and healthBefore and timeInState <= DAMAGE_WATCH_WINDOW then
        local hp = types.Actor.stats.dynamic.health(mwSelf)
        local lost = healthBefore - hp.current

        if lost > 0 then
            -- Don't resurrect: if the fall was fatal, leave it fatal.
            if hp.current > 0 then
                local refund = lost * refundFraction()
                hp.current = math.min(hp.base + hp.modifier, hp.current + refund)
            end
            refundApplied = true
        end
    end

    if timeInState >= ROLL_DURATION then
        if diveArmed then
            AirPose.requestDive()
            return "Airborne"
        end
        return "Idle"
    end

    return nil
end

return RollState
