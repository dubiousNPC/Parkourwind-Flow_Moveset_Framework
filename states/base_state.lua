---@omw-context player
-- State interface. Every state inherits enter/exit/update.

local BaseState = {}
BaseState.__index = BaseState

-- Constructor
function BaseState.new(name)
    local new_state = {
        name = name or "BaseState"
    }
    setmetatable(new_state, BaseState)
    return new_state
end

-- Interface Methods (Defaults)

function BaseState:canEnter(dt, syncData, inputData)
    return false
end

-- Called once when entering the state
function BaseState:enter(syncData)
    -- print("[FLOW:FSM] Entered " .. self.name)
end

-- Called once when leaving the state
function BaseState:exit()
    -- Cleanup
end

function BaseState:update(dt, syncData, inputData)
    return nil
end

print("[FLOW] BaseState loaded successfully.") -- Debug confirmation
return BaseState