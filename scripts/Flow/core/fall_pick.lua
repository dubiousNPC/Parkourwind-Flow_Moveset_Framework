---@omw-context any
-- Fall clip selection from the measured manifest (core/fall_clips.lua).
--
-- The Hit Reactions method applied to falls, with no damage event and so no
-- MSS: what drives the choice is the fall itself, which FLOW already has.
--   * bearing   - where the body is travelling, off its own facing (0 ahead,
--                 90 right, 180 back). Scored against each clip's measured
--                 `turn`: the direction it actually tumbles the body.
--   * severity  - impact speed for a landing; for the air pool it only
--                 widens the choice to the heavier tumbles.
--   * hasGroup  - every candidate is checked against this skeleton first.
-- Candidates within SLACK of the best score form a pool and one is drawn at
-- random, so the direction is honoured but the exact clip is not fixed.
--
-- No openmw import: the sim runs this file as it is.
local Pick = {}

Pick.SLACK = 35            -- degrees; the candidate pool around the best match
Pick.HEAVY_TUMBLE = 150    -- a clip whose measured tumble exceeds this is "heavy"

local function gap(a, b)
    local d = math.abs(a - b) % 360
    return d > 180 and 360 - d or d
end
Pick.gap = gap

-- Bearing of a horizontal velocity relative to the actor's facing. `fwd` is
-- the actor's horizontal forward; it is NORMALISED here (direction_math's
-- fix): a pitched-down forward has a short horizontal part, and an unscaled
-- one stretches every angle that is not dead ahead.
function Pick.bearing(vx, vy, fx, fy)
    local fl = math.sqrt(fx * fx + fy * fy)
    if fl < 1e-6 then return nil end
    fx, fy = fx / fl, fy / fl
    local ahead = vx * fx + vy * fy
    local right = vx * fy - vy * fx      -- (fx, fy) turned a quarter to the right
    if ahead * ahead + right * right < 1e-6 then return nil end
    return math.deg(math.atan2 and math.atan2(right, ahead) or math.atan(right, ahead))
end

-- opts: role (required), bearing (deg or nil = any), heavy (bool),
--       hasGroup(fn), random(fn n -> 1..n), exclude (group to avoid repeating)
function Pick.choose(clips, opts)
    local hasGroup = opts.hasGroup or function() return true end
    local rnd = opts.random or math.random
    local cands = {}
    for _, c in ipairs(clips) do
        if c.role == opts.role and hasGroup(c.group) then cands[#cands + 1] = c end
    end
    if #cands == 0 then return nil end

    -- Severity narrows first (the .md's near/far step), but never to nothing.
    if opts.heavy ~= nil and opts.role == 'air' then
        local narrowed = {}
        for _, c in ipairs(cands) do
            if ((c.tumble or 0) > Pick.HEAVY_TUMBLE) == opts.heavy then narrowed[#narrowed + 1] = c end
        end
        if #narrowed > 0 then cands = narrowed end
    end

    local scored, best = {}, math.huge
    for _, c in ipairs(cands) do
        local s = opts.bearing and gap(c.turn or 0, opts.bearing) or 0
        if c.group == opts.exclude then s = s + Pick.SLACK end   -- prefer a change
        scored[#scored + 1] = { c = c, s = s }
        if s < best then best = s end
    end
    local pool = {}
    for _, e in ipairs(scored) do
        if e.s <= best + Pick.SLACK then pool[#pool + 1] = e.c end
    end
    return pool[rnd(#pool)]
end

-- The landing for an impact: dive-roll onto the feet, or a hard landing that
-- chains into its measured follow-up. Returns a list of clips to play in order.
function Pick.landing(clips, impactSpeed, hard, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    o.role = (impactSpeed >= hard) and 'landHard' or 'land'
    local first = Pick.choose(clips, o) or (o.role == 'landHard' and Pick.choose(clips, { role = 'land',
        bearing = o.bearing, hasGroup = o.hasGroup, random = o.random }))
    if not first then return {} end
    local seq, seen = { first }, { [first.group] = true }
    local byGroup = {}
    for _, c in ipairs(clips) do byGroup[c.group] = c end
    local nxt = first.chainTo and byGroup[first.chainTo]
    while nxt and not seen[nxt.group] and (not o.hasGroup or o.hasGroup(nxt.group)) do
        seq[#seq + 1] = nxt; seen[nxt.group] = true
        nxt = nxt.chainTo and byGroup[nxt.chainTo]
    end
    return seq
end

function Pick.duration(seq, speed)
    local d = 0
    for _, c in ipairs(seq) do d = d + c.dur end
    return d / (speed or 1)
end

return Pick
