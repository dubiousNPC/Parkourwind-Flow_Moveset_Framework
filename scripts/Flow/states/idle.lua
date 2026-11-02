---@omw-context player
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local StateManager = require('scripts/Flow/core/state_manager')

local IdleState = BaseState.new("Idle", { sensors = { forward = true } })

-- Lowest first; each target's canEnter decides. No fatigue gate here: an empty
-- bar lowers the skill check, it never takes the move away (skill_check.lua).
local JUMP_RUNGS = { "Vault", "Mantle" }

-- Safety net: a botch that never reached a Stumble must not survive into
-- the next jump.
function IdleState:enter()
    SkillCheck.clearBotch()
end

function IdleState:update(dt, syncData, inputData)
    if not syncData.isGrounded then
        return "Airborne"
    end

    if inputData.jump and StateManager.tryAny(JUMP_RUNGS) then return end

    if inputData.moveVector.y > 0.1 then
        return "Ladder"
    end
end

return IdleState
