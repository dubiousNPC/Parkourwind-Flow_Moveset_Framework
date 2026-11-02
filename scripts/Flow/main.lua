---@omw-context player
-- FLOW entry point. Registers states and drives the pipeline.
local self = require('openmw.self')

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
local StumbleState = require('scripts/Flow/states/stumble')

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
    StumbleState
}

local DEBUG_HUD_INTERVAL = 0.1
local debugTick = H3.every(DEBUG_HUD_INTERVAL)
local debugWasEnabled = false

local wasActive = true

-- Leaving the active state releases whatever its traits held (overrides,
-- Levitate), so switching FLOW off never strands either.
local function standDown()
    if StateManager.getActiveStateName() ~= "Idle" then
        StateManager.setState("Idle")
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

-- Sensors run on demand: only for a state that reads them, and only while jump
-- is held, because every consumer acts on held jump. The forward scan alone is
-- 3 rays a frame with nothing ahead and up to 7 plus a navmesh query facing a
-- wall.
--
-- Debug mode runs them regardless, so the HUD stays live - which means DEBUG
-- MODE CHANGES DETECTION, not just display. Anything reading Sensor.data
-- outside a jump-held frame works with the HUD on and sees a reset table in
-- play. tools/check_sensors.py holds the line: a read outside canEnter needs
-- the trait.
local function runSensors(dt, state, intents, debugOn)
    local want = state and state.traits.sensors
    local asked = want and (intents.jump or debugOn)
    if asked and want.forward then
        Sensor.update(dt, intents, EngineSync.data)
    else
        Sensor.reset()
    end
    if asked and want.ledge then
        SensorExt.updateLedgeHang(dt, intents, EngineSync.data)
    else
        SensorExt.reset()
    end
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

    local debugOn = Settings.debugMode()

    EngineSync.update(dt)
    InputManager.update()
    runSensors(dt, StateManager.getActiveState(), InputManager.intents, debugOn)
    StateManager.update(dt, EngineSync.data, InputManager.intents)

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
