---@omw-context player
-- The landing you did not choose. Two presentations, one mechanism:
--   "stumble"   - dbsfall, after a botched manoeuvre
--   "knockdown" - pwfalling at Scripted priority, after a skydive
--
-- There is no Lua setter for an engine knockdown; canMove() only reads one. So
-- this holds the controls for the clip's length instead, which does not depend
-- on the fall damage landing hard enough.
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local BaseState = require('scripts/Flow/states/base_state')
local Anim = require('scripts/Flow/playerAnim')
local SkillCheck = require('scripts/Flow/core/skill_check')

local StumbleState = BaseState.new("Stumble")

local DURATION = { stumble = 1.00, knockdown = 1.50 }

local timeInState = 0
local kind = "stumble"
local pending = nil

function StumbleState.request(which)
    pending = DURATION[which] and which or "stumble"
end

function StumbleState:enter(syncData)
    timeInState = 0
    self.abort = false
    kind = pending or "stumble"
    pending = nil
    SkillCheck.clearBotch()
    I.Controls.overrideMovementControls(true)
    Anim.setVariant(kind)
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

    if timeInState >= DURATION[kind] then return "Idle" end

    return nil
end

function StumbleState.getDebug()
    return string.format("%s %.2f", kind, timeInState)
end

return StumbleState
