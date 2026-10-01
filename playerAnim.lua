---@omw-context player
-- Animation controller. The only file where group names appear.
local self = require('openmw.self')
local animation = require('openmw.animation')
local I = require('openmw.interfaces')

local Anim = {}

local PRIORITY_FLOW       = animation.PRIORITY.Weapon
local PRIORITY_FLOW_MAJOR = animation.PRIORITY.Block

local GROUPS = {
    Vault     = { group = { "pwvault1", "pwvault2", "pwvault3" }, speed = .8 },
    Mantle    = { group = { "pwmantle1", "pwmantle2", "pwmantle3" }, speed = .7,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        autoDisable = true},
    LedgeHang = {
        group = "pwwallhangidle", speed = .7,  -- looping hang pose
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
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
        variants = { left = "pwshimmyl1", right = "pwshimmyr1" },
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
        group = "pwwalljump1", speed = 1,
        priority = PRIORITY_FLOW_MAJOR,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
}

local LOOPING_STATES = { LedgeHang = true, Ladder = true }
local ONE_SHOT_STATES = { Vault = true, Mantle = true, Roll = true,
                          Shimmy = true, WallBoost = true, WallJump = true }

local FULLBODY_PRIORITY = {
    [animation.BONE_GROUP.RightArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LeftArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.Torso] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LowerBody] = animation.PRIORITY.Jump,
}
local FULLBODY_BLEND_MASK = animation.BLEND_MASK.LeftArm + animation.BLEND_MASK.Torso
                           + animation.BLEND_MASK.RightArm + animation.BLEND_MASK.LowerBody

local currentGroup = nil

local pendingVariant = nil

local reissue = nil   -- forward declaration; defined once playGroup exists

function Anim.registerAnimRefresh()
    if not I.AnimRefresh then
        print("[FLOW:Anim] I.AnimRefresh not found - poses will not survive a "
            .. "first/third-person switch. Make sure scripts/AnimRefresh/"
            .. "AnimRefresh_v4.lua is registered in FLOW_AMF.omwscripts.")
        return
    end

    I.AnimRefresh.subscribe("FLOW", function()
        if reissue then reissue() end
    end, { verify = true })
end

function Anim.setVariant(name)
    pendingVariant = name
end

local lastVariant = {}

-- Resolves a GROUPS entry to an actual group name, honouring `variants`.
local function resolveGroup(entry)
    if not entry then return nil end
    if entry.variants then
        local key = pendingVariant or lastVariant[entry]
        local group = key and entry.variants[key]
        if not group then
            for k, g in pairs(entry.variants) do key, group = k, g; break end
        end
        if key then lastVariant[entry] = key end
        return group
    end

    if type(entry.group) == "table" then
        local n = #entry.group
        if n == 0 then return nil end
        return entry.group[math.random(n)]
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

    local probes = {}
    for stateName, entry in pairs(GROUPS) do
        if type(entry) == "table" then
            if entry.variants then
                for dir, g in pairs(entry.variants) do
                    probes[#probes + 1] = { stateName .. "/" .. dir, g }
                end
            elseif type(entry.group) == "table" then
                for i = 1, #entry.group do
                    probes[#probes + 1] = { stateName .. "[" .. i .. "]", entry.group[i] }
                end
            elseif entry.group then
                probes[#probes + 1] = { stateName, entry.group }
            end
        else
            print(string.format("[FLOW][anim] MALFORMED GROUPS entry '%s' (%s, expected table)",
                tostring(stateName), type(entry)))
        end
    end

    for i = 1, #probes do
        local label, group = probes[i][1], probes[i][2]
        local present = animation.hasGroup(self, group)
        if present then
            print(string.format("[FLOW][anim] %-16s '%s' -> OK", label, group))
        else
            print(string.format("[FLOW][anim] %-16s '%s' -> MISSING (will T-pose or do nothing)",
                label, group))
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
    local group = resolveGroup(entry)
    pendingVariant = nil   -- consumed; never let a direction leak forward
    if not group then return end

    if currentGroup == group then return end -- already playing, avoid restart stutter
    stopCurrent()

    local autoDisable = entry.autoDisable
    if autoDisable == nil then autoDisable = not looping end

    animation.playBlended(self, group, {
        startKey = entry.startKey,
        stopKey = entry.stopKey,
        priority = entry.priority or FULLBODY_PRIORITY,
        blendMask = entry.blendMask or FULLBODY_BLEND_MASK,
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

function Anim.onStateChange(newState, oldState)
    if ONE_SHOT_STATES[newState] then
        lastRequest = { state = newState, looping = false }
        playGroup(newState, false)
    elseif LOOPING_STATES[newState] then
        lastRequest = { state = newState, looping = true }
        playGroup(newState, true)
    else
        lastRequest = nil
        -- Idle, Airborne, or anything else: hand control back to vanilla.
        stopCurrent()
    end
end

return Anim
