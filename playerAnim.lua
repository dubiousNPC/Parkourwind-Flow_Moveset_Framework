---@omw-context player
--[[
    playerAnim.lua

    Full-body animation controller for FLOW, built the same way as the
    Hookshot mod's playerAnim.lua: this file owns every animation call FLOW
    makes. States never touch the animation API directly -
    core/state_manager.lua's single setState() choke point calls
    Anim.onStateChange(newState, oldState) on every transition, and that's
    the only entry point into this file from the rest of the mod. Nothing
    else needs to change when you swap in a different animation set.

    Uses openmw.animation's module-level playBlended/cancel (explicit actor
    argument) rather than the I.AnimationController interface - both work
    the same way, this just matches the convention used more consistently
    in surf.zip. animation.cancel(actor, group) is also a cleaner way to
    stop a specific blended group than Hookshot's "reissue at Default
    priority" trick; used that way here.

    GROUPS below are placeholder vanilla-safe group names so the mod stays
    functional out of the box. Swap in your own custom set - see
    animated_climbing_and_slowdown.zip and chim_climbing.zip for a sense of
    what a climb-oriented group set can look like. This file is the only
    place animation group names appear anywhere in FLOW.
]]--

local self = require('openmw.self')
local animation = require('openmw.animation')
local I = require('openmw.interfaces')

local Anim = {}

-- ==============================================
-- CONFIGURATION - replace with your own custom groups
-- ==============================================
-- Each entry: { group = "kf group name", startKey, stopKey, speed,
--               priority, blendMask, autoDisable }
-- startKey/stopKey are optional - only set them if your .kf file has named
-- text keys marking a sub-segment of the group; omit them (nil) to just
-- play the group's own default range, like surf.zip does.
-- priority/blendMask/autoDisable are also optional - omit to use the
-- FULLBODY_PRIORITY/FULLBODY_BLEND_MASK defaults below and the standard
-- "one-shot autoDisables, looping doesn't" rule. Mantle and LedgeHang set
-- their own here because they used to call openmw.animation directly
-- with this exact tuning (before that got centralized here, which was
-- the actual cause of LedgeHang's custom animation not reliably
-- showing - two competing playBlended calls racing each other).
-- =============================================================================
-- PRIORITY TIERS
--
-- [REGRESSION FIX] These were PRIORITY_FLOW / + 20, i.e. 15
-- and 25. The documented enum runs Default(0) .. Scripted(13), so both were off
-- the end of it. A scalar priority is a legal FORM ("a single #Priority value
-- assigned to all bone groups") but 15 and 25 are not #Priority values, and
-- they do NOT inherit Scripted's special behaviour -- that is tied to the exact
-- value 13, not to "big number".
--
--   FLOW       = Weapon (7) - above Jump(4), Movement(5), Hit(6)
--   FLOW_MAJOR = Block  (8) - above FLOW
--
-- Both sit BELOW Knockdown(9) and Death(12), so being knocked down or killed
-- still interrupts a parkour move, and below Scripted(13), whose documented
-- side effect is pausing every non-Scripted animation on the actor.
--
-- Do not go back to arithmetic on the enum.
-- =============================================================================
local PRIORITY_FLOW       = animation.PRIORITY.Weapon
local PRIORITY_FLOW_MAJOR = animation.PRIORITY.Block
local PRIORITY_FLOW_FULL  = animation.PRIORITY.Storm

local GROUPS = {
    -- List form: interchangeable clips for the same action. These are VISUAL
    -- variation only - none carries root motion - so which one plays cannot
    -- affect movement, and resolveGroup picks at random per entry.
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

    -- Optional states below are inert unless re-enabled - see
    -- states/optional/README.md. Kept here so re-enabling one of them
    -- doesn't require touching this file at all, just uncommenting/adding
    -- its name to the ONE_SHOT_STATES/LOOPING_STATES sets below.
    -- Sprint's entry was removed along with the state itself. Vanilla's own
    -- run animation is correct while running, and FLOW no longer has a state
    -- to attach a replacement to.

    -- Directional entries. `variants` replaces `group`; the state selects
    -- which one via Anim.setVariant() immediately before the transition, so
    -- group names still appear ONLY in this file.
    -- Ladder: three clips selected by travel direction via Anim.setVariant().
    -- LOOPING - a climb continues for as long as the key is held, unlike the
    -- one-shot moves, so the clip must not autoDisable partway up.
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
        priority = PRIORITY_FLOW_FULL,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },

    Roll      = {
        group = "pwroll1", speed = 1,  -- one-shot landing roll
        priority = PRIORITY_FLOW_FULL,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
}

-- Which states get a looping animation, which get a one-shot, and which
-- get nothing at all. Idle/Airborne intentionally get nothing - vanilla's
-- own idle/jump/fall animations are already correct for those; FLOW only
-- needs to add NEW motions for its own mechanics, not replace basic ones.
--
-- IMPORTANT: only list a state here if its GROUPS entry names a group
-- that actually exists in the loaded animation set. playBlended with
-- FULLBODY_BLEND_MASK masks out vanilla's own animation for those bone
-- groups; if the named group has no matching clip, nothing replaces it
-- and the character T-poses for as long as the state is active. That is
-- exactly what the removed WallJump entry ("pwwalljump") was doing.
local LOOPING_STATES = { LedgeHang = true, Ladder = true }
local ONE_SHOT_STATES = { Vault = true, Mantle = true, Roll = true,
                          Shimmy = true, WallBoost = true }

local FULLBODY_PRIORITY = {
    [animation.BONE_GROUP.RightArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LeftArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.Torso] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LowerBody] = animation.PRIORITY.Jump,
}
local FULLBODY_BLEND_MASK = animation.BLEND_MASK.LeftArm + animation.BLEND_MASK.Torso
                           + animation.BLEND_MASK.RightArm + animation.BLEND_MASK.LowerBody

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local currentGroup = nil

