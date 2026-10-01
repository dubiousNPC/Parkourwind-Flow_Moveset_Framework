---@omw-context player
-- Actor dimensions from the engine, cached. Replaces a hardcoded 128.
local mwSelf = require('openmw.self')

local Body = {}

local height = nil
local halfWidth = nil

local FALLBACK_HEIGHT = 128.0
local FALLBACK_HALF_WIDTH = 22.0

local function measure()
    local box = mwSelf:getBoundingBox()
    if not box then return end
    local h = box.halfSize.z * 2
    if h < 32 or h > 512 then return end   -- model not loaded yet; retry next call
    height = h
    halfWidth = math.max(box.halfSize.x, box.halfSize.y)
end

function Body.height()
    if not height then measure() end
    return height or FALLBACK_HEIGHT
end

function Body.halfWidth()
    if not halfWidth then measure() end
    return halfWidth or FALLBACK_HALF_WIDTH
end

-- Height as a fraction of the actor's own height.
function Body.frac(f)
    return Body.height() * f
end

return Body
