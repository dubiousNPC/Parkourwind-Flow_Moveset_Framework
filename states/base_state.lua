---@omw-context player
--- START OF FILE states/base_state.lua ---

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

-- Checks if we can transition INTO this state
-- @param dt: Delta time
-- @param syncData: The read-only data table from EngineSync
-- @param inputData: The input table (Phase 2)
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

-- Called every frame while active
-- Return a string (State Name) to request a transition, or nil to stay
function BaseState:update(dt, syncData, inputData)
    return nil
end

print("[FLOW] BaseState loaded successfully.") -- Debug confirmation
return BaseState