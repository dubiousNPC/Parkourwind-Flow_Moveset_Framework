---@omw-context player
-- Settings page and read cache.
local async = require("openmw.async")
local I = require("openmw.interfaces")
local storage = require("openmw.storage")

local MOD_ID = "FLOW_AMF"
local SETTINGS_KEY = "Settings" .. MOD_ID

I.Settings.registerPage({
    key = MOD_ID,
    l10n = MOD_ID,
    name = "FLOW Movement",
    description = "Advanced Movement Framework Configuration"
})

I.Settings.registerGroup({
    key = SETTINGS_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF",
    permanentStorage = false,
    settings = {
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
            description = "Shows the live state/sensor readout on screen. Off by default - the HUD redraws ten times a second, and also forces the sensor to resolve object names it otherwise wouldn't need. Leave off unless diagnosing something.",
            default = false, renderer = "checkbox"
        },
    }
})

local STATES_KEY = SETTINGS_KEY .. "States"

I.Settings.registerGroup({
    key = STATES_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF_States",
    permanentStorage = false,
    settings = {
        {
            key = "stateVault",
            name = "Vault",
            description = "Hurdling knee-to-waist-height obstacles (25-50% of player height). Turning this off also stops the forward obstacle scan when Mantle is off too.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateMantle",
            name = "Mantle",
            description = "Climbing onto waist-to-shoulder-height surfaces (51-80% of player height). Also used to climb up from a ledge hang - with this off, hanging still works but you cannot pull yourself over the top.",
            default = true, renderer = "checkbox"
        },
        {
            key = "stateLedgeHang",
            name = "Ledge Hang",
            description = "Catching overhead ledges in mid-air (110-130% of player height). Turning this off also removes the per-frame ledge probe while airborne, and makes Shimmy and Wall Boost unreachable - both are entered only from a hang.",
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
        {
            key = "stateSkydive",
            name = "Skydive",
            description = "A long enough fall from a long enough height goes into a skydive, with Acrobatics heavily boosted and the animation steering on the movement keys. Cosmetic: jump controls stay native, and pressing jump cancels it.",
            default = true, renderer = "checkbox"
        },
    }
})

local CHALLENGE_KEY = SETTINGS_KEY .. "Challenge"

I.Settings.registerGroup({
    key = CHALLENGE_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF_Challenge",
    permanentStorage = false,
    settings = {
        {
            key = "skillChecks",
            name = "Skill Checks",
            description = "Measure Acrobatics, Agility and remaining fatigue against each move. A failed check never blocks the move: it botches it, so the landing becomes a stumble. Ledge Hang, Landing Roll, Ladder Climb and Skydive are never checked.",
            default = true, renderer = "checkbox"
        },
        {
            key = "skillDifficulty",
            name = "Skill Check Threshold",
            description = "Scales every move's difficulty. 0.5 is half as demanding, 2.0 twice. At 0 every check passes.",
            default = 1.0, renderer = "number",
            argument = { min = 0.0, max = 3.0 }
        },
        {
            key = "staminaScale",
            name = "Fatigue Cost",
            description = "Scales the fatigue every move spends. 0 stops the spending. Fatigue is never a gate on its own - an empty bar lowers the skill check, it does not take the move away.",
            default = 1.0, renderer = "number",
            argument = { min = 0.0, max = 3.0 }
        },
        {
            key = "skydiveWindup",
            name = "Skydive Windup (seconds)",
            description = "How long the skydive entry takes before release. The clip runs 5.5 seconds from its start key to its release key, longer than any fall here, so it is played faster to fit.",
            default = 3.0, renderer = "number",
            argument = { min = 0.5, max = 10.0 }
        },
    }
})

local section = storage.playerSection(SETTINGS_KEY)
local statesSection = storage.playerSection(STATES_KEY)
local challengeSection = storage.playerSection(CHALLENGE_KEY)

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

local challengeCache = {}

challengeSection:subscribe(async:callback(function()
    challengeCache = {}
end))

local function challenge(key, default)
    local v = challengeCache[key]
    if v == nil then
        v = challengeSection:get(key)
        if v == nil then v = default end
        challengeCache[key] = v
    end
    return v
end

local STATE_KEYS = {
    Vault     = "stateVault",
    Mantle    = "stateMantle",
    LedgeHang = "stateLedgeHang",
    Shimmy    = "stateShimmy",
    WallBoost = "stateWallBoost",
    Roll      = "stateRoll",
    Ladder    = "stateLadder",
    Skydive   = "stateSkydive",
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

    skillChecks = function() return challenge("skillChecks", true) end,
    skillDifficulty = function() return challenge("skillDifficulty", 1.0) end,
    staminaScale = function() return challenge("staminaScale", 1.0) end,
    skydiveWindup = function() return challenge("skydiveWindup", 2.0) end,

    stateEnabled = stateEnabled,
}