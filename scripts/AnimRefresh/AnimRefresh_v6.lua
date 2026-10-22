---@omw-context player
-- AnimRefresh v6: tells subscribers when the player model is rebuilt
-- (first-person boundary, Rest/Travel/Training/Jail/ChargenRace, load).
-- See docs/animrefresh.md.
--   I.AnimRefresh.subscribe(key, fn(mode, previousMode, meta) [-> false to retry],
--                           { verify = true })
--   I.AnimRefresh.unsubscribe(key)
--   I.AnimRefresh.refreshNow([detail])
--
-- TRANCHES 1-3 of the v6 fix list: items 8, 3, 12, 7, then 1, 2, 4, 11, then 5 and 9.
--
-- The first two callback arguments are unchanged, so a two-argument consumer written
-- against v5 keeps working untouched; `meta` (item 9) is additive and ignorable.
--
-- Still open, by design: item 6 (type hints - pending the sentinel experiment),
-- item 13 (retiring a superseded provider's handlers), items 10, 15, 16.

local camera = require('openmw.camera')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 6

-- Item 8 (provider guard). The interface is userdata, not a table, so it must not be
-- type-checked as one - only its `version` field is inspected, and only as a number.
-- A foreign provider with a missing or non-numeric version used to break the comparison
-- outright and take this script's startup with it.
do
    local existing = I.AnimRefresh
    if existing ~= nil then
        local theirVersion = existing.version
        if type(theirVersion) == 'number' then
            if theirVersion >= MY_VERSION then
                return -- a compatible equal or newer provider is already published
            end
        else
            -- Overwriting is still the lesser harm here: a non-numeric version cannot be
            -- shown to be newer, and standing down would leave every consumer on a
            -- service of unknown contract. Loud, never silent.
            print("[AnimRefresh] an existing AnimRefresh provider reports version " ..
                  tostring(theirVersion) .. " (" .. type(theirVersion) ..
                  "), which is not a number; publishing v" .. MY_VERSION ..
                  " over it. The other provider's handlers and timers are NOT retired " ..
                  "(v6 fix list item 13).")
        end
    end
end

local POLL_INTERVAL = 0.1

-- Item 1 (camera phase). Dispatch is deferred with a zero-delay simulation timer created
-- from onUpdate, an event handler or onLoad. Traced in OpenMW f4bec414:
--
--   engine.cpp::frame()      230 synchronizedUpdate (onFrame, queued actions)
--                            302 mWorld->update          <- the camera rebuild lands here
--                            352 LuaWorker allowUpdate -> LuaManager::update()
--   LuaManager::update()     processTimers -> events -> engine handlers -> onUpdate
--
-- processTimers runs *before* onUpdate within the same LuaManager::update(), so a timer
-- created in onUpdate cannot fire in that pass. It fires in the next frame's
-- processTimers, which is after the next frame's line 302 - i.e. after the rebuild that
-- the boundary was inferred from. That is the whole of the G2 fix.
--
-- Note the asymmetry the engine imposes: updateTimerQueue is a `while` loop over a heap,
-- so a timer created *inside* a timer callback with a deadline already past is popped in
-- the same pass. Deferral therefore only buys a phase guarantee when the episode is
-- raised from onUpdate/event/onLoad, which is where every camera boundary is raised.
local DISPATCH_DELAY = 0

local JOIN_DELAY = 0.10
local LOAD_DELAY = 0.10

-- Item 10. Chosen from recorded in-game measurement, not from a guess, and deliberately
-- not a universal safety bound - the gate rejects one and the data agrees.
--
-- Four SentinelProbe sessions (2026-10-16) recorded 64 model rebuilds on the player, each
-- detected directly as a cleared animation state rather than inferred. The 60 gaps between
-- consecutive rebuilds are bimodal:
--
--   rapid follow-on (<= 2s)   n=20   min 0.20  median 0.84  p90 1.78  max 1.95
--   independent     (> 2s)    n=40   min 2.14  median 11.48 max 119.67
--
-- Only the first population is reachable by a verification: the second is independent
-- user-driven activity - opening inventory, changing stance - uniformly spread over tens of
-- seconds, which no bounded delay covers and none should try to. Sizing against the rapid
-- population, 1.8s covers 95% of it and 2.0s all 20 observations, where v5's 1.0s covers
-- 55%. 1.8s is the p90/p95 knee; past 2.0s the delay buys nothing and only widens the
-- window in which a one-shot consumer may already have expired.
local VERIFY_DELAY = 1.8

-- Item 11. A load or a join is one reconciliation of existing desired state, so its
-- retries stretch further rather than being repeated as fresh notices. This covers the
-- window v5 reached with a second load delivery at 0.60 while emitting one notice.
local RETRY_DELAYS = {
    boundary = { 0.10, 0.10 },
    menu     = { 0.10, 0.10 },
    manual   = { 0.10, 0.10 },
    verify   = { 0.10, 0.10 },
    reconcile = { 0.10, 0.20, 0.40 },
}

-- Item 5. UI modes that rebuild the model. These are *latched* when seen, and acted on
-- when gameplay resumes, because the close of a rebuilding menu is not observable as
-- "newMode == nil" in general:
--
--   Travel and Training are pushed from inside the dialogue window
--   (mwgui/dialogue.cpp:453 and :462, pushGuiMode(GM_Travel|GM_Training, mPtr)), so the
--   stack is {Dialogue, Travel} and closing the window pops to Dialogue, not to nothing.
--   The event for that pop carries newMode == "Dialogue". v5's precondition therefore
--   could never fire for either of them - that is G1, and it is structural rather than a
--   timing accident. Rest (mwinput/actionmanager.cpp:226) and Jail
--   (mwgui/windowmanagerimp.cpp:1545) are pushed over nothing, which is exactly why those
--   two did work in v5.
--
-- ChargenRace is included because changing race replaces the body model outright.
local LATCH_UI_MODES = {
    Rest        = true,
    Travel      = true,
    Training    = true,
    Jail        = true,
    ChargenRace = true,
}

-- Item 3 (registration identity). `registrations[key]` holds the token of the live
-- registration for that key. Every subscribe() mints a fresh token, so deferred work
-- captured against an older registration can be recognised and dropped even when the
-- key has been reused by a different owner.
local registrations   = {}   -- key -> token (an opaque table)
local callbacks       = {}   -- token -> function
local verifiers       = {}   -- token -> true
local verifyDelays    = {}   -- token -> that subscriber's own verification delay (item 10)
local inFlight        = {}   -- token -> episode id, while its callback is running
local subscriberCount = 0
local pollTimer       = 0

-- Item 3 (episode identity). One episode per reconciliation cause. `latestCause` is the
-- id of the most recent cause; deferred work from a superseded episode is dropped rather
-- than replayed, which is what stops a retry landing after - and overwriting the meaning
-- of - a newer boundary.
local episodeCounter = 0
local latestCause    = 0

-- Item 12 (bounded reentrancy).
local dispatching = false

-- Item 11 (join/load coalescing).
local pendingReconcile = nil   -- set of keys awaiting one primary reconciliation

-- Item 5 (menu latch). `menuLatch` is a set of mode names seen since gameplay was last
-- running; `menuLatchOrder` keeps them in the order first seen so the metadata can name
-- them. Both are nil when nothing is latched.
local menuLatch      = nil
local menuLatchOrder = nil

-- Item 9, for the coalesced reconcile episode (item 11).
local pendingReconcileOrigin = nil

local function isFirstPersonMode(mode)
    return mode == camera.MODE.FirstPerson
end

-- The poll's baseline. Deliberately not what isFirstPerson() reports - see item 7.
local baselineFirstPerson = isFirstPersonMode(camera.getMode())
local lastMode            = camera.getMode()

-- ---------------------------------------------------------------------------
-- EPISODES
-- ---------------------------------------------------------------------------

local function newEpisode(reason, mode, previous, recipients, origin, detail)
    episodeCounter = episodeCounter + 1
    local episode = {
        id         = episodeCounter,
        reason     = reason,
        mode       = mode,
        previous   = previous,
        recipients = recipients,
        retries    = RETRY_DELAYS[reason] or RETRY_DELAYS.boundary,
        -- Item 9. Recorded on the episode and copied into a fresh table per delivery.
        origin     = origin,
        detail     = detail,
    }
    if reason == 'reconcile' then
        -- A join or load reconciles state that is already desired; it reports no
        -- transition and does not supersede anything. Both halves of its
        -- (mode, previousMode) resolve at dispatch, because freezing only `previous`
        -- would let a non-crossing change (ThirdPerson -> Preview, which fires no
        -- boundary) deliver mode ~= previous and read as one.
        episode.cause    = latestCause
        episode.liveMode = true
    else
        latestCause   = episode.id
        episode.cause = episode.id
    end
    return episode
end

-- Deferred work is only still wanted if no newer cause has happened since.
local function episodeIsCurrent(episode)
    return latestCause == episode.cause
end

local function captureAll()
    local recipients = {}
    for key, token in pairs(registrations) do recipients[key] = token end
    return recipients
end

local function forget(key)
    local token = registrations[key]
    if token == nil then return false end
    registrations[key] = nil
    callbacks[token]   = nil
    verifiers[token]   = nil
    verifyDelays[token] = nil
    inFlight[token]    = nil
    subscriberCount    = subscriberCount - 1
    return true
end

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

-- Item 2 (subscriber isolation), without a pcall. Each recipient is invoked from its own
-- simulation timer, and ScriptsContainer::callTimer wraps every timer callback in its own
-- try/catch (scriptscontainer.cpp:719-743). So a subscriber that throws is reported by the
-- engine and cannot truncate the fan-out, cancel other recipients' retries or stop
-- verification being scheduled.
--
-- The cost the audit flags is real: callTimer does `mTemporaryCallbacks.erase(id)` *after*
-- the call and inside the try, so a throwing callback is retained for the lifetime of the
-- script. It is bounded here by quarantining the registration, which needs a Lua-visible
-- signal because engine-level isolation tells Lua nothing. `inFlight` is that signal: it
-- is set before the call and cleared after, so an entry still present at the next dispatch
-- means the previous call never returned.
local dispatchOne

-- `dispatching` guards against reentrancy from inside a callback, so it must be true only
-- while one is running. A callback that throws never reaches the line that clears it, and
-- with engine-level isolation Lua never finds out - so a stranded `true` would silence
-- every later cause. Every entry point the engine calls is outside any callback by
-- construction, so each one clears it first and a leak cannot outlive one timer or frame.
local function enterFromEngine()
    dispatching = false
end

local function quarantine(key, token, episodeId)
    print("[AnimRefresh] '" .. tostring(key) .. "' raised an error during episode " ..
          tostring(episodeId) .. " (the engine logged it as 'callTimer failed'); " ..
          "removing that registration. Re-subscribe after fixing it.")
    if registrations[key] == token then forget(key) end
    inFlight[token] = nil
end

dispatchOne = function(episode, key, attempt)
    enterFromEngine()
    if not episodeIsCurrent(episode) then return end

    local token = episode.recipients[key]
    if token == nil or registrations[key] ~= token then return end

    local previousFlight = inFlight[token]
    if previousFlight ~= nil then
        quarantine(key, token, previousFlight)
        return
    end

    local callback = callbacks[token]
    if callback == nil then return end

    local mode, previous = episode.mode, episode.previous
    if episode.liveMode then
        -- A reconcile reports no transition, so both halves are the mode now. Using
        -- `lastMode` for `previous` is not safe: processTimers runs before onUpdate in
        -- LuaManager::update, so a reconcile can beat the first poll after a non-crossing
        -- change (ThirdPerson -> Preview) and deliver mode ~= previous - which is the only
        -- signal a two-argument consumer has for "a real boundary happened". v5 has the
        -- same race; making them equal by construction is what finally makes
        -- `mode ~= previousMode` a dependable discriminator.
        mode = camera.getMode()
        previous = mode
    end

    -- Item 9. A fresh table per delivery, never a shared one. That is what makes the
    -- isolation guarantee hold without enforcement: two subscribers in the same episode
    -- cannot be handed the same object, so neither can affect the other by writing to it.
    -- Immutability is therefore by contract (documented, not enforced) and the contract
    -- costs a consumer nothing to honour.
    --
    -- Deliberately a plain table rather than util.makeReadOnly(). makeReadOnly returns
    -- zero-size *userdata* carrying __index/__len/__pairs (luastate.cpp:312-336), so a
    -- consumer doing the reasonable `type(meta) == 'table'` would see 'userdata' and skip
    -- its own handling. Freshness already buys the isolation; enforcement would only buy
    -- protection against a subscriber mutating its own copy, at the price of lying about
    -- the type.
    -- observedMode/observedPrevious are what the camera read when the cause was RAISED, as
    -- against the (mode, previousMode) arguments, which for a reconcile are resolved at
    -- dispatch. Item 3's gate asks to "retain the original observed mode/reason in
    -- metadata"; it asks that because it expects the delivered mode to be re-stamped. This
    -- build does not re-stamp boundaries - obsolete work is discarded instead - so for a
    -- boundary the two agree, and the pair only diverges for a reconcile. Carrying both
    -- satisfies the gate either way and makes the difference inspectable rather than
    -- something a consumer has to infer from `reason`.
    local meta = {
        reason           = episode.reason,
        episode          = episode.id,
        cause            = episode.cause,
        attempt          = attempt,
        origin           = episode.origin,
        detail           = episode.detail,
        observedMode     = episode.mode,
        observedPrevious = episode.previous,
        version          = MY_VERSION,
    }

    local wasDispatching = dispatching
    dispatching = true
    inFlight[token] = episode.id

    local result = callback(mode, previous, meta)

    inFlight[token] = nil
    dispatching = wasDispatching

    if result ~= false then return end

    local delay = episode.retries[attempt + 1]
    if delay == nil then
        print("[AnimRefresh] '" .. tostring(key) .. "' still not ready after " ..
              tostring(#episode.retries + 1) ..
              " attempts; giving up on this change")
        return
    end
    async:newUnsavableSimulationTimer(delay, function()
        dispatchOne(episode, key, attempt + 1)
    end)
end

local function dispatch(episode, delay)
    for key in pairs(episode.recipients) do
        async:newUnsavableSimulationTimer(delay, function()
            dispatchOne(episode, key, 0)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- CAUSES
-- ---------------------------------------------------------------------------

local function raise(reason, previous, recipients, delay, origin, detail)
    if subscriberCount == 0 then return nil end
    -- Item 12: a refreshNow() raised from inside a callback is covered by the episode
    -- already running. It creates no nested fan-out and no self-generated chain.
    if dispatching then return nil end
    local episode = newEpisode(reason, camera.getMode(), previous, recipients,
                               origin, detail)
    dispatch(episode, delay)
    return episode
end

local function fireBoundary(previous)
    local episode = raise('boundary', previous, captureAll(), DISPATCH_DELAY, 'poll')
    if episode == nil then return end
    if next(verifiers) == nil then return end

    -- Item 2: scheduled at the cause rather than after the fan-out returns, so no
    -- subscriber's failure can cancel it. Item 3: it belongs to this boundary, so a
    -- subscriber that joined afterwards is not one of its verifiers and a newer cause
    -- retires it altogether.
    for key, token in pairs(episode.recipients) do
        if verifiers[token] then
            async:newUnsavableSimulationTimer(verifyDelays[token] or VERIFY_DELAY, function()
                if not episodeIsCurrent(episode) then return end
                if registrations[key] ~= token then return end
                local followUp = newEpisode('verify', camera.getMode(), episode.previous,
                                            { [key] = token }, 'verify', episode.detail)
                -- A verification is a follow-up to its boundary, not a new cause, so it
                -- must not supersede the boundary for any other recipient still retrying.
                followUp.cause = episode.cause
                latestCause = episode.cause
                dispatch(followUp, DISPATCH_DELAY)
            end)
        end
    end
end

-- Item 11. One primary reconciliation per batch of joins and loads, instead of v5's two
-- load deliveries plus a join per subscriber for the same single restoration need.
local function requestReconcile(keys, delay, origin)
    local scheduling = pendingReconcile == nil
    pendingReconcile = pendingReconcile or {}
    for key, token in pairs(keys) do pendingReconcile[key] = token end
    -- A load, an init and a join coalescing into one episode is one episode with one
    -- origin. A lifecycle cause is the stronger claim, so it wins the label over a join.
    if origin == 'load' or origin == 'init' or pendingReconcileOrigin == nil then
        pendingReconcileOrigin = origin
    end
    if not scheduling then return end

    async:newUnsavableSimulationTimer(delay, function()
        local batch       = pendingReconcile
        local batchOrigin = pendingReconcileOrigin
        pendingReconcile       = nil
        pendingReconcileOrigin = nil
        if batch == nil or subscriberCount == 0 then return end
        local recipients = nil
        for key, token in pairs(batch) do
            if registrations[key] == token then
                recipients = recipients or {}
                recipients[key] = token
            end
        end
        if recipients == nil then return end
        local episode = newEpisode('reconcile', camera.getMode(), lastMode, recipients,
                                   batchOrigin)
        dispatch(episode, DISPATCH_DELAY)
    end)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- Item 5's poll backstop, defined with the latch below but called from the poll here.
local checkMenuLatch

-- The poll is the only writer of the baseline.
local function checkBoundary()
    -- Item 4. v5 returned here whenever a mode change was queued, which left the baseline
    -- unwritten for as long as the queue was held. An applied crossing followed by a held
    -- return then landed back on the old baseline and both rebuilds vanished (G19). A
    -- queued request is a possible *future* change and is never a reason to skip sampling
    -- what the camera is doing now. `getQueuedMode()` being nil was never settlement
    -- evidence either: Camera::setMode assigns mMode immediately and defers the rebuild
    -- through mProcessViewChange (camera.cpp:217-245, consumed at :137).
    local mode = camera.getMode()
    local nowFirst = isFirstPersonMode(mode)
    local previous = lastMode
    lastMode = mode

    if nowFirst == baselineFirstPerson then return end
    baselineFirstPerson = nowFirst
    fireBoundary(previous)
end

local function onUpdate(dt)
    enterFromEngine()
    if subscriberCount == 0 then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkBoundary()
    checkMenuLatch()
end

-- ---------------------------------------------------------------------------
-- ITEM 5: THE MENU LATCH
-- ---------------------------------------------------------------------------

local function latch(mode)
    menuLatch = menuLatch or {}
    if menuLatch[mode] then return end
    menuLatch[mode] = true
    menuLatchOrder = menuLatchOrder or {}
    menuLatchOrder[#menuLatchOrder + 1] = mode
end

local function clearLatch()
    menuLatch      = nil
    menuLatchOrder = nil
end

-- Resolved lazily, not at load: omw/ui.lua may not have published its interface yet when
-- this script runs. Re-resolved while still nil, then cached.
local uiModesView = nil
local function uiModes()
    if uiModesView == nil then
        local uiInterface = I.UI
        if uiInterface ~= nil then uiModesView = uiInterface.modes end
    end
    return uiModesView
end

-- Latches every rebuilding mode currently on the stack and reports whether the stack is
-- empty, i.e. whether gameplay is running.
--
-- `modes` is util.makeReadOnly(modeStack): zero-size *userdata* carrying
-- __index/__len/__pairs (luastate.cpp:312-336). So it must not be type-checked as a table
-- - the same trap as the provider guard above - and indexing is the only metamethod worth
-- relying on, since __ipairs was removed in Lua 5.3 and __len and __pairs on userdata vary
-- by version. A numeric probe needs none of them.
--
-- Returns false, not true, when the interface is unavailable: "I cannot see the stack" must
-- never be mistaken for "gameplay is running", or an unresolved interface would consume
-- latches that nothing had confirmed were over.
local function scanUiStack()
    local modes = uiModes()
    if modes == nil then return false end
    local i = 1
    while true do
        local mode = modes[i]
        if mode == nil then break end
        if LATCH_UI_MODES[mode] then latch(mode) end
        i = i + 1
    end
    return i == 1
end

-- The one consume path, shared by the event and the poll. Whichever observes the return to
-- gameplay first clears the latch, so the other finds nothing and the notice is single.
local function consumeLatch(origin)
    if menuLatch == nil then return end
    local detail = table.concat(menuLatchOrder, '+')
    clearLatch()
    raise('menu', lastMode, captureAll(), DISPATCH_DELAY, origin, detail)
end

-- The backstop, which makes item 5 independent of the event arriving at all.
--
-- receiveEvent walks the handler list in *reverse* registration order and breaks when a
-- handler returns exactly false (scriptscontainer.cpp:368-373), so a script loaded after
-- this one can starve the UiModeChanged handler completely. A handler that merely *throws*
-- cannot - each is individually wrapped in its own try/catch - so the exposure is
-- specifically a later-loaded handler that returns false. That is the audit's G16, and
-- polling the stack removes it as a dependency rather than recording it as a limit.
--
-- The cost is one userdata index per poll in the overwhelmingly common case, because
-- gameplay means an empty stack and the probe stops at the first nil.
--
-- Which path wins is genuinely undetermined, and neither is "the fast one". A menu closes
-- during input, before the model update at engine.cpp:302, so a poll landing in that same
-- frame observes the empty stack already - while ui.lua reaches this script by
-- self:sendEvent from an engine handler, which queues and is delivered in a *later*
-- frame's callEventHandlers. So the poll often observes gameplay first, and with a poll
-- interval of 0.1s either may. Both are safe, because both run after 302; whichever gets
-- there clears the latch, so the notice is single either way. `meta.origin` therefore
-- records which path observed it and is NOT a suppression indicator: the poll cannot
-- distinguish an event that was suppressed from one not yet delivered.
checkMenuLatch = function()
    if not scanUiStack() then return end
    consumeLatch('poll')
end

-- Item 5. Latch from *either* field, and act when gameplay resumes.
--
-- A rebuilding menu pushed from dialogue appears as `newMode` on its push and as
-- `oldMode` on its pop, and as neither on the event that returns to gameplay. Reading
-- both fields is well founded rather than belt-and-braces: ui.lua's `oldMode` is a
-- module-level variable assigned *after* the event is sent (files/data/scripts/omw/ui.lua
-- :135-136), so it is the previous stack top, which is exactly the mode just popped.
local function uiModeChanged(data)
    enterFromEngine()
    if data == nil then return end

    local newMode, oldMode = data.newMode, data.oldMode

    -- Latch regardless of subscriber count: a subscriber may join while the menu is still
    -- open, and the set is bounded at five names so an unobserved latch costs nothing.
    if newMode ~= nil and LATCH_UI_MODES[newMode] then latch(newMode) end
    if oldMode ~= nil and LATCH_UI_MODES[oldMode] then latch(oldMode) end

    -- An empty mode stack is the return to gameplay, and the only point at which the
    -- rebuild has certainly happened and the player can see the model again.
    if newMode ~= nil then return end
    consumeLatch('uiMode')

    -- Returns nothing, deliberately. receiveEvent breaks out of the handler list when a
    -- handler returns exactly false (scriptscontainer.cpp:371-373), so returning false
    -- here would starve every UiModeChanged handler registered before this script.
end

local function onLoad()
    enterFromEngine()
    -- A load supersedes any latch: whatever menu was open belonged to the session being
    -- replaced, and the reconcile below covers the model that actually exists now.
    clearLatch()
    requestReconcile(captureAll(), LOAD_DELAY, 'load')
end

-- Item 11's gate names three lifecycle entries: new-script onInit, saved-script onLoad and
-- reloadlua. onLoad covers a script already present in the save; onInit is what fires when
-- this script is added to an existing save, and without it that case raised no load
-- reconcile at all. It degraded rather than broke - subscribe() still produces a join
-- reconcile per consumer - but item 11 asks for one primary reconciliation per live
-- registration epoch, and the join path gives one per subscriber instead.
--
-- On a brand-new game this fires with no subscribers, which requestReconcile drops when
-- the batch is drained. Harmless, and cheaper than trying to tell the two cases apart.
local function onInit()
    enterFromEngine()
    clearLatch()
    requestReconcile(captureAll(), LOAD_DELAY, 'init')
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

-- Item 8: everything is checked before anything is written, so a rejected call leaves
-- the registry exactly as it was. In v5 the opts read happened after the registration
-- was already stored, so a bad `opts` raised but still left the callback live.
local function validate(key, callback, opts)
    if type(key) ~= 'string' or key == '' then
        return ("[AnimRefresh] subscribe() needs a non-empty string key, got %s")
               :format(type(key) == 'string' and '""' or type(key))
    end
    if callback ~= nil and type(callback) ~= 'function' then
        return ("[AnimRefresh] subscribe('%s', ...) needs a function, got %s")
               :format(key, type(callback))
    end
    -- nil and false both mean "no options", for compatibility.
    if opts ~= nil and opts ~= false then
        if type(opts) ~= 'table' then
            return ("[AnimRefresh] subscribe('%s', ...) options must be a table, got %s")
                   :format(key, type(opts))
        end
        if opts.verify ~= nil and type(opts.verify) ~= 'boolean' then
            return ("[AnimRefresh] subscribe('%s', ...) options.verify must be a boolean, got %s")
                   :format(key, type(opts.verify))
        end
        -- Item 10: a consumer that knows its own action lifetime picks its own delay rather
        -- than inheriting a service-wide one. `verify` stays a boolean, per item 8's gate.
        if opts.verifyDelay ~= nil then
            if type(opts.verifyDelay) ~= 'number' then
                return ("[AnimRefresh] subscribe('%s', ...) options.verifyDelay must be a number, got %s")
                       :format(key, type(opts.verifyDelay))
            end
            if opts.verifyDelay <= 0 or opts.verifyDelay ~= opts.verifyDelay then
                return ("[AnimRefresh] subscribe('%s', ...) options.verifyDelay must be above zero, got %s")
                       :format(key, tostring(opts.verifyDelay))
            end
        end
    end
    return nil
end

local function unsubscribe(key)
    if type(key) ~= 'string' or key == '' then return end
    forget(key)
end

local function subscribe(key, callback, opts)
    local problem = validate(key, callback, opts)
    if problem then error(problem) end

    -- v5 accepted a nil callback as an unsubscribe. Kept working, but routed through the
    -- one implementation rather than being a second, undocumented path that also
    -- silently discarded opts.
    if callback == nil then
        forget(key)
        return
    end

    local firstSubscriber = subscriberCount == 0
    forget(key)   -- replacing an existing registration retires its token first

    -- Item 3: a fresh token per registration. Deferred work captured against the old
    -- token can no longer reach the new owner of this key.
    local token = {}
    registrations[key] = token
    callbacks[token]   = callback
    verifiers[token]   = (opts and opts.verify) or nil
    verifyDelays[token] = (opts and opts.verifyDelay) or nil
    subscriberCount    = subscriberCount + 1

    if firstSubscriber then
        -- 0 -> 1 subscribers: re-baseline, so a view change nobody was listening for
        -- is not reported as news.
        lastMode            = camera.getMode()
        baselineFirstPerson = isFirstPersonMode(lastMode)
        pollTimer           = 0
    end

    -- Item 5: if a rebuilding menu is already open, this subscription must still be told
    -- when it closes, even though its push event predates the subscription.
    scanUiStack()

    -- Item 11: the joiner's refresh joins any reconciliation already pending rather than
    -- becoming another notice for the same need.
    requestReconcile({ [key] = token }, JOIN_DELAY, 'subscribe')
end

-- For model changes this service cannot see. `detail` is optional and is passed through
-- to subscribers as meta.detail, so a caller that rebuilt the model can say why.
local function refreshNow(detail)
    if detail ~= nil and type(detail) ~= 'string' then
        -- Not an error: refreshNow() never raised in v5 and a caller passing something
        -- stray should still get its refresh. Loud, though, never silent.
        print("[AnimRefresh] refreshNow() takes an optional string detail, got " ..
              type(detail) .. "; ignoring it and refreshing anyway")
        detail = nil
    end
    raise('manual', lastMode, captureAll(), DISPATCH_DELAY, 'api', detail)
end

local function getMode()
    return camera.getMode()
end

-- Item 7: live, and documented as the current camera mode rather than the generation of
-- the current skeleton. v5 returned the cached poll value, which was stale indefinitely
-- with no subscribers and whenever queue sampling was suppressed.
local function isFirstPersonNow()
    return isFirstPersonMode(camera.getMode())
end

-- ---------------------------------------------------------------------------
-- ITEM 13: HANDOVER
-- ---------------------------------------------------------------------------
--
-- Publication is decided by LOAD ORDER, not by version. ScriptsContainer::addInterface
-- assigns `mPublicInterfaces[name]` only when no later script publishes the same name
-- (`scriptscontainer.cpp:283`), so the highest script id wins and this script's version
-- guard is a courtesy on top of that, not the mechanism.
--
-- `onInterfaceOverride` is called on THIS script with the interface it is displacing
-- (`scriptscontainer.cpp:265`, `LuaUtil::call(..., *script.mOnOverride, *prev->mInterface)`),
-- which is what item 13 means by "a recipient passed directly because publication has not
-- happened yet". It is accepted as an engine handler: extracted at :153 before the
-- unsupported-name check at :157.
--
-- What is achievable depends entirely on what the displaced provider offers:
--   * against a provider with `retire` (v6 or later): a real handover - its registrations
--     move here once, its scheduling stops, and its cached references forward.
--   * against v5: only per-key de-duplication, because v5 cannot enumerate its
--     registrations and has nothing to stop its poll. Its onUpdate and timers keep running.
--     That residue is G12 and this item does not pretend to fix it.
local previousProvider = nil
local retiredTo        = nil
-- addInterface can call onInterfaceOverride more than once for one script: a script
-- inserted BELOW an already-loaded later one re-notifies that later one
-- (scriptscontainer.cpp:271-281). A displaced v6 would no-op on a second retire() thanks
-- to its own guard, but relying on the other side's correctness is not a protocol.
local handedOver       = false

-- Forward-declared: onInterfaceOverride hands this to a displaced provider's retire(), and
-- it is only ever called after the chunk has returned, so the assignment below is in time.
-- A global here would be a sandbox violation as well as a bug.
local PUBLISHED

local function versionOf(provider)
    -- The interface is userdata, and the gate says raw table/proxy equality is invalid, so
    -- it is never compared or type-checked - only its version field is read, as a number.
    if provider == nil then return nil end
    local reported = provider.version
    if type(reported) ~= 'number' then return nil end
    return reported
end

local function onInterfaceOverride(previous)
    enterFromEngine()
    if previous == nil then return end
    local theirVersion = versionOf(previous)

    -- A provider that can retire itself gets a real handover. It re-subscribes its own
    -- registrations here, so nothing is enumerated across the boundary and no callback is
    -- ever serialized - live functions, one live Lua state.
    if theirVersion ~= nil and theirVersion < MY_VERSION
       and type(previous.retire) == 'function' then
        if handedOver then return end
        handedOver = true
        previousProvider = nil
        previous.retire(PUBLISHED)
        print("[AnimRefresh] took over from v" .. tostring(theirVersion) ..
              " through its retire(); its registrations transferred and its scheduling " ..
              "stopped.")
        return
    end

    -- Otherwise keep the reference for per-key de-duplication in subscribe().
    previousProvider = previous
    print("[AnimRefresh] publishing over an AnimRefresh v" .. tostring(theirVersion) ..
          " that offers no retire(). Its registrations cannot be enumerated, so each key " ..
          "is unsubscribed from it as that key subscribes here. Its onUpdate and timers " ..
          "keep running (v6 fix list item 13 / G12): load only one provider.")
end

-- Item 13's retirement side, so a future v7 can displace this build cleanly. Idempotent:
-- "transfer once" means a second call is a no-op, not a second transfer.
local function retire(successor)
    if retiredTo ~= nil then return end
    if successor == nil or type(successor.subscribe) ~= 'function' then
        print("[AnimRefresh] retire() needs a successor with a subscribe(); ignoring, " ..
              "and staying live rather than leaving consumers with no provider.")
        return
    end
    retiredTo = successor

    -- Move the live registrations once. Keys conflict in the successor's favour, which is
    -- what the gate requires: it subscribes last, so its own entry for a key wins.
    local moved = 0
    for key, token in pairs(registrations) do
        local callback = callbacks[token]
        if callback ~= nil then
            successor.subscribe(key, callback,
                { verify = verifiers[token] and true or nil,
                  verifyDelay = verifyDelays[token] })
            moved = moved + 1
        end
    end

    -- Stop everything of ours: the poll goes quiet because subscriberCount drops to zero,
    -- and any deferred work is dropped because its key's token no longer matches.
    registrations, callbacks, verifiers, verifyDelays = {}, {}, {}, {}
    inFlight, pendingReconcile, pendingReconcileOrigin = {}, nil, nil
    subscriberCount = 0
    clearLatch()
    print("[AnimRefresh] retired to a newer provider; transferred " .. moved ..
          " registration(s).")
end

-- A consumer holding a cached reference to this interface must keep working after
-- retirement, so these forward rather than fail. Item 13 calls this "forwarding of cached
-- old references".
local function subscribeOrForward(key, callback, opts)
    if retiredTo ~= nil then return retiredTo.subscribe(key, callback, opts) end
    return subscribe(key, callback, opts)
end

local function unsubscribeOrForward(key)
    if retiredTo ~= nil then return retiredTo.unsubscribe(key) end
    return unsubscribe(key)
end

local function refreshNowOrForward(detail)
    if retiredTo ~= nil then return retiredTo.refreshNow(detail) end
    return refreshNow(detail)
end

-- Item 13's de-duplication against a provider that cannot enumerate: as each key arrives
-- here, remove it there. Only known keys are reachable, which the gate states outright.
local function subscribeAndDeduplicate(key, callback, opts)
    local result = subscribeOrForward(key, callback, opts)
    if previousProvider ~= nil and callback ~= nil
       and type(previousProvider.unsubscribe) == 'function' then
        previousProvider.unsubscribe(key)
    end
    return result
end

PUBLISHED = {
    version       = MY_VERSION,
    subscribe     = subscribeAndDeduplicate,
    unsubscribe   = unsubscribeOrForward,
    refreshNow    = refreshNowOrForward,
    getMode       = getMode,
    isFirstPerson = isFirstPersonNow,
    retire        = retire,
}

return {
    interfaceName = "AnimRefresh",
    interface = PUBLISHED,
    -- An event, not an engine handler. See docs/animrefresh.md.
    eventHandlers = {
        UiModeChanged  = uiModeChanged,
    },
    engineHandlers = {
        onUpdate            = onUpdate,
        onInit              = onInit,
        onLoad              = onLoad,
        onInterfaceOverride = onInterfaceOverride,
    },
}