-- Set by a state immediately before returning its own name, to pick between
-- a GROUPS entry's `variants`. Consumed on the next resolve and cleared, so
-- a stale direction can't leak into an unrelated transition.
local pendingVariant = nil

-- =============================================================================
-- PERSPECTIVE-CHANGE RECOVERY
--
-- Switching 1st/3rd person rebuilds the player's animation object, dropping
-- any scripted animation attached to it - a Vault or LedgeHang pose silently
-- vanishes mid-move if the player presses the POV key. AnimRefresh notifies
-- us after the new skeleton has settled; we simply re-issue whatever we
-- believed was playing.
--
-- Only re-issues if a group was actually active, so a player who never
-- triggers a FLOW animation pays nothing beyond the subscription itself.
-- =============================================================================
local reissue = nil   -- forward declaration; defined once playGroup exists

-- Called from main.lua's onActive, the same binding point Sensor uses for
-- I.SharedRay: every player script has loaded by then, so the interface is
-- present whatever position the engine gave AnimRefresh in the load order.
-- That position is not FLOW's to set. scripts/AnimRefresh/AnimRefresh_v4.lua
-- is shared with WhyWalk and Take a Seat, and OpenMW merges one path into ONE
-- script. Subscribing at file scope, as this used to, only worked while
-- AnimRefresh happened to load first. subscribe() replaces by key, so running
-- this on every activation is harmless.
--
-- I.AnimRefresh is looked up here on every call and never cached in a local.
-- v4's contract spells out why: if an older bundled copy loaded first and this
-- one overrode it, a cached reference still points at the dead copy.
--
-- WHY v4 AND NOT v3. v3 fired on every camera-mode hop, so auto-vanity after
-- ~30s idle counted as a perspective change - a player hanging from a ledge
-- long enough to go idle had the hang pose restarted for no reason. v4 watches
-- only the first-person boundary, which is the only one that rebuilds the
-- model, and adds the two causes v3 missed that FLOW is exposed to: the Rest /
-- Travel / Training / Jail menus, and loading a save.
function Anim.registerAnimRefresh()
    if not I.AnimRefresh then
        print("[FLOW:Anim] I.AnimRefresh not found - poses will not survive a "
            .. "first/third-person switch. Make sure scripts/AnimRefresh/"
            .. "AnimRefresh_v4.lua is registered in FLOW_AMF.omwscripts.")
        return
    end

    -- verify = true buys a second delivery a second after a boundary change,
    -- covering a model rebuild that finishes AFTER the first one (nothing in
    -- openmw.animation can report that, so a second call is the only cover).
    --
    -- Take a Seat declines this because it re-issues a looping pose and a
    -- second call restarts it visibly. FLOW is in the other camp for one
    -- reason only: reissue() below checks animation.isPlaying first, so a
    -- second delivery is a no-op whenever the pose survived. Should that guard
    -- ever be removed, this opt-in has to go with it.
    I.AnimRefresh.subscribe("FLOW", function()
        if reissue then reissue() end
    end, { verify = true })
end

function Anim.setVariant(name)
    pendingVariant = name
end

