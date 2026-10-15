---@omw-context player
local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('core/sensor')
local VaultState = require('states/vault')
local MantleState = require('states/mantle')
local LadderState = require('states/ladder')

local IdleState = BaseState.new("Idle")

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
