---@omw-context player
-- Stumble. The landing after a botched manoeuvre: dbsfall, controls held.
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')

local StumbleState = BaseState.new("Stumble")

local STUMBLE_DURATION = 1.00   -- dbsfall's own length

local timeInState = 0

function StumbleState:enter(syncData)
    timeInState = 0
    self.abort = false
    SkillCheck.clearBotch()
    I.Controls.overrideMovementControls(true)
end

function StumbleState:exit()
    I.Controls.overrideMovementControls(false)
end

function StumbleState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- A real knockdown or death takes over; nothing to hold on to here.
    if not types.Actor.canMove(mwSelf) then return "Idle" end

    mwSelf.controls.movement = 0
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.jump = false
    mwSelf.controls.run = false

    if timeInState >= STUMBLE_DURATION then return "Idle" end

    return nil
end

return StumbleState