-- Last variant actually played, per state. resolveGroup falls back to this so
-- a replay that sets no variant reuses the one in flight.
local lastVariant = {}

-- Resolves a GROUPS entry to an actual group name, honouring `variants`.
local function resolveGroup(entry)
    if not entry then return nil end
    if entry.variants then
        -- Fallback chain, and the order matters.
        --
        -- This used to be a bare `pendingVariant or "right"`. That worked only
        -- because every directional entry happened to have a "right" key -
        -- Ladder's are up/down/idle, so a replay with no variant set resolved
        -- to nil and the clip silently stopped. AnimRefresh's reissue is
        -- exactly such a replay, and so is any future caller.
        --
        -- Prefer the variant just requested; else the one last played for this
        -- state, which keeps a left shimmy replaying left rather than flipping
        -- right; else any key at all, so a new entry cannot resolve to nil for
        -- want of a convention it never adopted.
        local key = pendingVariant or lastVariant[entry]
        local group = key and entry.variants[key]
        if not group then
            for k, g in pairs(entry.variants) do key, group = k, g; break end
        end
        if key then lastVariant[entry] = key end
        return group
    end

    -- List form: pick one at random. Restored after a merge dropped it - the
    -- symptom was that only the first clip ever played, because `group` was
    -- reverted to a plain string and there was nothing to choose between.
    if type(entry.group) == "table" then
        local n = #entry.group
        if n == 0 then return nil end
        return entry.group[math.random(n)]
    end
    return entry.group
end

-- =============================================================================
-- ONE-SHOT GROUP VERIFICATION
--
-- Every animation failure in this mod so far has come down to the same
-- question - is the configured group actually present in the animation set
-- loaded on THIS actor? - and until now there was no way to answer it
-- except by inference from the symptom (T-pose = missing, nothing at all =
-- ambiguous). animation.hasGroup() answers it directly.
--
-- Called once from main.lua's cold init, not per frame. Also probes the
-- vanilla 'jump' group, since states/airborne.lua's landing fast-path
-- depends on it existing.
-- =============================================================================
local verified = false

function Anim.verifyGroups()
    if verified then return end
    verified = true

    if not animation.hasGroup then
        print("[FLOW][anim] animation.hasGroup unavailable - skipping group probe")
        return
    end

    -- Collect every group name this file can ever play, flattening variants.
    -- Guarded on type: a malformed GROUPS table (an entry that isn't a table)
    -- used to make this throw, since entry.group was indexed outside pcall.
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
        -- No pcall: the `if not animation.hasGroup then` capability check
        -- above already covers the only real failure (the function being
        -- absent on an older build). Wrapping each call as well could only
        -- hide a genuine mistake (RESEARCH 2.4).
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

-- ==============================================
-- PUBLIC API - called only from core/state_manager.lua's setState()
-- ==============================================
-- Remembers the last thing we asked for, so AnimRefresh can replay it.
local lastRequest = nil

reissue = function()
    if not lastRequest then return end

    -- IDEMPOTENCE. Required by AnimRefresh v4, not merely polite: v4 delivers
    -- once shortly after subscribe() and twice after onLoad, so this WILL be
    -- called when nothing was lost. Without the check below, entering a cell
    -- while hanging from a ledge would restart the hang pose from frame 0, and
    -- FLOW's `verify = true` opt-in would do the same a second later.
    --
    -- Tested against currentGroup, NOT against resolveGroup(lastRequest):
    -- list-form entries (Vault, Mantle) pick a clip at random, so resolveGroup
    -- can name a different clip than the one actually playing and we would
    -- cancel a perfectly good pose to replay a sibling of it.
    --
    -- If the clip is gone, the rebuild really did drop it and we replay. A
    -- one-shot that simply finished is not replayed either, because
    -- onStateChange clears lastRequest as soon as a non-animating state is
    -- entered - lastRequest being non-nil IS "an animating state is active".
    if currentGroup and animation.isPlaying(self, currentGroup) then return end

    currentGroup = nil   -- force playGroup past its "already playing" guard
    playGroup(lastRequest.state, lastRequest.looping)
end

-- NOTE: an Anim.getGroupDuration() helper lived here, reading a clip's length
-- from its start/stop text keys so a state could drive movement over the
-- animation's real duration. It was removed with its only consumer (Shimmy):
-- a duration that can change between steps makes the lerp restart against a
-- different denominator each time, which judders far worse than a slightly
-- mismatched constant. Timing mismatches belong in the .kf, not in a runtime
-- query.

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
