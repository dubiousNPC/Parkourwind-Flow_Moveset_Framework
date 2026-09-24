---@omw-context player
local async = require("openmw.async")
local I = require("openmw.interfaces")
local storage = require("openmw.storage")

local MOD_ID = "FLOW_AMF"
local SETTINGS_KEY = "Settings" .. MOD_ID

-- Both registrations are wrapped. This file holds the settings-registration
-- exception to the no-pcall rule (RESEARCH.md 2.16): a single rejected setting
-- removes EVERY setting on the page, including the Debug HUD toggle every other
-- diagnostic depends on. The failure is unrecoverable rather than informative.
-- Both print, so the error is surfaced AND the rest of the page survives - that
-- is what separates this from concealment.
--
-- Whole-mod pcall inventory, so this claim stays checkable: THREE, all of them
-- in this file - the page, the core group and the states group. That is the
-- entire list. SharedRay wraps its own callbacks; that file is third-party and
-- is not edited.
--
-- core/h3lp_compat.lua used to be a fourth. It wrapped `require` of an optional
-- module on the grounds that a missing file throws, which is true - but
-- vfs.fileExists answers the same question without loading anything, and the
-- pcall could not distinguish "h3lp absent" from "h3lp threw while loading", so
-- a broken h3lp was silently replaced by FLOW's fallback. See that file's header.
-- Every capability question outside this file is now answered by testing for the
-- field or the file directly.
local pageOk = pcall(I.Settings.registerPage, {
    key = MOD_ID,
    l10n = MOD_ID,
    name = "FLOW Movement",
    description = "Advanced Movement Framework Configuration"
})
if not pageOk then print("[FLOW] settings page failed to register") end

local groupOk = pcall(I.Settings.registerGroup, {
    key = SETTINGS_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF",
    permanentStorage = false,
    settings = {
        -- [NEW] Master enable/disable
        {
            key = "modEnabled",
            name = "Enable FLOW",
            description = "Master switch. When off, FLOW does nothing at all - no raycasts, no state tracking, pure vanilla movement.",
            default = true, renderer = "checkbox"
        },
        {
            key = "disableInInteriors",
            name = "Disable Indoors",
            description = "When on, FLOW is inactive while inside interior cells (still works in the open world).",
            default = false, renderer = "checkbox"
        },
        {
            key = "debugMode",
            name = "Debug HUD",
            description = "Shows the live state/sensor readout on screen. Off by default - the HUD redraws and allocates strings every frame, and also forces the sensor to resolve object names it otherwise wouldn't need. Leave off unless diagnosing something.",
            default = false, renderer = "checkbox"
        },
    }
})
if not groupOk then print("[FLOW] settings group failed to register") end

-- =============================================================================
-- PER-STATE TOGGLES
--
-- A SECOND GROUP, and the extra pcall that comes with it is the point rather
-- than an oversight. The justification for the first two (RESEARCH.md 2.16) is
-- that a rejected setting takes the whole PAGE down with it, including the
-- Debug HUD toggle every other diagnostic depends on. Putting seven more
-- settings in the group above would put the Debug HUD behind seven more chances
-- of exactly that. A separate group means a rejection here costs the state
-- toggles and nothing else, and the mod still has its master switch and its
-- diagnostics. Same shape as the two above: wrapped, and it prints, so the
-- failure is surfaced rather than concealed.
local STATES_KEY = SETTINGS_KEY .. "States"

