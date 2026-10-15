---@omw-context player
-- Soft dependency on h3lp scripts.s3 timers, with local fallbacks.
local core = require('openmw.core')
local vfs = require('openmw.vfs')

local function tryRequire(path, vfsPath)
    if not vfs.fileExists(vfsPath) then return nil end
    return require(path)
end

local h3Every = tryRequire('scripts.s3.every', 'scripts/s3/every.lua')

local H3 = {
    available = (h3Every ~= nil),
}

print("[FLOW:H3] timer backend: " ..
      (H3.available and "h3lp scripts.s3" or "FLOW internal fallback"))

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

-- Returns a closure that fires true once per completed interval.
function H3.every(interval)
    if h3Every then return h3Every(interval) end
    return fallbackEvery(interval)
end

return H3
