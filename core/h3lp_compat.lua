---@omw-context player
--[[
    core/h3lp_compat.lua

    Soft dependency on H3lp Yours3lf's scripts.s3.every / scripts.s3.cooldown
    timer utilities. If H3 is installed, FLOW calls its real functions
    directly - nothing is copied or reimplemented from them. If it's not
    installed, this provides small independent fallbacks with the exact
    same calling convention, so the rest of FLOW never needs to know or
    care which backend is active.

    NOTE ON DEPENDENCY SHAPE: h3lp's scripts.s3.* utility modules (this
    file's target) are plain require()'d files, not something exposed
    through openmw.interfaces like I.SharedRay or I.ErnGliderSurf, so there
    is no `if I.SomeInterface then` to test. See tryRequire below for how
    that is tested instead, and why it is not a pcall.

    Separately: these utility modules only need H3's data directory
    merged (require() alone is enough) - unlike H3's s3lf module, which
    additionally needs "H3lp Yours3lf.esp" enabled in the content list for
    its per-actor script attachment to populate I.s3.lf at all. See
    docs/h3lp_and_cod3x_notes.md for why s3lf itself isn't adopted here yet.
]]--

local core = require('openmw.core')
local vfs = require('openmw.vfs')

-- =============================================================================
-- SOFT DEPENDENCY TEST
--
-- THIS USED TO BE `pcall(require, path)`, and the reasoning behind that was
-- half right: a missing file does throw on require() rather than returning nil,
-- and h3lp exposes no interface to test. But the conclusion did not follow, and
-- the guard was hiding something.
--
-- IT WAS AVOIDABLE. vfs.fileExists answers "is h3lp installed" without loading
-- anything, and openmw.vfs is available in every script context. That is the
-- same shape as every other capability test in this mod - getUnclipped,
-- hasGroup, addTextKeyHandler - rather than an exception to it.
--
-- IT CONFLATED TWO DIFFERENT FAILURES. pcall(require, ...) cannot tell "h3lp is
-- not installed" from "h3lp is installed and threw while loading". A syntax
-- error or a load-time bug in h3lp's own file landed in the same branch as
-- absence: FLOW silently substituted its fallback, printed nothing, and h3lp
-- stayed broken with no indication anywhere. That is a failure reported as a
-- success - the same shape as I.Settings.registerRenderer logging a refusal and
-- returning normally, which is the bug that made the settings page vanish twice
-- while a pcall around it reported success.
--
-- So the two questions are asked separately. fileExists decides whether h3lp is
-- there; if it is, require runs UNGUARDED, and a broken h3lp raises with h3lp's
-- own stack. That is the right outcome: it is h3lp's bug, it is visible, and it
-- is attributed. Being quietly replaced by a fallback is how a user ends up
-- wondering why H3 timers are not being used.
--
-- Path form: require('scripts.s3.every') resolves to the VFS path
-- scripts/s3/every.lua, so the two arguments are the same file named two ways.
-- =============================================================================
local function tryRequire(path, vfsPath)
    if not vfs.fileExists(vfsPath) then return nil end
    return require(path)
end

local h3Every = tryRequire('scripts.s3.every', 'scripts/s3/every.lua')
local h3Cooldown = tryRequire('scripts.s3.cooldown', 'scripts/s3/cooldown.lua')

local H3 = {
    available = (h3Every ~= nil and h3Cooldown ~= nil),
}

-- H3.available was computed and never read by anything, which made "which timer
-- backend is live" unanswerable from outside this file. Rather than delete the
-- field, report it once at load, the same way Sensor and playerAnim report which
-- copy of SharedRay and AnimRefresh claimed their interfaces. Once per session,
-- not per frame - and this mod has been debugged blind on exactly this kind of
-- "whose implementation actually won" question more than once.
print("[FLOW:H3] timer backend: " ..
      (H3.available and "h3lp scripts.s3" or "FLOW internal fallback"))

-- ==============================================
-- FALLBACKS (only used when H3 isn't installed)
-- Independent implementations, same wall-clock-based calling convention
-- as h3lp's own (no dt argument - each returned closure checks
-- core.getRealTime() itself).
-- ==============================================
local function fallbackEvery(interval)
    local elapsed = 0
    local last = core.getRealTime()
    return function()
        local now = core.getRealTime()
        elapsed = elapsed + (now - last)
        last = now
        if elapsed >= interval then
            elapsed = elapsed % interval
            return true
        end
        return false
    end
end

local function fallbackCooldown(interval)
    local elapsed = interval  -- starts ready, matching h3lp's cooldown()
    local last = core.getRealTime()
    return function()
        local now = core.getRealTime()
        elapsed = elapsed + (now - last)
        last = now
        if elapsed >= interval then
            elapsed = 0
            return true
        end
        return false
    end
end

-- Returns a closure that fires true once per completed interval.
function H3.every(interval)
    if h3Every then return h3Every(interval) end
    return fallbackEvery(interval)
end

-- Returns a closure that fires true at most once per interval, starting ready.
function H3.cooldown(interval)
    if h3Cooldown then return h3Cooldown(interval) end
    return fallbackCooldown(interval)
end

return H3