local statesOk = pcall(I.Settings.registerGroup, {
    key = STATES_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF_States",
    permanentStorage = false,
    settings = {
        {
            key = "stateVault",
            name = "Vault",
            description = "Hurdling knee-to-waist-height obstacles (30-55% of player height). Turning this off also stops the forward obstacle scan when Mantle is off too.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateMantle",
            name = "Mantle",
            description = "Climbing onto waist-to-head-height surfaces (56-100% of player height). Also used to climb up from a ledge hang - with this off, hanging still works but you cannot pull yourself over the top.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateLedgeHang",
            name = "Ledge Hang",
            description = "Catching overhead ledges in mid-air (120-140% of player height). Turning this off also removes the per-frame ledge probe while airborne, and makes Shimmy and Wall Boost unreachable - both are entered only from a hang.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateShimmy",
            name = "Shimmy",
            description = "Stepping sideways along a ledge you are hanging from. Requires Ledge Hang.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateWallBoost",
            name = "Wall Boost",
            description = "Jumping away from a ledge at an angle, boosted by Acrobatics. Requires Ledge Hang.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateRoll",
            name = "Landing Roll",
            description = "Tapping jump in mid-air near the ground to roll on landing, reducing fall damage. Turning this off also skips the ground-height probe that arming the roll would cast.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateLadder",
            name = "Ladder Climb",
            description = "Climbing statics recognised as ladders. Turning this off also skips the forward probe that looks for them.",
            default = true, renderer = "checkbox"
        },
    }
})
if not statesOk then print("[FLOW] settings group 'states' failed to register") end

local section = storage.playerSection(SETTINGS_KEY)
local statesSection = storage.playerSection(STATES_KEY)

-- =============================================================================
-- READ CACHE
--
-- main.lua checks modEnabled() and disableInInteriors() on EVERY frame before
-- doing anything else, and section:get() is a storage lookup that crosses into
-- the engine. That's two boundary crossings per frame, forever, for values
-- that only change when the player opens the settings menu.
--
-- Cache reads and let the storage subscription invalidate them.
--
-- The callback deliberately ignores its arguments and clears the whole
-- cache. Selectively dropping a single changed key would be marginally
-- cheaper, but it depends on the exact callback signature, and the proven
-- pattern in the wild (SourceMovement's config.lua) uses an argument-less
-- refresh. With ~12 entries, rebuilding all of them lazily on the next
-- read costs nothing, and it can't go stale if the signature differs.
local cache = {}

section:subscribe(async:callback(function()
    cache = {}
end))

local function get(key, default)
    local v = cache[key]
    if v == nil then
        v = section:get(key)
        if v == nil then v = default end
        -- Note: false caches correctly here - only nil counts as "not
        -- cached", and false ~= nil in Lua.
        cache[key] = v
    end
    return v
end

-- The state toggles live in their own storage section, so they need their own
-- cache and their own subscription. Same lazy-rebuild pattern, and for the same
-- reason: stateEnabled() is read on the hot path - once per sensor update and
-- once per FSM transition - for values that only change from the settings menu.
local stateCache = {}

statesSection:subscribe(async:callback(function()
    stateCache = {}
end))

-- State name -> storage key. Only states with a toggle appear here; Idle and
-- Airborne are the FSM's spine and are not optional, so an unmapped name is
-- ENABLED rather than an error. A future state added without a setting is
-- therefore on by default, which is the safe direction: it works, rather than
-- silently never firing.
local STATE_KEYS = {
    Vault     = "stateVault",
    Mantle    = "stateMantle",
    LedgeHang = "stateLedgeHang",
    Shimmy    = "stateShimmy",
    WallBoost = "stateWallBoost",
    Roll      = "stateRoll",
    Ladder    = "stateLadder",
}

local function stateEnabled(name)
    local key = STATE_KEYS[name]
    if not key then return true end

    local v = stateCache[key]
    if v == nil then
        v = statesSection:get(key)
        if v == nil then v = true end
        stateCache[key] = v
    end
    return v
end

return {
    modEnabled = function() return get("modEnabled", true) end,
    disableInInteriors = function() return get("disableInInteriors", false) end,
    debugMode = function() return get("debugMode", false) end,

    -- Settings.stateEnabled("Vault") etc. Enforced in two places, deliberately:
    -- core/state_manager.lua refuses the TRANSITION (correctness - it covers
    -- every entry route without each state file having to remember), and the
    -- detectors check it themselves (performance - a disabled state should not
    -- cost the raycasts that would have found work for it).
    stateEnabled = stateEnabled,
}