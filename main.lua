---@omw-context player
local core = require('openmw.core')
local ui = require('openmw.ui')
local input = require('openmw.input')
local self = require('openmw.self')
local I = require('openmw.interfaces')

-- Import Modules
local EngineSync = require('core/engine_sync')
local StateManager = require('core/state_manager')
local InputManager = require('core/input')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local DebugHUD = require('core/debug_hud')
local Anim = require('playerAnim')
local Settings = require('settings')
local H3 = require('core/h3lp_compat')

-- Import States
local IdleState = require('states/idle')
local AirborneState = require('states/airborne')
local MantleState = require('states/mantle')
local VaultState = require('states/vault')
local LedgeHangState = require('states/ledge_hang')
local RollState = require('states/roll')
local ShimmyState = require('states/shimmy')
local WallBoostState = require('states/wall_boost')
-- WallJump has been removed entirely - it never worked as intended and
-- was the source of the repeating on-screen message and the T-pose (its
-- configured animation group had no matching clip, and its one-shot
-- playBlended masked out vanilla's own animation with nothing to
-- replace it).
-- WallRun is optional and not loaded by default.
-- See states/optional/README.md to bring it back.

local REGISTERED_STATES = {
    IdleState,
    AirborneState,
    MantleState,
    VaultState,
    LedgeHangState,
    RollState,
    ShimmyState,
    WallBoostState
}

-- =================================================================
-- DEBUG HUD THROTTLE
-- =================================================================
-- The HUD used to be hardcoded on and updated OUTSIDE the idle throttle,
-- so every frame it built several strings and forced a UI redraw even
-- while the rest of the pipeline was correctly throttled. It also made
-- the sensor resolve object names (getObjectName -> pcall + record
-- lookup) purely to feed a debug string. It's now off by default, and
-- when on it refreshes at a readable 10Hz rather than every frame.
local DEBUG_HUD_INTERVAL = 0.1
local debugTick = H3.every(DEBUG_HUD_INTERVAL)
local debugWasEnabled = false

-- =================================================================
-- PERFORMANCE THROTTLE
-- =================================================================
-- The full pipeline (Sensor raycasts, SensorExt's LedgeHang fallback,
-- StateManager.update) only runs at full rate while the active state is
-- something other than Idle - which is exactly what holding Sprint (or
-- being mid-action) gives you. While genuinely idle, it only runs on this
-- throttled tick instead. EngineSync/InputManager stay untouched every
-- frame regardless - they're cheap (no raycasts) and keep isGrounded/
-- velocity/input state accurate for whenever the throttled tick does fire.
--
-- inputData.jump and inputData.sprint are level-triggered (true for as
-- long as the key is held), so a throttled tick can't miss a press
-- outright - but it could still delay noticing one by up to
-- IDLE_THROTTLE_INTERVAL, which is exactly the moment reactivity matters
-- most (the player just pressed jump at a ledge from a standing start).
-- InputManager.intents.jumpPressed/sprintPressed are cheap edge triggers
-- (a couple of boolean comparisons, no raycasts) that force an
-- unthrottled tick on the exact frame the key goes down, so the full
-- pipeline still only runs at the throttled rate while genuinely idle,
-- but never adds latency to the moment the player actually acts.
local IDLE_THROTTLE_INTERVAL = 0.15
local idleTick = H3.every(IDLE_THROTTLE_INTERVAL)

-- States permitted to hold I.Controls overrides. Anything else gets them
-- cleared every tick by the safety net in onUpdate.
--
-- overrideMovementControls(true) suppresses JUMP as well as movement, so a
-- state left without its exit() running leaves the jump key dead until some
-- later state happens to clear it. Asserting the correct value from one place
-- costs two boolean writes and makes the fault unable to outlive a tick.
local OVERRIDE_STATES = {
    Vault = true, Mantle = true, LedgeHang = true,
    Shimmy = true, WallBoost = true,
}

local function onInit()
    print("[FLOW] Cold Init...")
    EngineSync.init()
    StateManager.init(REGISTERED_STATES)
    -- HUD is created lazily by DebugHUD.update() only when the debug
    -- setting is on; nothing to create here.
end

-- Runs once all of the player's local scripts have loaded, which is the
-- documented-safe point to touch I.SharedRay: if another mod bundles a
-- newer SharedRay_v2.lua, the version race between copies has already
-- resolved by the time onActive fires.
local function onActive()
    Sensor.registerSharedRay()
