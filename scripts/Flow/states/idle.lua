---@omw-context player
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('scripts/Flow/core/sensor')
local VaultState = require('scripts/Flow/states/vault')
local MantleState = require('scripts/Flow/states/mantle')
local LadderState = require('scripts/Flow/states/ladder')

local IdleState = BaseState.new("Idle")

-- Safety net: a botch that never reached a Stumble must not survive into
-- the next jump.
function IdleState:enter(syncData)
    SkillCheck.clearBotch()
end

function IdleState:update(dt, syncData, inputData)
    if not syncData.isGrounded then
        return "Airborne"
    end

    if inputData.jump then
        local fat = types.Actor.stats.dynamic.fatigue(mwSelf).current

        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked(Sensor.data.targetPos) then
            if fat > 5 then return "Vault" end
        elseif Sensor.data.interaction == "Mantle" and not MantleState.isBlocked(Sensor.data.targetPos) then
            if fat > 10 then return "Mantle" end
        end
    end

    if inputData.moveVector.y > 0.1 then
        local lp, ln = LadderState.probe()
        if lp then
            LadderState.setLadder(lp, ln)
            return "Ladder"
        end
    end

    return nil
end

return IdleState
