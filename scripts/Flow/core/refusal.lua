---@omw-context player
-- Short memory of a refused target, so a held key does not re-run a move's
-- entry probes every frame against the same spot.
local core = require('openmw.core')

local Refusal = {}
Refusal.__index = Refusal

function Refusal.new(duration, radius)
    return setmetatable({ duration = duration, radius = radius, pos = nil, untilT = 0 }, Refusal)
end

function Refusal:block(pos)
    self.pos = pos
    self.untilT = core.getRealTime() + self.duration
end

-- A nil candidate counts as blocked while the memory is live.
function Refusal:blocks(candidate)
    if core.getRealTime() >= self.untilT then return false end
    if not (self.pos and candidate) then return true end
    return (candidate - self.pos):length() < self.radius
end

return Refusal
