---@omw-context player
local ui = require('openmw.ui')
local Anim = require('playerAnim')
local Settings = require('settings')

local StateManager = {
    -- Registry of all available states
    states = {},
    activeState = nil,
    
    -- Configuration. Read from the settings menu rather than hardcoded: this
    -- was pinned true, so the per-transition console line below fired for
    -- every player regardless of the debug setting used everywhere else.
    debugMode = false
}

-- Transitions that are part of a continuous action rather than a new one.
-- Shimmy hands back to LedgeHang after every single step, so a held direction
-- re-enters LedgeHang about once per second -- without this the "LEDGE GRAB"
-- banner and the console line repeat for the whole traverse.
local CONTINUATION = {
    LedgeHang = { Shimmy = true },
    Shimmy    = { LedgeHang = true, Shimmy = true },
}

local function isContinuation(nextStateName, prevStateName)
    local from = CONTINUATION[nextStateName]
    return from ~= nil and from[prevStateName] == true
end

-- Initialize with list of state files
function StateManager.init(stateModules)
    print("[FLOW] Initializing State Manager...")
    
    -- Clear old states to ensure a clean slate during hot-reload
    StateManager.states = {} 
    
    -- Load States
    for _, module in pairs(stateModules) do
        if module and module.name then
            StateManager.states[module.name] = module
            print("[FLOW] Registered State: " .. module.name)
        else
            print("[FLOW:Error] Loaded a state module with no 'name' property!")
        end
    end

    -- Default to Idle if available, otherwise first loaded
    if StateManager.states["Idle"] then
        StateManager.setState("Idle", nil)
    else
        print("[FLOW:Error] 'Idle' state not found in registry!")
    end
end

-- Force a state change
function StateManager.setState(nextStateName, syncData)
    local nextState = StateManager.states[nextStateName]
    
    if not nextState then
        print("[FLOW:Error] Attempted to set invalid state: " .. tostring(nextStateName))
        return
    end

    local prevStateName = StateManager.activeState and StateManager.activeState.name or "None"

    -- Exit current
    if StateManager.activeState then
        StateManager.activeState:exit()
    end

    -- Enter new
    StateManager.activeState = nextState
    
    -- Pass syncData to enter()
    StateManager.activeState:enter(syncData)

    -- [FIX] A state may REFUSE on entry - Vault and Mantle both validate their
    -- destination in enter() and set self.abort when the move is not viable.
    -- Announcing and animating regardless is what produced "the message says
    -- MANTLE but nothing moves and no animation plays": the banner fired, the
    -- clip started, and the next tick bounced to Airborne and cancelled it.
    --
    -- An aborted entry now announces nothing and plays nothing. The state
    -- still returns to Airborne on its own next update.
    if StateManager.activeState.abort then
        if Settings.debugMode() then
            ui.printToConsole("[FLOW:FSM] " .. nextStateName .. " REFUSED on entry",
                ui.CONSOLE_COLOR.Failure)
        end
        return
    end

    -- Single choke point for animations - states never call the animation
    -- API themselves, see playerAnim.lua.
    Anim.onStateChange(nextStateName, prevStateName)

    -- Visual Feedback for Parkour Actions. Announce the START of an action,
    -- not every internal step of one.
    local continuation = isContinuation(nextStateName, prevStateName)
    if not continuation then
        if nextStateName == "Vault" or nextStateName == "Mantle" then
            ui.showMessage(">>> ACTION: " .. string.upper(nextStateName) .. " <<<", { showInDialogue = false })
        elseif nextStateName == "LedgeHang" then
            ui.showMessage(">>> ACTION: LEDGE GRAB <<<", { showInDialogue = false })
        end
    end

    -- Console logging for debugging history. Continuations are skipped for the
    -- same reason, so a traverse does not bury the transitions worth seeing.
    if Settings.debugMode() and not continuation then
        ui.printToConsole("[FLOW:FSM] Transition > " .. nextStateName, ui.CONSOLE_COLOR.Success)
    end
end

-- Main Update Loop
function StateManager.update(dt, syncData, inputData)
    if not StateManager.activeState then return end

    -- 1. Let active state run logic
    local requestedState = StateManager.activeState:update(dt, syncData, inputData)

    if requestedState then
        -- The state decided it's done
        StateManager.setState(requestedState, syncData)
        return
    end
end

function StateManager.getActiveStateName()
    return StateManager.activeState and StateManager.activeState.name or "None"
end

return StateManager