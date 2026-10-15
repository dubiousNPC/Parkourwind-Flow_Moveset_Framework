---@omw-context player
-- FLOW entry point. Registers states, drives the pipeline, owns the throttle.
local self = require('openmw.self')
local I = require('openmw.interfaces')

local EngineSync = require('scripts/Flow/core/engine_sync')
local StateManager = require('scripts/Flow/core/state_manager')
local InputManager = require('scripts/Flow/core/input')
local Sensor = require('scripts/Flow/core/sensor')
local SensorExt = require('scripts/Flow/core/optional/sensor_ext')
local DebugHUD = require('scripts/Flow/core/debug_hud')
local Owned = require('scripts/Flow/core/owned')
local Anim = require('scripts/Flow/playerAnim')
local Settings = require('scripts/Flow/settings')
local H3 = require('scripts/Flow/core/h3lp_compat')

local IdleState = require('scripts/Flow/states/idle')
local AirborneState = require('scripts/Flow/states/airborne')
local MantleState = require('scripts/Flow/states/mantle')
local VaultState = require('scripts/Flow/states/vault')
local LedgeHangState = require('scripts/Flow/states/ledge_hang')
local RollState = require('scripts/Flow/states/roll')
local LadderState = require('scripts/Flow/states/ladder')
local ShimmyState = require('scripts/Flow/states/shimmy')
local WallBoostState = require('scripts/Flow/states/wall_boost')
local WallJumpState = require('scripts/Flow/states/wall_jump')

local REGISTERED_STATES = {
    IdleState,
    AirborneState,
    MantleState,
    VaultState,
    LedgeHangState,
    RollState,
    LadderState,
    ShimmyState,
    WallBoostState,
    WallJumpState
}

local DEBUG_HUD_INTERVAL = 0.1
local debugTick = H3.every(DEBUG_HUD_INTERVAL)
local debugWasEnabled = false

local IDLE_THROTTLE_INTERVAL = 0.15
local idleTick = H3.every(IDLE_THROTTLE_INTERVAL)

local OVERRIDE_STATES = {
    Vault = true, Mantle = true, LedgeHang = true,
    Shimmy = true, WallBoost = true, Ladder = true,
    Roll = true,
}

local overrideHeld = false
local wasActive = true

local function releaseOverrides()
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
end

local function standDown()
    if StateManager.getActiveStateName() ~= "Idle" then
        StateManager.setState("Idle")
    end
    if overrideHeld then
        releaseOverrides()
        overrideHeld = false
    end
end

local function onInit()
    EngineSync.init()
    StateManager.init(REGISTERED_STATES)
end

local function onActive()
    Sensor.registerSharedRay()
    Anim.registerAnimRefresh()
end

local function onSave()
    return { owned = Owned.save() }
end

local function onLoad(data)
    Owned.undo(data and data.owned)
end

local function onUpdate(dt)
    if StateManager.getActiveStateName() == "None" then
        EngineSync.init()
        StateManager.init(REGISTERED_STATES)
        if Anim.verifyGroups then Anim.verifyGroups() end
        if StateManager.getActiveStateName() == "None" then return end
    end

    local active = Settings.modEnabled()
        and not (Settings.disableInInteriors() and self.cell and not self.cell.isExterior)
    if not active then
        if wasActive then standDown() end
        wasActive = false
        return
    end
    wasActive = true

    EngineSync.update(dt)
    InputManager.update()

    local activeName = StateManager.getActiveStateName()
    local isIdle = activeName == "Idle" and not self.controls.run
    local justActed = InputManager.intents.jumpPressed
    if not isIdle or idleTick() or justActed then
        Sensor.update(dt, InputManager.intents, EngineSync.data)
        SensorExt.updateLedgeHang(dt, InputManager.intents, EngineSync.data)
        StateManager.update(dt, EngineSync.data, InputManager.intents)
    end

    -- Same frame as the exit, so no other script can take the flag in between.
    if OVERRIDE_STATES[StateManager.getActiveStateName()] then
        overrideHeld = true
    elseif overrideHeld then
        releaseOverrides()
        overrideHeld = false
    end

    local debugOn = Settings.debugMode()
    if debugOn then
        if debugTick() then
            DebugHUD.update(
                StateManager.getActiveStateName(),
                Sensor.getDebugString(),
                AirborneState.getRollDebug()
            )
        end
    elseif debugWasEnabled then
        DebugHUD.destroy()
    end
    debugWasEnabled = debugOn
end

return {
    engineHandlers = {
        onInit = onInit,
        onActive = onActive,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    }
}
