---@omw-context player
-- FSM. Single choke point for transitions and animation.
local ui = require('openmw.ui')
local Anim = require('playerAnim')
local Settings = require('settings')

local StateManager = {
    states = {},
    activeState = nil,
}

local CONTINUATION = {
    LedgeHang = { Shimmy = true },
    Shimmy    = { LedgeHang = true },
}

local function isContinuation(nextStateName, prevStateName)
    local from = CONTINUATION[nextStateName]
    return from ~= nil and from[prevStateName] == true
end

function StateManager.init(stateModules)
    StateManager.states = {}

    for _, module in pairs(stateModules) do
        if module and module.name then
            StateManager.states[module.name] = module
        else
            print("[FLOW:Error] Loaded a state module with no 'name' property!")
        end
    end

    if StateManager.states["Idle"] then
        StateManager.setState("Idle", nil)
    else
        print("[FLOW:Error] 'Idle' state not found in registry!")
    end
end

function StateManager.setState(nextStateName, syncData)
    local nextState = StateManager.states[nextStateName]

    if not nextState then
        print("[FLOW:Error] Attempted to set invalid state: " .. tostring(nextStateName))
        return
    end

    if not Settings.stateEnabled(nextStateName) then
        if Settings.debugMode() then
            ui.printToConsole("[FLOW:FSM] " .. nextStateName .. " DISABLED in settings",
                ui.CONSOLE_COLOR.Info)
        end
        return
    end

    local prevStateName = StateManager.activeState and StateManager.activeState.name or "None"

    if StateManager.activeState then
        StateManager.activeState:exit()
    end

    StateManager.activeState = nextState
    StateManager.activeState:enter(syncData)

    if StateManager.activeState.abort then
        if Settings.debugMode() then
            ui.printToConsole("[FLOW:FSM] " .. nextStateName .. " REFUSED on entry",
                ui.CONSOLE_COLOR.Error)
        end
        return
    end

    Anim.onStateChange(nextStateName, prevStateName)

    local continuation = isContinuation(nextStateName, prevStateName)
    local debugOn = Settings.debugMode()

    if debugOn and not continuation then
        if nextStateName == "Vault" or nextStateName == "Mantle" then
            ui.showMessage(">>> ACTION: " .. string.upper(nextStateName) .. " <<<", { showInDialogue = false })
        elseif nextStateName == "LedgeHang" then
            ui.showMessage(">>> ACTION: LEDGE GRAB <<<", { showInDialogue = false })
        end
    end

    if debugOn and not continuation then
        ui.printToConsole("[FLOW:FSM] Transition > " .. nextStateName, ui.CONSOLE_COLOR.Success)
    end
end

function StateManager.update(dt, syncData, inputData)
    if not StateManager.activeState then return end

    local requestedState = StateManager.activeState:update(dt, syncData, inputData)
    if requestedState then
        StateManager.setState(requestedState, syncData)
    end
end

function StateManager.getActiveStateName()
    return StateManager.activeState and StateManager.activeState.name or "None"
end

return StateManager