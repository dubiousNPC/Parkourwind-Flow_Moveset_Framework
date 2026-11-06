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

-- ---------------------------------------------------------------------------
-- YIELDING TO ANOTHER MOD
-- ---------------------------------------------------------------------------
-- Mods that take hold of the player -- a mount, a boat's helm, a caravan, a
-- grappling hook -- leave the actor not grounded for as long as they hold it,
-- and FLOW reads not grounded as a jump in progress. Unasked, it ran the whole
-- airborne ladder on a rider: the mount's jump (the same key) grabbed a ledge
-- off the saddle, a falling mount played Skydive and landed as a knockdown,
-- a hookshot hang's releasing Jump chained into a FLOW grab.
--
-- So a mod that holds the player says so, and FLOW stands down to Idle and
-- does nothing until every holder has let go:
--
--     if I.Flow then I.Flow.yield('MyMod') end    -- BEFORE writing the
--     ...                                          -- override flag
--     if I.Flow then I.Flow.resume('MyMod') end
--
-- ORDER MATTERS. overrideMovementControls is one flag shared by every mod.
-- Standing down releases FLOW's own hold on it; yielding first means that
-- write happens before the holder's, not over it.
--
-- Per owner, so two mods (a hookshot fired from the saddle) cannot release
-- each other. Not saved: every holder re-takes the player on load through its
-- own restore path, and a stale yield would switch FLOW off for good.
--
-- The Flow_Yield event { owner, yield } does the same for a script that cannot
-- or will not depend on the interface (a global script, via player:sendEvent).
local yields = {}
local yieldCount = 0
local resumePending = false

local function yield(owner)
    assert(owner ~= nil, "I.Flow.yield needs an owner name")
    if yields[owner] then return end
    yields[owner] = true
    yieldCount = yieldCount + 1
    if yieldCount == 1 then
        -- Now, not next frame: the caller writes the override flag next.
        standDown()
        InputManager.reset()
    end
end

local function resume(owner)
    if owner == nil or not yields[owner] then return end
    yields[owner] = nil
    yieldCount = yieldCount - 1
    -- A jump still held from the hold (the press that released a hookshot
    -- hang, a mount's jump) is not a new request. Applied on the next update,
    -- where input is read.
    if yieldCount == 0 then resumePending = true end
end

local function isYielded()
    return yieldCount > 0
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
    yields, yieldCount, resumePending = {}, 0, false
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

    -- Ground and velocity stay current while yielded, so the first frame
    -- after a hold ends reads the actor as it is, not as it was.
    EngineSync.update(dt)
    if yieldCount > 0 then
        if StateManager.getActiveStateName() ~= "Idle" then standDown() end
        return
    end
    if resumePending then
        resumePending = false
        InputManager.latchJump()
    end
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
    interfaceName = "Flow",
    interface = {
        version = 1,
        yield = yield,
        resume = resume,
        isYielded = isYielded,
        getState = function() return StateManager.getActiveStateName() end,
    },
    eventHandlers = {
        Flow_Yield = function(data)
            if type(data) ~= "table" or data.owner == nil then return end
            if data.yield == false then resume(data.owner) else yield(data.owner) end
        end,
    },
    engineHandlers = {
        onInit = onInit,
        onActive = onActive,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
    }
}
