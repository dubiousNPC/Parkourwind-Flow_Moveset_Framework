---@omw-context player
-- FSM. Single choke point for transitions, the engine-side holds a state
-- declares in its traits, and animation.
local core = require('openmw.core')
local ui = require('openmw.ui')
local I = require('openmw.interfaces')
local Anim = require('scripts/Flow/playerAnim')
local Settings = require('scripts/Flow/settings')
local Owned = require('scripts/Flow/core/owned')
local EngineSync = require('scripts/Flow/core/engine_sync')

local StateManager = {
    states = {},
    activeState = nil,
}

local LEVITATE_MAG = 200
local NO_TRAITS = {}

-- What the FSM currently holds. overrideMovementControls is ONE shared flag:
-- it is written only when this changes, so FLOW never releases another mod's
-- override while it sits in a state that holds none.
local held = { movement = false, combat = false, suspend = false, teleports = false }

local function applyTraits(t)
    t = t or NO_TRAITS
    local movement = t.overrides ~= nil
    local combat = t.overrides == "all"
    if movement ~= held.movement then
        I.Controls.overrideMovementControls(movement)
        held.movement = movement
    end
    if combat ~= held.combat then
        I.Controls.overrideCombatControls(combat)
        held.combat = combat
    end
    local suspend = t.suspend == true
    if suspend ~= held.suspend then
        Owned.effect(core.magic.EFFECT_TYPE.Levitate, suspend and LEVITATE_MAG or -LEVITATE_MAG)
        held.suspend = suspend
    end
    local teleports = t.teleports == true
    if teleports ~= held.teleports then
        EngineSync.suspendTeleportDetection(teleports)
        held.teleports = teleports
    end
end

-- Steps along one ledge are one continuous hang; no announcement between them.
local CONTINUATION = {
    LedgeHang = { Shimmy = true },
    Shimmy    = { LedgeHang = true },
}

local lastRefusal = nil

local function debugPrint(text, colour)
    if Settings.debugMode() then ui.printToConsole(text, colour) end
end

function StateManager.init(stateModules)
    StateManager.states = {}
    for _, module in pairs(stateModules) do
        -- traits is indexed unguarded in setState. BaseState.new defaults it,
        -- so this only catches a hand-rolled module - which would otherwise
        -- crash the transition rather than warn here.
        if module and module.name and type(module.traits) == "table" then
            StateManager.states[module.name] = module
        else
            print("[FLOW:Error] state module rejected: needs 'name' and a "
                .. "'traits' table (got name=" .. tostring(module and module.name)
                .. ", traits=" .. type(module and module.traits) .. ")")
        end
    end

    if StateManager.states["Idle"] then
        StateManager.setState("Idle")
    else
        print("[FLOW:Error] 'Idle' state not found in registry!")
    end
end

-- Returns true if the transition happened.
function StateManager.setState(nextStateName, payload)
    local nextState = StateManager.states[nextStateName]
    if not nextState then
        print("[FLOW:Error] Attempted to set invalid state: " .. tostring(nextStateName))
        return false
    end

    if not Settings.stateEnabled(nextStateName) then return false end

    local prev = StateManager.activeState
    local prevName = prev and prev.name or "None"

    -- Refusal happens here, while the current state is still intact. A state
    -- that refused inside enter() stayed active for a frame and ran its exit:
    -- cancel events, override toggles, camera resets for a move that never
    -- started.
    local plan = payload
    if nextState.canEnter then
        plan = nextState:canEnter(payload, prevName)
        if plan == nil then
            local msg = nextStateName .. " refused from " .. prevName
            if msg ~= lastRefusal then
                lastRefusal = msg
                debugPrint("[FLOW:FSM] " .. msg, ui.CONSOLE_COLOR.Error)
            end
            return false
        end
    end
    lastRefusal = nil

    if prev then prev:exit(nextStateName) end
    StateManager.activeState = nextState
    applyTraits(nextState.traits)
    nextState:enter(plan, prevName)

    Anim.onStateChange(nextStateName, prevName, nextState.traits.anim)

    local continuation = CONTINUATION[nextStateName] and CONTINUATION[nextStateName][prevName]
    if not continuation then
        debugPrint("[FLOW:FSM] Transition > " .. nextStateName, ui.CONSOLE_COLOR.Success)
    end
    return true
end

-- First of `names` that accepts wins. For a state's update to offer several
-- targets in priority order and carry on itself if every one refuses:
--     if StateManager.tryAny(RUNGS) then return end
function StateManager.tryAny(names, payload)
    for i = 1, #names do
        if StateManager.setState(names[i], payload) then return true end
    end
    return false
end

function StateManager.update(dt, syncData, inputData)
    local state = StateManager.activeState
    if not state then return end

    local requested, payload = state:update(dt, syncData, inputData)
    -- The update may already have transitioned through tryAny.
    if requested and StateManager.activeState == state then
        StateManager.setState(requested, payload)
    end
end

function StateManager.getActiveState()
    return StateManager.activeState
end

function StateManager.getActiveStateName()
    return StateManager.activeState and StateManager.activeState.name or "None"
end

return StateManager
