-- Unit tests: the measured manifest and FallPick (bearing maths, durations).
-- Selection by the authored layout is tested in test_fall_plan.lua. No OpenMW.
--   python3 tools/sim/run_lua.py tools/sim/test_fall_pick.lua .
MOD_ROOT = arg[1] or "."
package.path = MOD_ROOT .. "/?.lua;" .. package.path
local Pick = require("scripts/Flow/core/fall_pick")
local clips = require("scripts/Flow/core/fall_clips")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "")) end
end
local function near(a, b, e) return a and math.abs(a - b) <= (e or 0.5) end
local function draws(opts, n)
    local seen, list = {}, {}
    for i = 1, n do
        local k = (i % 7) + 1
        local c = Pick.choose(clips, setmetatable({ random = function(m) return ((k - 1) % m) + 1 end }, { __index = opts }))
        if c and not seen[c.group] then seen[c.group] = true; list[#list + 1] = c.group end
    end
    table.sort(list)
    return seen, table.concat(list, ",")
end

print("[1] bearing off the facing")
check("ahead = 0", near(Pick.bearing(0, 300, 0, 1), 0))
check("right = 90", near(Pick.bearing(300, 0, 0, 1), 90))
check("behind = 180", near(math.abs(Pick.bearing(0, -300, 0, 1)), 180))
-- A forward pitched 60 deg down has horizontal length 0.5. Unnormalised, the
-- 45-deg travel would read as atan(1/0.5) = 63 deg; normalised it stays 45.
check("pitched forward normalised (45 stays 45)", near(Pick.bearing(200, 200, 0, 0.5), 45), Pick.bearing(200, 200, 0, 0.5))
check("no horizontal travel = nil", Pick.bearing(0, 0, 0, 1) == nil)

print("[2] the manifest")
local roles = {}
for _, c in ipairs(clips) do roles[c.role] = (roles[c.role] or 0) + 1 end
check("23 measured clips (+ set 101, 2026-11-18)", #clips == 23, #clips)
check("10 air, 4 land, 5 landHard, 4 recover", roles.air == 10 and roles.land == 4 and roles.landHard == 5 and roles.recover == 4,
    string.format("%s %s %s %s", roles.air, roles.land, roles.landHard, roles.recover))

-- The selection sections below exercise FallPick's measured picker, which no
-- longer drives play (core/fall_plan.lua does); they keep it honest on the
-- sets it was written for, 1-3. Set 101 is the skydive's, picked by the plan.
do
    local legacy = {}
    for _, c in ipairs(clips) do if not c.group:find("^pwfall101") then legacy[#legacy + 1] = c end end
    clips = legacy
end
print("[3] direction is honoured, the clip is not fixed")
local seen, l = draws({ role = "air", bearing = 90 }, 40)
check("travelling right -> pwfall1b (the right roll)", seen.pwfall1b and not seen.pwfall2a, l)
seen, l = draws({ role = "air", bearing = -70 }, 40)
check("travelling left -> a pool of the left rolls", seen.pwfall1a and seen.pwfall1c and seen.pwfall1ds and not seen.pwfall1b, l)
seen, l = draws({ role = "air", bearing = 180 }, 40)
check("travelling back -> the on-the-back set", seen.pwfall2a and seen.pwfall2c and not seen.pwfall1b, l)
seen, l = draws({ role = "air", bearing = 180, heavy = true }, 40)
check("heavy fall narrows to the big tumbles", seen.pwfall2ds and not seen.pwfall2a, l)
seen, l = draws({ role = "air" }, 40)
check("no bearing -> the whole air pool", seen.pwfall1b and seen.pwfall2a, l)
local seenX = {}
for k = 1, 6 do
    local c = Pick.choose(clips, { role = "air", bearing = -70, exclude = "pwfall1a", random = function(m) return ((k - 1) % m) + 1 end })
    seenX[c.group] = true
end
check("the clip just played is passed over when another is in reach", not seenX.pwfall1a and seenX.pwfall1c)
local c = Pick.choose(clips, { role = "air", bearing = 90, exclude = "pwfall1b", random = function() return 1 end })
check("...and repeated when it is the only one that fits", c and c.group == "pwfall1b", c and c.group)

print("[4] hasGroup is the safety rail")
c = Pick.choose(clips, { role = "air", bearing = 90, hasGroup = function(g) return g ~= "pwfall1b" end })
check("a missing group is never offered", c and c.group ~= "pwfall1b", c and c.group)
c = Pick.choose(clips, { role = "air", hasGroup = function() return false end })
check("none on the skeleton -> nil (caller falls back)", c == nil)

print("[5] landings")
local seq = Pick.landing(clips, 800, 1100, { random = function() return 1 end })
check("soft impact: one dive-roll onto the feet", #seq == 1 and seq[1].role == "land", seq[1] and seq[1].group)
seq = Pick.landing(clips, 1500, 1100, {})
check("hard impact: landHard then its measured follow-up", #seq == 2 and seq[1].group == "pwfall3es" and seq[2].group == "pwfall3up",
    seq[1] and (seq[1].group .. "," .. (seq[2] and seq[2].group or "-")))
check("hard landing lasts both clips", near(Pick.duration(seq), 3.333, 0.01), Pick.duration(seq))
seq = Pick.landing(clips, 1500, 1100, { hasGroup = function(g) return g ~= "pwfall3es" end })
check("no hard clip on the skeleton -> a dive-roll instead", #seq == 1 and seq[1].role == "land", seq[1] and seq[1].group)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
