---@omw-context player
-- State interface.
--
--   traits            what the FSM holds for the state, applied on the diff
--                     between the old and new state:
--     overrides       nil | "movement" | "all"  (movement + combat)
--     suspend         true: Levitate holds the actor against gravity
--     teleports       true: the backend moves the actor; EngineSync must not
--                     read the jump as a teleport
--     anim            nil | "oneshot" | "loop"
--     sensors         { forward = true, ledge = true }: run while jump is held
--
--   canEnter(payload, from) -> plan | nil
--                     Optional. Runs BEFORE the current state exits; nil
--                     refuses and nothing changes. The plan is handed to enter.
--   enter(plan, from)
--   exit(to)
--   update(dt, syncData, inputData) -> nextName [, payload]

local BaseState = {}
BaseState.__index = BaseState

function BaseState.new(name, traits)
    return setmetatable({ name = name or "BaseState", traits = traits or {} }, BaseState)
end

function BaseState:enter(plan, from) end
function BaseState:exit(to) end
function BaseState:update(dt, syncData, inputData) return nil end

return BaseState
