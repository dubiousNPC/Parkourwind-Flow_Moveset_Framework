---@omw-context player
local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('core/sensor')
local VaultState = require('states/vault')

local IdleState = BaseState.new("Idle")

function IdleState:update(dt, syncData, inputData)
    -- 1. To Airborne
    if not syncData.isGrounded then
        return "Airborne"
    end

    -- 2. Obstacle Handling (Jump Pressed)
    if inputData.jump then
        local fat = types.Actor.stats.dynamic.fatigue(mwSelf).current

        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked() then
            if fat > 5 then return "Vault" end
        elseif Sensor.data.interaction == "Mantle" then
            if fat > 10 then return "Mantle" end
        end
    end

    -- 3. To Sprint (was missing entirely - Sprint was unreachable from a
    -- standing start; this is the actual entry point for the mod's
    -- "hold key to sprint, run at obstacle" flow). Gated on the same
    -- fatigue threshold Sprint's own update() checks, so this doesn't
    -- hand off into a state that immediately bounces back.
    if inputData.sprint and inputData.moveVector.y > 0 then
        local fat = types.Actor.stats.dynamic.fatigue(mwSelf).current
        if fat > 0 then
            return "Idle"
        end
    end

    return nil
end

return IdleState
