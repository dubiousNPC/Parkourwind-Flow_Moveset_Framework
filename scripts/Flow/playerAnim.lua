---@omw-context player
-- Animation controller. The only file where group names appear.
local self = require('openmw.self')
local animation = require('openmw.animation')
local I = require('openmw.interfaces')

local Anim = {}

local AnimPriority = require('scripts/Flow/core/anim_priority')
local Settings = require('scripts/Flow/settings')
local PRIORITY_FLOW       = AnimPriority.FLOW
local PRIORITY_FLOW_MAJOR = AnimPriority.FLOW_MAJOR
local PRIORITY_SCRIPTED   = AnimPriority.FLOW_SCRIPTED

-- Fall clips: chosen by the authored layout (core/fall_plan.lua); the
-- measured manifest (core/fall_clips.lua) supplies their lengths.
local FallClips = require('scripts/Flow/core/fall_clips')
local FallPlan = require('scripts/Flow/core/fall_plan')
local clipLength = {}
for _, c in ipairs(FallClips) do clipLength[c.group] = c.dur end
local DEFAULT_CLIP_LENGTH = 1.667

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

    Skydive   = {
        variants = { entry = "skydive1", loop = "skydive",
                     left = "skydivel", right = "skydiver",
                     forward = "skydivefwd" },
        variantSpeed = { entry = function() return Anim.skydiveWindupSpeed() end },
        speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    -- Out-of-control fall: a clip drawn from the manifest's `air` pool by the
    -- fall's bearing
    Falling   = {
        fallPick = "air", chain = true,
        group = "dbsfall", speed = 1,
        priority = PRIORITY_FLOW,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    -- "stumble" after a botched manoeuvre; "knockdown" after a skydive and
    -- "fallen" after a botched fall that showed the Falling pose
    Stumble   = {
        -- the variants are only the fallback when no sequence could be planned
        variants = { stumble = "pwfall1c", knockdown = "pwfall1b", fallen = "pwfall1up", falldown = "pwfall1c" },
        seqVariants = { stumble = true, knockdown = true, fallen = true, falldown = true },
        variantPriority = { stumble = PRIORITY_SCRIPTED, knockdown = PRIORITY_SCRIPTED, fallen = PRIORITY_SCRIPTED,
                            falldown = PRIORITY_SCRIPTED },
        speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
}

local currentGroup = nil

local fallCtx = { bearing = nil, heavy = false, impact = 0 }
local fallSeq = nil       -- remaining clips of a planned landing
local lastPicked = nil    -- the air clip just played: the next draw prefers a change
local chainFirst = false  -- first clip of a Falling pose: desync with startPoint


function Anim.setFallContext(bearing, heavy, impact)
    fallCtx.bearing = bearing
    fallCtx.heavy = heavy and true or false
    fallCtx.impact = impact or 0
end

local fallProvider = nil
function Anim.setFallContextProvider(fn) fallProvider = fn end
local function refreshFallContext()
    if fallProvider then Anim.setFallContext(fallProvider()) end
end

-- Plans the clips of a Stumble from the landing check and returns their total
-- length in seconds, or nil (nothing to play: a plain landing, or none of the
-- clips on this skeleton). landing = { outcome = "clean"|"close"|"fail"|"severe",
-- highSkill = bool }; see core/fall_plan.lua for what each plays.
function Anim.planLanding(kind, landing)
    refreshFallContext()
    landing = landing or { outcome = "fail" }
    -- a botch landing continues the direction of the air clip that showed
    local airDir = (kind == "stumble" or kind == "fallen") and FallPlan.dirOf(lastPicked) or nil
    lastPicked = nil
    local groups = FallPlan.landing(landing.outcome, {
        bearing = fallCtx.bearing,
        highSkill = landing.highSkill,
        fallen = (kind == "fallen"),
        skydive = (kind == "knockdown"),
        dir = airDir,
    }, Anim.groupExists)
    if #groups == 0 then fallSeq = nil; return nil end
    local seq, total = {}, 0
    for i, g in ipairs(groups) do
        local dur = clipLength[g] or DEFAULT_CLIP_LENGTH
        seq[i] = { group = g, dur = dur }
        total = total + dur
    end
    fallSeq = seq
    return total / (GROUPS.Stumble.speed or 1)
end

-- What a landing would play, without starting it (Airborne asks first, so a
-- clean ordinary landing never enters Stumble at all).
function Anim.landingGroups(kind, landing)
    refreshFallContext()
    return FallPlan.landing(landing.outcome, { bearing = fallCtx.bearing,
        highSkill = landing.highSkill, fallen = (kind == "fallen"),
        skydive = (kind == "knockdown") }, Anim.groupExists)
end

local pendingVariant = nil

local reissue = nil   -- forward declaration; defined once playGroup exists

function Anim.registerAnimRefresh()
    if not I.AnimRefresh then
        print("[FLOW:Anim] I.AnimRefresh not found - poses will not survive a "
            .. "first/third-person switch. Make sure scripts/AnimRefresh/"
            .. "AnimRefresh_v6.lua is registered in FLOW_AMF.omwscripts.")
        return
    end

    I.AnimRefresh.subscribe("FLOW", function()
        Anim.forgetGroupAvailability()
        if reissue then reissue() end
    end, { verify = true })
end

local SKYDIVE_RELEASE_SPAN = 5.467   -- fallback if the key is missing

function Anim.skydiveWindupSpeed()
    local windup = math.max(0.5, Settings.skydiveWindup())
    local span = SKYDIVE_RELEASE_SPAN
    if animation.getTextKeyTime then
        local release = animation.getTextKeyTime(self, "skydive1: release")
        local from = animation.getTextKeyTime(self, "skydive1: start")
        if release and from and release > from then span = release - from end
    end
    return span / windup
end

function Anim.setVariant(name)
    pendingVariant = name
end


local lastVariant = {}

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

Anim.groupExists = groupExists

-- Resolves a GROUPS entry to an actual group name, honouring `variants`.
local function resolveGroup(entry)
    if not entry then return nil end
    if entry.fallPick then
        refreshFallContext()
        local g = FallPlan.airClip(fallCtx.bearing, fallCtx.heavy, groupExists, lastPicked)
        if g then lastPicked = g; return g end
        return entry.group
    end
    if entry.variants then
        local key = pendingVariant or lastVariant[entry]
        if key and entry.seqVariants and entry.seqVariants[key] and fallSeq and #fallSeq > 0 then
            lastVariant[entry] = key
            return table.remove(fallSeq, 1).group, key
        end
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

local hintGiven = false

local fitSeconds = nil
function Anim.fitNext(seconds) fitSeconds = seconds end
local FIT_MIN_SPEED, FIT_MAX_SPEED = 0.4, 2.5

local function playGroup(stateName, looping)
    local fit = fitSeconds
    fitSeconds = nil   -- consumed by this call, played or not
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
            if not hintGiven then
                hintGiven = true
                print("[FLOW][anim] If FLOW's moves play no animation at all, turn on "
                    .. "'Use additional animation sources' in the OpenMW launcher "
                    .. "(settings.cfg: [Game] use additional anim sources = true).")
            end
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

    local speed = entry.speed or 1
    if variant and entry.variantSpeed and entry.variantSpeed[variant] then
        speed = entry.variantSpeed[variant]
    end
    if type(speed) == "function" then speed = speed() end
    if fit and fit > 0 and animation.getTextKeyTime then
        local a = animation.getTextKeyTime(self, group .. ": " .. (startKey or "start"))
        local b = animation.getTextKeyTime(self, group .. ": " .. (stopKey or "stop"))
        if a and b and b > a then
            speed = math.max(FIT_MIN_SPEED, math.min(FIT_MAX_SPEED, (b - a) / fit))
        end
    end

    local priority = entry.priority
    if variant and entry.variantPriority and entry.variantPriority[variant] then
        priority = entry.variantPriority[variant]
    end

    local chained = entry.chain or (entry.seqVariants and variant and entry.seqVariants[variant])
    local startPoint = nil
    if entry.chain then
        looping, autoDisable = false, false
        if chainFirst then startPoint = math.random() * 0.3 end
        chainFirst = false
    elseif chained then
        autoDisable = false
    end

    animation.playBlended(self, group, {
        startKey = startKey,
        stopKey = stopKey,
        startPoint = startPoint,
        priority = priority,
        blendMask = entry.blendMask,
        speed = speed,
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

function Anim.replay(force)
    if not lastRequest then return end
    if force then currentGroup = nil end
    playGroup(lastRequest.state, lastRequest.looping)
end

-- Cosmetic pose. The requesting state stays active and keeps its movement
-- authority; this only drives the skeleton. AnimRefresh still reissues it.
function Anim.setPose(name, variant, looping)
    pendingVariant = variant
    chainFirst = true
    lastPicked = nil
    lastRequest = { state = name, looping = looping and true or false }
    currentGroup = nil
    playGroup(name, looping and true or false)
end

function Anim.clearPose()
    lastRequest = nil
    stopCurrent()
end

function Anim.tickChain()
    if not lastRequest or not currentGroup then return end
    local entry = GROUPS[lastRequest.state]
    if not entry then return end
    local seq = entry.seqVariants and fallSeq and #fallSeq > 0
    if not (entry.chain or seq) then return end
    local done = not animation.isPlaying(self, currentGroup)
    if not done and animation.getCompletion then
        local c = animation.getCompletion(self, currentGroup)
        done = (c == nil) or c >= 0.999
    end
    if not done then return end
    currentGroup = nil
    playGroup(lastRequest.state, lastRequest.looping)
end

-- `mode` is the entering state's traits.anim: "oneshot", "loop" or nil.
function Anim.onStateChange(newState, oldState, mode)
    if mode == "oneshot" or mode == "loop" then
        local looping = mode == "loop"
        lastRequest = { state = newState, looping = looping }
        playGroup(newState, looping)
    else
        lastRequest = nil
        stopCurrent()
    end
end

return Anim
