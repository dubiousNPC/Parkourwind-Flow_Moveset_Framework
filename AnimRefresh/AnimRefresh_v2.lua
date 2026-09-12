---@omw-context player
--[[

]]

local camera = require('openmw.camera')
local input  = require('openmw.input')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 2

if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then
    return
end


local SETTLE_DELAY = 0.10

-- Backstop poll rate for mode changes that arrive without a TogglePOV press.
local POLL_INTERVAL = 1.0

local subscribers   = {}
local subscriberCount = 0
local lastMode      = camera.getMode()
local pollTimer     = 0
local pendingSettle = false

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

local MAX_RETRIES = 1
local RETRY_DELAY = 0.10

local deliver   -- forward declaration: deliver reschedules itself

deliver = function(keys, mode, previous, attempt)
    local notReady = nil

    for key in pairs(keys) do

        local callback = subscribers[key]
        if callback then
            local ok, result = pcall(callback, mode, previous)
            if not ok then
                print("[AnimRefresh] callback error in '" .. tostring(key) .. "': " .. tostring(result))
            elseif result == false then
                notReady = notReady or {}
                notReady[key] = true
            end
        end
    end

    if not notReady then return end

    if attempt < MAX_RETRIES then
        async:newUnsavableSimulationTimer(RETRY_DELAY, function()
            deliver(notReady, mode, previous, attempt + 1)
        end)
    else
        -- Say so rather than dropping it silently. A subscriber still not ready
        -- here has a real problem and this is the only place it is visible.
        for key in pairs(notReady) do
            print("[AnimRefresh] '" .. tostring(key) ..
                  "' still not ready after " .. tostring(MAX_RETRIES + 1) ..
                  " attempts; giving up on this change")
        end
    end
end

-- A subscriber blowing up must not stop delivery to the others, same rule
-- SharedRay applies to its callbacks.
local function fire(mode, previous)
    local all = {}
    for key in pairs(subscribers) do all[key] = true end
    deliver(all, mode, previous, 0)
end

local function scheduleRefresh(previous)
    if pendingSettle then return end   -- collapse a burst of changes into one
    pendingSettle = true
    async:newUnsavableSimulationTimer(SETTLE_DELAY, function()
        pendingSettle = false
        local mode = camera.getMode()
        lastMode = mode
        if subscriberCount == 0 then return end
        fire(mode, previous)
    end)
end

local function checkMode()
    local mode = camera.getMode()
    if mode == lastMode then return end
    local previous = lastMode
    lastMode = mode
    scheduleRefresh(previous)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------


if input.triggers and input.triggers.TogglePOV then
    input.registerTriggerHandler("TogglePOV", async:callback(function()
        if subscriberCount == 0 then return end
        -- The mode has not actually changed yet at trigger time, so schedule
        -- off the press rather than comparing modes here.
        scheduleRefresh(lastMode)
    end))
end

local function onUpdate(dt)
    if subscriberCount == 0 then return end

    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkMode()
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

local function subscribe(key, callback)
    if not key then return end
    if subscribers[key] == nil and callback ~= nil then
        subscriberCount = subscriberCount + 1
    elseif subscribers[key] ~= nil and callback == nil then
        subscriberCount = subscriberCount - 1
    end
    subscribers[key] = callback
    -- Re-baseline so a subscriber joining just after a switch does not get an
    -- immediate spurious refresh for a change it was never present for.
    lastMode = camera.getMode()
    pollTimer = 0
end

local function unsubscribe(key)
    subscribe(key, nil)
end

local function refreshNow()
    scheduleRefresh(lastMode)
end

local function getMode()
    return lastMode
end

return {
    interfaceName = "AnimRefresh",
    interface = {
        version     = MY_VERSION,
        subscribe   = subscribe,
        unsubscribe = unsubscribe,
        refreshNow  = refreshNow,
        getMode     = getMode,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
