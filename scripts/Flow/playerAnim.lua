---@omw-context player
-- Animation controller. The only file where group names appear.
local self = require('openmw.self')
local animation = require('openmw.animation')
local I = require('openmw.interfaces')

local Anim = {}

-- Above the engine's Jump (4) and Movement (5); a tie hides both.
local PRIORITY_FLOW       = animation.PRIORITY.Weapon
local PRIORITY_FLOW_MAJOR = animation.PRIORITY.Block

local GROUPS = {
    Vault     = { group = { "pwvault1", "pwvault2", "pwvault3" }, speed = .8,
        priority = PRIORITY_FLOW,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
    Mantle    = { group = { "pwmantle1", "pwmantle2", "pwmantle3" }, speed = .7,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
    LedgeHang = {
        group = "pwwallhangidle", speed = .7,  -- looping hang pose
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    Ladder = {
        variants = { up = "pwladderup", down = "pwladderdwn", idle = "pwladderidle" },
        speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    Shimmy = {
        -- Third-person sets key these pwshimmyl1/r1, the .1st sets pwshimmy1l/1r.
        variants = { left = { "pwshimmyl1", "pwshimmy1l" },
                     right = { "pwshimmyr1", "pwshimmy1r" } },
        speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    WallBoost = {
        variants = { left = "pwboostbkl", right = "pwboostbkr" },
        speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    Roll      = {
        group = "pwroll1", speed = 1,  -- one-shot landing roll
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    WallJump  = {
        -- Clip is 0.667s; the hop is BRACE+HOP = 0.65s. See states/wall_jump.lua.
        group = { "pwwalljump1", "pwwalljump2" }, speed = 1.0,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
}

local LOOPING_STATES = { LedgeHang = true, Ladder = true }
local ONE_SHOT_STATES = { Vault = true, Mantle = true, Roll = true,
                          Shimmy = true, WallBoost = true, WallJump = true }

local currentGroup = nil

local pendingVariant = nil

local reissue = nil   -- forward declaration; defined once playGroup exists

function Anim.registerAnimRefresh()
    if not I.AnimRefresh then
        print("[FLOW:Anim] I.AnimRefresh not found - poses will not survive a "
            .. "first/third-person switch. Make sure scripts/AnimRefresh/"
            .. "AnimRefresh_v5.lua is registered in FLOW_AMF.omwscripts.")
        return
    end

    I.AnimRefresh.subscribe("FLOW", function()
        Anim.forgetGroupAvailability()
        if reissue then reissue() end
    end, { verify = true })
end

function Anim.setVariant(name)
    pendingVariant = name
end

local lastVariant = {}

-- Which groups this skeleton actually defines. Cleared on a model rebuild,
-- because first and third person load different animation sources: every .1st
-- set keys shimmy pwshimmy1l/1r and no set but the beast one has pwwalljump2,
-- so an unfiltered random pick is a silent no-op half the time.
local groupAvailable = {}
local absentWarned = {}

function Anim.forgetGroupAvailability()
    groupAvailable = {}
end

local function groupExists(group)
    if not animation.hasGroup then return true end
    local known = groupAvailable[group]
    if known == nil then
        known = animation.hasGroup(self, group)
        groupAvailable[group] = known
    end
    return known
end

local function pickAvailable(list)
    local pool = {}
    for i = 1, #list do
        if groupExists(list[i]) then pool[#pool + 1] = list[i] end
    end
    if #pool == 0 then return list[1] end
    return pool[math.random(#pool)]
end

-- Resolves a GROUPS entry to an actual group name, honouring `variants`.
local function resolveGroup(entry)
    if not entry then return nil end
    if entry.variants then
        local key = pendingVariant or lastVariant[entry]
        local group = key and entry.variants[key]
        if not group then
            for k, g in pairs(entry.variants) do key, group = k, g; break end
        end
        if type(group) == "table" then group = pickAvailable(group) end
        if key then lastVariant[entry] = key end
        return group, key
    end

    if type(entry.group) == "table" then
        if #entry.group == 0 then return nil end
        return pickAvailable(entry.group)
    end
    return entry.group
end

local verified = false

function Anim.verifyGroups()
    if verified then return end
    verified = true

    if not animation.hasGroup then
        print("[FLOW][anim] animation.hasGroup unavailable - skipping group probe")
        return
    end

    -- One slot per thing the state can play; alts are interchangeable clips.
    local slots = {}
    for stateName, entry in pairs(GROUPS) do
        if type(entry) == "table" then
            if entry.variants then
                for dir, g in pairs(entry.variants) do
                    slots[#slots + 1] = { stateName .. "/" .. dir,
                        type(g) == "table" and g or { g },
                        (entry.variantStartKey and entry.variantStartKey[dir]) or entry.startKey,
                        (entry.variantStopKey and entry.variantStopKey[dir]) or entry.stopKey }
                end
            elseif type(entry.group) == "table" then
                slots[#slots + 1] = { stateName, entry.group, entry.startKey, entry.stopKey }
            elseif entry.group then
                slots[#slots + 1] = { stateName, { entry.group }, entry.startKey, entry.stopKey }
            end
        else
            print(string.format("[FLOW][anim] MALFORMED GROUPS entry '%s' (%s, expected table)",
                tostring(stateName), type(entry)))
        end
    end

    -- A group whose start key is missing is unplayable and silent. A slot with
    -- no playable clip at all is the fatal case; absent siblings only cost
    -- variety, and the two POVs legitimately define different clip names.
    local function keysMissing(group, sk, tk)
        if not animation.getTextKeyTime then return nil end
        local bad = {}
        for _, key in ipairs({ sk or "start", tk or "stop" }) do
            if not animation.getTextKeyTime(self, group .. ": " .. key) then
                bad[#bad + 1] = key
            end
        end
        return #bad > 0 and table.concat(bad, ", ") or nil
    end

    for i = 1, #slots do
        local label, alts, sk, tk = slots[i][1], slots[i][2], slots[i][3], slots[i][4]
        local playable, notes = {}, {}
        for j = 1, #alts do
            local group = alts[j]
            if not animation.hasGroup(self, group) then
                notes[#notes + 1] = group .. " absent"
            else
                local bad = keysMissing(group, sk, tk)
                if bad then
                    notes[#notes + 1] = group .. " missing key(s) " .. bad
                else
                    playable[#playable + 1] = group
                end
            end
        end
        local detail = #notes > 0 and ("  [" .. table.concat(notes, "; ") .. "]") or ""
        if #playable == 0 then
            print(string.format("[FLOW][anim] %-18s -> UNPLAYABLE%s", label, detail))
        else
            print(string.format("[FLOW][anim] %-18s -> OK %d/%d: %s%s", label,
                #playable, #alts, table.concat(playable, ", "), detail))
        end
    end

    print(string.format("[FLOW][anim] vanilla   'jump' -> %s",
        animation.hasGroup(self, 'jump') and "OK" or "MISSING"))
end

local function stopCurrent()
    if not currentGroup then return end
    animation.cancel(self, currentGroup)
    currentGroup = nil
end

local function playGroup(stateName, looping)
    local entry = GROUPS[stateName]
    local group, variant = resolveGroup(entry)
    pendingVariant = nil   -- consumed; never let a direction leak forward
    if not group then return end

    -- playBlended on an undefined group is a silent no-op; say so once.
    if not groupExists(group) then
        if not absentWarned[group] then
            absentWarned[group] = true
            print(string.format("[FLOW][anim] '%s' is not defined on this skeleton "
                .. "- %s will play nothing", group, stateName))
        end
        return
    end

    if currentGroup == group then return end -- already playing, avoid restart stutter
    stopCurrent()

    local autoDisable = entry.autoDisable
    if autoDisable == nil then autoDisable = not looping end

    local startKey = entry.startKey
    local stopKey = entry.stopKey
    if variant then
        local vs = entry.variantStartKey and entry.variantStartKey[variant]
        local vt = entry.variantStopKey and entry.variantStopKey[variant]
        if vs ~= nil then startKey = vs or nil end
        if vt ~= nil then stopKey = vt or nil end
    end

    animation.playBlended(self, group, {
        startKey = startKey,
        stopKey = stopKey,
        priority = entry.priority,
        blendMask = entry.blendMask,
        speed = entry.speed or 1,
        loops = looping and -1 or 0,
        forceLoop = looping and true or nil,
        autoDisable = autoDisable,
    })
    currentGroup = group
end

local lastRequest = nil

reissue = function()
    if not lastRequest then return end

    if currentGroup and animation.isPlaying(self, currentGroup) then return end

    currentGroup = nil   -- force playGroup past its "already playing" guard
    playGroup(lastRequest.state, lastRequest.looping)
end

-- Re-resolves the current state's group, picking up a new variant.
function Anim.replay()
    if lastRequest then playGroup(lastRequest.state, lastRequest.looping) end
end

function Anim.onStateChange(newState, oldState)
    if ONE_SHOT_STATES[newState] then
        lastRequest = { state = newState, looping = false }
        playGroup(newState, false)
    elseif LOOPING_STATES[newState] then
        lastRequest = { state = newState, looping = true }
        playGroup(newState, true)
    else
        lastRequest = nil
        stopCurrent()
    end
end

return Anim
