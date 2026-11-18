---@omw-context any
-- Fall clips by the AUTHORED layout of the .kf files, and the landing check's
-- outcome bands. No openmw import: the sim runs this file as it is.
--
-- The layout, as the animations were made:
--   xpwfalling1  forward:  1a right, 1b left, 1c straight, 1ds severe failure,
--                          1up recovery (the baseline recovery for every fall)
--   xpwfalling2  backward: 2a right, 2b left, 2c straight, 2ds severe failure
--                          (2up exists; not used, 1up is the baseline)
--   xpwfalling3  acrobatic, for high skill: 3a right, 3b left, 3c straight
--                tumbles on a CLOSE check, forward falls; 3bkup the backward
--                tumble on a CLOSE check, backward falls (added 2026-11-17;
--                only the male third-person and beast sets have it, the rest
--                take 3c); 3df handspring on a CLEAN one (the highest
--                display); 3es severe failure on a FAILED one
--                (3up is reserved for a future high-skill variance pass)
--                Set 3 is for manoeuvres only: it never follows a skydive.
--   xpwfalling101 + xpwfall101df  SKYDIVE landings (added 2026-11-18): 101a
--                right, 101b left, 101c straight, 101ds severe (the beast set
--                keys it 101es), all landing face down from the skydive
--                posture; 101up gets up from face down; 101df is the landing
--                that is made (a roll onto the feet). Only the male third-
--                person and beast sets have it; the rest land a skydive on set
--                1, never set 3.
--
-- Selection goes by this table, not by the manifest's measured `turn`: the
-- measured roll direction and the authored side disagree on several clips,
-- and the author's intent wins. The manifest still supplies each clip's
-- length and says which groups the skeleton has.
local Plan = {}

Plan.RECOVER = "pwfall1up"
Plan.RESERVED = { pwfall3up = true, pwfall2up = true }

Plan.FALL = {
    fwd  = { right = "pwfall1a", left = "pwfall1b", straight = "pwfall1c", severe = "pwfall1ds" },
    back = { right = "pwfall2a", left = "pwfall2b", straight = "pwfall2c", severe = "pwfall2ds" },
}
Plan.SKY = { right = "pwfall101a", left = "pwfall101b", straight = "pwfall101c",
             severe = { "pwfall101ds", "pwfall101es" },
             landed = "pwfall101df", recover = "pwfall101up" }

Plan.ACRO = { right = "pwfall3a", left = "pwfall3b", straight = "pwfall3c",
              display = "pwfall3df", failed = "pwfall3es",
              -- the KF's group is "pwfall3bkup"; "pwfall3bk" is accepted too,
              -- first one this skeleton defines wins
              back = { "pwfall3bk", "pwfall3bkup" } }

-- Travel bearing off the facing (0 ahead, +90 right, 180 back), or nil when
-- there is no real horizontal travel (dropping straight down).
Plan.SIDE_DEG = 30          -- within this of the fore-aft line: "straight"

function Plan.direction(bearing)
    if bearing == nil then return "fwd", "straight" end
    local b = ((bearing + 180) % 360) - 180      -- -180..180
    local dir = (math.abs(b) <= 90) and "fwd" or "back"
    local off = (dir == "fwd") and b or ((b > 0) and (180 - b) or (-180 - b))
    -- `off` is the angle from the fore-aft line on the same side as b
    local side
    if math.abs(off) < Plan.SIDE_DEG then side = "straight"
    elseif b > 0 then side = "right" else side = "left" end
    return dir, side
end

-- The landing's roll. A LANDING is the one check that is rolled: it never
-- refuses anything (the move checks stay deterministic, so the priority ladder
-- stays predictable), and without a roll the same drop with the same stats
-- would always land the same way. FALL_ROLL = 0 makes it deterministic too.
Plan.FALL_ROLL = 15
function Plan.roll(rnd)
    rnd = rnd or math.random
    return (rnd() * 2 - 1) * Plan.FALL_ROLL
end

-- Check margin (chance - difficulty, with the roll) into a band.
Plan.CLOSE = 15             -- 0 <= margin < CLOSE: made it, barely
Plan.SEVERE = -25           -- margin < SEVERE: a severe failure

