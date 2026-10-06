---@omw-context player
-- State interface. Every state inherits enter/exit/update.

local BaseState = {}
BaseState.__index = BaseState

function BaseState.new(name)
    local new_state = {
        name = name or "BaseState"
    }
    setmetatable(new_state, BaseState)
    return new_state
end

function BaseState:canEnter(dt, syncData, inputData)
    return false
end

function BaseState:enter(syncData)
end

function BaseState:exit()
end

function BaseState:update(dt, syncData, inputData)
    return nil
end

return BaseState