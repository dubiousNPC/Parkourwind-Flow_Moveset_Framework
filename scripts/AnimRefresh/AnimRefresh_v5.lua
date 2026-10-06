---@omw-context player
-- AnimRefresh v5: tells subscribers when the player model is rebuilt
-- (first-person boundary, Rest/Travel/Training/Jail, load). See docs/animrefresh.md.
--   I.AnimRefresh.subscribe(key, fn(mode, previousMode) [-> false to retry], { verify = true })
--   I.AnimRefresh.unsubscribe(key)

local camera = require('openmw.camera')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 5

if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then
    return
end

local POLL_INTERVAL = 0.1

local MAX_RETRIES = 2
local RETRY_DELAY = 0.10

local LOAD_DELAYS = { 0.10, 0.60 }

local JOIN_DELAY = 0.10

local VERIFY_DELAY = 1.0

-- UI modes that rebuild the model.
local REBUILD_UI_MODES = {
    Rest     = true,
    Travel   = true,
    Training = true,
    Jail     = true,
}

local subscribers     = {}
local verifiers       = {}
local subscriberCount = 0
local pollTimer       = 0

local function isFirstPerson()
    return camera.getMode() == camera.MODE.FirstPerson
end

local firstPerson = isFirstPerson()
local lastMode    = camera.getMode()

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

local deliver

deliver = function(keys, mode, previous, attempt)
    local notReady = nil

    for key in pairs(keys) do
        local callback = subscribers[key]
        if callback then
            local result = callback(mode, previous)
            if result == false then
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
        for key in pairs(notReady) do
            print("[AnimRefresh] '" .. tostring(key) ..
                  "' still not ready after " .. tostring(MAX_RETRIES + 1) ..
                  " attempts; giving up on this change")
        end
    end
end

local function fire(previous)
    if subscriberCount == 0 then return end
    local all = {}
    for key in pairs(subscribers) do all[key] = true end
    deliver(all, camera.getMode(), previous, 0)
end

local function fireBoundary(previous)
    fire(previous)
    if next(verifiers) == nil then return end
    async:newUnsavableSimulationTimer(VERIFY_DELAY, function()
        local again = nil
        for key in pairs(verifiers) do
            if subscribers[key] then again = again or {}; again[key] = true end
        end
        if again then deliver(again, camera.getMode(), previous, 0) end
    end)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- The poll is the only writer of the baseline.
local function checkBoundary()
    if camera.getQueuedMode() ~= nil then return end

    local mode = camera.getMode()
    local nowFirst = mode == camera.MODE.FirstPerson
    local previous = lastMode
    lastMode = mode

    if nowFirst == firstPerson then return end
    firstPerson = nowFirst
    fireBoundary(previous)
end

local function onUpdate(dt)
    if subscriberCount == 0 then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkBoundary()
end

-- Fires when a rebuilding menu closes.
local function uiModeChanged(data)
    if subscriberCount == 0 then return end
    if data and data.newMode == nil and data.oldMode and REBUILD_UI_MODES[data.oldMode] then
        fire(lastMode)
    end
end

local function onLoad()
    for _, delay in ipairs(LOAD_DELAYS) do
        async:newUnsavableSimulationTimer(delay, function() fire(lastMode) end)
    end
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

local function subscribe(key, callback, opts)
    if type(key) ~= 'string' or key == '' then
        error(("[AnimRefresh] subscribe() needs a non-empty string key, got %s")
              :format(type(key) == 'string' and '""' or type(key)))
    end
    if callback ~= nil and type(callback) ~= 'function' then
        error(("[AnimRefresh] subscribe('%s', ...) needs a function, got %s")
              :format(key, type(callback)))
    end

    if subscribers[key] == nil and callback ~= nil then
        -- 0 -> 1 subscribers: re-baseline.
        if subscriberCount == 0 then
            lastMode    = camera.getMode()
            firstPerson = lastMode == camera.MODE.FirstPerson
            pollTimer   = 0
        end
        subscriberCount = subscriberCount + 1
    elseif subscribers[key] ~= nil and callback == nil then
        subscriberCount = subscriberCount - 1
    end
    subscribers[key] = callback
    verifiers[key] = (callback ~= nil and opts and opts.verify) or nil

    -- One refresh for the joiner alone.
    if callback ~= nil then
        async:newUnsavableSimulationTimer(JOIN_DELAY, function()
            if subscribers[key] then
                deliver({ [key] = true }, camera.getMode(), lastMode, 0)
            end
        end)
    end
end

local function unsubscribe(key)
    if type(key) ~= 'string' or key == '' then return end
    if subscribers[key] == nil then return end
    subscriberCount = subscriberCount - 1
    subscribers[key] = nil
    verifiers[key] = nil
end

-- For model changes this service cannot see.
local function refreshNow()
    fire(lastMode)
end

local function getMode()
    return camera.getMode()
end

local function isFirstPersonNow()
    return firstPerson
end

return {
    interfaceName = "AnimRefresh",
    interface = {
        version       = MY_VERSION,
        subscribe     = subscribe,
        unsubscribe   = unsubscribe,
        refreshNow    = refreshNow,
        getMode       = getMode,
        isFirstPerson = isFirstPersonNow,
    },
    -- An event, not an engine handler. See docs/animrefresh.md.
    eventHandlers = {
        UiModeChanged  = uiModeChanged,
    },
    engineHandlers = {
        onUpdate       = onUpdate,
        onLoad         = onLoad,
    },
}
