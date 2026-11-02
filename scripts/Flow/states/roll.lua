---@omw-context player
-- Landing roll. Committed action; see README.
--
-- Fall damage is the engine's, and the engine reads Acrobatics for it: every
-- point takes 1.5 units off the effective fall and 1% off the damage scale.
-- So the roll is an Acrobatics bonus held across the impact, not a heal after.
-- Airborne arms it on the tap; Roll owns it from touchdown and drops it once
-- the landing damage has been dealt.
local BaseState = require('scripts/Flow/states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Owned = require('scripts/Flow/core/owned')

-- The movement override is load-bearing: it suppresses jump and lets the state
-- drive forward motion itself.
local RollState = BaseState.new("Roll", { overrides = "movement", anim = "oneshot" })

local ROLL_DURATION = 1.07   -- pwroll1's own length, read from the .kf

local ACROBATICS_BONUS = 50
-- Held this long into the roll so the engine's landing frame sees it, whichever
-- side of Lua's update the damage lands on.
local IMPACT_WINDOW = 0.25

local buffApplied = false

function RollState.setBuff(enable)
    if enable == buffApplied then return end
    Owned.skill('acrobatics', enable and ACROBATICS_BONUS or -ACROBATICS_BONUS)
    buffApplied = enable
end

local FORWARD_DRIVE = 1.0

local function interrupted()
    return not types.Actor.canMove(mwSelf)
end

local INTERRUPT_GRACE = 0.1

local timeInState = 0

function RollState:enter()
    timeInState = 0
end

function RollState:exit()
    RollState.setBuff(false)
end

function RollState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if timeInState > IMPACT_WINDOW then RollState.setBuff(false) end

    if timeInState > INTERRUPT_GRACE and interrupted() then
        return "Idle"
    end

    mwSelf.controls.movement = FORWARD_DRIVE
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.run = true
    mwSelf.controls.jump = false

    if timeInState >= ROLL_DURATION then
        return "Idle"
    end

    return nil
end

return RollState