function Plan.outcome(margin)
    if margin >= Plan.CLOSE then return "clean" end
    if margin >= 0 then return "close" end
    if margin >= Plan.SEVERE then return "fail" end
    return "severe"
end

local function first(has, ...)
    for i = 1, select("#", ...) do
        local g = select(i, ...)
        if g and (not has or has(g)) then return g end
    end
    return nil
end

-- The clip for the out-of-control air pose (a botched move, falling). Heavy
-- (fast) falls take the file's severe tumble. `exclude` is the clip just
-- played: the re-draw takes a sibling from the same file instead.
-- "fwd" / "back" for an air clip of the FALL table, else nil.
function Plan.dirOf(group)
    for dir, set in pairs(Plan.FALL) do
        for _, g in pairs(set) do if g == group then return dir end end
    end
    return nil
end

function Plan.airClip(bearing, heavy, has, exclude)
    local dir, side = Plan.direction(bearing)
    local set = Plan.FALL[dir]
    local want = heavy and set.severe or set[side]
    if want == exclude then
        local order = { set[side], set.straight, set.right, set.left, set.severe }
        for _, g in ipairs(order) do
            if g ~= exclude and (not has or has(g)) then return g end
        end
    end
    return first(has, want, set.straight, Plan.FALL.fwd.straight)
end

-- The landing sequence (group names, in order) for a check outcome.
--   ctx.bearing    travel bearing at touchdown (or nil)
--   ctx.highSkill  acrobatics at or above the high-skill tier
--   ctx.fallen     the body is already down (the air pose showed): recover only
--   ctx.dir        "fwd"/"back" from the air clip that showed, overriding the bearing
--   ctx.skydive    a released skydive's landing: set 101 (set 1 where the
--                  skeleton lacks it); skill tier does not matter, set 3 never
--   has(group)     the skeleton defines it
-- Returns {} for "no FLOW landing" (a plain landing; the caller goes on to Idle).
function Plan.landing(outcome, ctx, has)
    ctx = ctx or {}
    local dir, side = Plan.direction(ctx.bearing)
    -- after the air pose, keep its direction: a body shown tumbling backward
    -- does not land forward because the last airborne frame drifted
    if ctx.dir == "fwd" or ctx.dir == "back" then dir = ctx.dir end
    local seq = {}
    local function add(g)
        if type(g) == "table" then
            for _, alt in ipairs(g) do if add(alt) then return true end end
            return false
        end
        if g and (not has or has(g)) then seq[#seq + 1] = g; return true end
    end
    local function recover() add(Plan.RECOVER) end

    if ctx.skydive then
        if outcome == "clean" or outcome == "close" then
            add(Plan.SKY.landed)                            -- {} without it: a plain landing
            return seq
        end
        local g = (outcome == "severe") and Plan.SKY.severe or Plan.SKY[side]
        if add(g) or add(Plan.SKY.straight) then
            if not add(Plan.SKY.recover) then recover() end -- 101up starts face down, as 101a-ds end
            return seq
        end
        -- no set 101 on this skeleton: land it on set 1, forward
        local set = Plan.FALL.fwd
        if not add((outcome == "severe") and set.severe or set[side]) then add(set.straight) end
        recover()
        return seq
    end

    if outcome == "clean" or outcome == "close" then
        if not ctx.highSkill then return seq end           -- an ordinary landing
        if outcome == "clean" then
            if not add(Plan.ACRO.display) then add(Plan.ACRO[side]) end
        else
            local tumble = (dir == "back") and Plan.ACRO.back or Plan.ACRO[side]
            if not add(tumble) then add(Plan.ACRO.straight) end
        end
        return seq                                          -- 3a-c/3df end on the feet
    end

    -- fail / severe
    if ctx.fallen then recover(); return seq end
    if ctx.highSkill then
        add(Plan.ACRO.failed)
    else
        local set = Plan.FALL[dir]
        local g = (outcome == "severe") and set.severe or set[side]
        if not add(g) then add(set.straight) end
    end
    recover()
    return seq
end

return Plan
