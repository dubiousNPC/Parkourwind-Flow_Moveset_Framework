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
local BaseState = require('scripts/Flow/states/base_state')
local Anim = require('scripts/Flow/playerAnim')
local SkillCheck = require('scripts/Flow/core/skill_check')

local StumbleState = BaseState.new("Stumble", { overrides = "movement", anim = "oneshot" })

local DURATION = { stumble = 1.00, knockdown = 1.50 }

local timeInState = 0
local kind = "stumble"

-- payload { kind = "stumble" | "knockdown" }; anything else is a stumble.
function StumbleState:enter(payload)
    timeInState = 0
    kind = (payload and DURATION[payload.kind]) and payload.kind or "stumble"
    SkillCheck.clearBotch()
    Anim.setVariant(kind)
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

return StumbleState
