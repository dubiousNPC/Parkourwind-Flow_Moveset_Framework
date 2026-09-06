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
    through openmw.interfaces like I.SharedRay or I.ErnGliderSurf. A
    missing file throws on require() instead of just returning nil, hence
    the pcall guard here rather than an `if I.SomeInterface then` check.
    Separately: these utility modules only need H3's data directory
    merged (require() alone is enough) - unlike H3's s3lf module, which
    additionally needs "H3lp Yours3lf.esp" enabled in the content list for
    its per-actor script attachment to populate I.s3.lf at all. See
    docs/h3lp_and_cod3x_notes.md for why s3lf itself isn't adopted here yet.
]]--

local core = require('openmw.core')

local function tryRequire(path)
    local ok, mod = pcall(require, path)
    if ok then return mod end
    return nil
end

local h3Every = tryRequire('scripts.s3.every')
local h3Cooldown = tryRequire('scripts.s3.cooldown')

local H3 = {
    available = (h3Every ~= nil and h3Cooldown ~= nil),
}

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
