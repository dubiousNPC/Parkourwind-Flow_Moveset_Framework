---@omw-context player
-- Settings page and read cache.
local async = require("openmw.async")
local I = require("openmw.interfaces")
local storage = require("openmw.storage")

local MOD_ID = "FLOW_AMF"
local SETTINGS_KEY = "Settings" .. MOD_ID

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
            key = "stateWallJump",
            name = "Wall Jump",
            description = "Jump into a wall, then press jump again straight away for a boosted second jump upward. Turning this off also skips the wall-contact probe, which is only cast on the second jump press and never per frame.",
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

local cache = {}

section:subscribe(async:callback(function()
    cache = {}
end))

local function get(key, default)
    local v = cache[key]
    if v == nil then
        v = section:get(key)
        if v == nil then v = default end
        cache[key] = v
    end
    return v
end

local stateCache = {}

statesSection:subscribe(async:callback(function()
    stateCache = {}
end))

local STATE_KEYS = {
    Vault     = "stateVault",
    Mantle    = "stateMantle",
    LedgeHang = "stateLedgeHang",
    Shimmy    = "stateShimmy",
    WallBoost = "stateWallBoost",
    WallJump  = "stateWallJump",
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

    stateEnabled = stateEnabled,
}