end

local function onUpdate(dt)
    if StateManager.getActiveStateName() == "None" then
        EngineSync.init()
        StateManager.init(REGISTERED_STATES)
        -- One-shot console probe: reports which configured animation groups
        -- actually exist on this actor. Runs here rather than in onInit
        -- because the player's animation object is reliably present by the
        -- first frame.
        -- Guarded: the log showed "attempt to call field 'verifyGroups'
        -- (a nil value)" killing onUpdate outright when main.lua and
        -- playerAnim.lua were from different builds. A diagnostic must never
        -- be able to take down the update loop.
        if Anim.verifyGroups then Anim.verifyGroups() end
        if StateManager.getActiveStateName() == "None" then return end
    end

    if not Settings.modEnabled() then return end
    if Settings.disableInInteriors() and self.cell and not self.cell.isExterior then return end

    EngineSync.update(dt)
    InputManager.update()

    local activeName = StateManager.getActiveStateName()
    if not OVERRIDE_STATES[activeName] then
        I.Controls.overrideMovementControls(false)
        I.Controls.overrideCombatControls(false)
    end

    -- Throttle gate. The dedicated Sprint state and its hotkey existed only to
    -- keep this pipeline unthrottled; vanilla's run flag says the same thing,
    -- picks up Always Run, and costs no keybind. Read as a control rather than
    -- an ACTION because Always Run makes the action momentary; only consulted
    -- while Idle, where nothing has overridden the controls.
    -- `self`, not `mwSelf`. Every other file in this mod requires openmw.self
    -- as `mwSelf`; main.lua is the one that names it `self` (line 5), so this
    -- line -- written in the siblings' idiom -- referenced an undeclared
    -- global. Indexing nil raised every frame, and because the throw is here,
    -- nothing below it ran: Sensor, SensorExt, StateManager and the debug HUD
    -- were all dead while init still logged normally.
    local isIdle = activeName == "Idle" and not self.controls.run
    local justActed = InputManager.intents.jumpPressed
    if not isIdle or idleTick() or justActed then
        Sensor.update(dt, InputManager.intents, EngineSync.data)
        SensorExt.updateLedgeHang(dt, InputManager.intents, EngineSync.data)
        StateManager.update(dt, EngineSync.data, InputManager.intents)
    end

    local debugOn = Settings.debugMode()
    if debugOn then
        if debugTick() then
            -- Third line: roll tap count and arm state, so an arming
            -- failure is visible instead of silent.
            DebugHUD.update(
                StateManager.getActiveStateName(),
                Sensor.getDebugString(),
                AirborneState.getRollDebug()
            )
        end
    elseif debugWasEnabled then
        -- Turned off mid-session - tear the HUD down rather than leaving
        -- a frozen readout on screen.
        DebugHUD.destroy()
    end
    debugWasEnabled = debugOn
end

return {
    engineHandlers = {
        onInit = onInit,
        onActive = onActive,
        -- onUpdate, NOT onFrame. onUpdate is paused-aware; onFrame runs even
        -- while the world is paused. Two reasons this matters:
        --
        -- 1. CORRECTNESS. global/flow_amf_backend.lua drives the Vault and
        --    Mantle tweens from its own onUpdate. With this side on onFrame
        --    the two halves disagreed about pause: pausing mid-vault froze
        --    the global tween while this side's timer kept counting, so
        --    VaultState:update hit its duration, exited, and fired
        --    FLOW_Vault_Cancel on a tween that never reached progress >= 1.0
        --    - the "vault comes up short" failure COMPLETION_GRACE exists to
        --    prevent, which no grace value could have fixed because the two
        --    clocks were simply different.
        --
        -- 2. COST. Menus, inventory, dialogue and barter are a large share of
        --    real playtime, and none of the sensor raycasts, engine calls or
        --    state ticks need to happen during them.
        --
        -- Nothing here needs to run while paused: FLOW writes no per-frame
        -- controls (that is what would justify onFrame, and is why
        -- surfAnimations keeps its control writes there). core/input.lua's
        -- I.UI.getMode() guard still covers UI modes that do NOT pause.
        --
        -- dt is now simulation time rather than frame time, so state timers
        -- respect the game's time scaling.
        onUpdate = onUpdate
    }
}
