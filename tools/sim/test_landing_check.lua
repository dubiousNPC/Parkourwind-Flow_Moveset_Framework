-- Unit tests: the landing check's inputs (skill, agility, LUCK, remaining
-- FATIGUE %) and its bands. Uses the sim's openmw mock.
--   python3 tools/sim/run_lua.py tools/sim/test_landing_check.lua .
MOD_ROOT = arg[1] or "."
local here = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local M = require("mock")
local SkillCheck = require("scripts/Flow/core/skill_check")
local Plan = require("scripts/Flow/core/fall_plan")
local pass, fail = 0, 0
local function check(name, ok, got)
    if ok then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (got ~= nil and ("  -- " .. tostring(got)) or "")) end
end
local function stat(b) return setmetatable({ base = b, modifier = 0, damage = 0 }, {
    __index = function(t, k) if k == "modified" then return t.base + t.modifier end end }) end
local function set(acro, agi, luck, fatiguePct)
    M.stats.acrobatics = stat(acro); M.stats.agility = stat(agi); M.stats.luck = stat(luck)
    M.stats.fatigue = { current = 200 * fatiguePct, base = 200, modifier = 0 }
end

print("[1] Luck and remaining fatigue move the chance")
set(30, 50, 50, 1.0); local base = SkillCheck.fallChance()
set(30, 50, 80, 1.0); local lucky = SkillCheck.fallChance()
set(30, 50, 20, 1.0); local unlucky = SkillCheck.fallChance()
check("more Luck, higher chance", lucky > base and base > unlucky, string.format("%.1f %.1f %.1f", unlucky, base, lucky))
set(30, 50, 50, 0.5); local half = SkillCheck.fallChance()
set(30, 50, 50, 0.0); local empty = SkillCheck.fallChance()
check("less fatigue left, lower chance", base > half and half > empty, string.format("%.1f %.1f %.1f", base, half, empty))
check("an empty bar costs 40% of the chance (x1.25 -> x0.75)", math.abs(empty / base - 0.6) < 0.01, empty / base)

print("[2] the check is deterministic without a roll")
set(30, 50, 50, 1.0)
local a = SkillCheck.fallCheck(1500); local b = SkillCheck.fallCheck(1500)
check("same stats, same drop, same margin", a == b, a)
check("harder impact, lower margin", SkillCheck.fallCheck(2500) < SkillCheck.fallCheck(1000))

print("[3] who lands how (no roll)")
-- typical new character: Acrobatics 15, Agility 45, Luck 40, rested
set(15, 45, 40, 1.0)
local m, high = SkillCheck.fallCheck(900)
check("new character, a 900 u/s landing: makes it", not high and Plan.outcome(m) ~= "fail" and Plan.outcome(m) ~= "severe", string.format("%+.0f %s", m, Plan.outcome(m)))
m = SkillCheck.fallCheck(2500)
check("new character, a 2500 u/s skydive landing: severe", Plan.outcome(m) == "severe", string.format("%+.0f", m))
set(15, 45, 40, 0.1)
m = SkillCheck.fallCheck(1300)
check("new character, exhausted, 1300 u/s: fails", Plan.outcome(m) == "fail" or Plan.outcome(m) == "severe", string.format("%+.0f", m))
-- acrobat: Acrobatics 75, Agility 70, Luck 50
set(75, 70, 50, 1.0)
m, high = SkillCheck.fallCheck(2500)
check("acrobat is high-skill", high)
check("acrobat, rested, 2500 u/s: lands it before the roll (close or clean)", m >= 0, string.format("%+.0f", m))
set(75, 70, 50, 1.0)
m = SkillCheck.fallCheck(1500)
check("acrobat, rested, 1500 u/s: clean (3df)", Plan.outcome(m) == "clean", string.format("%+.0f", m))
set(75, 70, 50, 0.3)
m = SkillCheck.fallCheck(2500)
check("acrobat, tired, 2500 u/s: close (a tumble) or failed (3es)", Plan.outcome(m) ~= "clean", string.format("%+.0f %s", m, Plan.outcome(m)))
set(75, 70, 80, 0.3)
local m2 = SkillCheck.fallCheck(2500)
check("...and Luck 80 pulls the same tired acrobat up", m2 > m, string.format("%+.0f -> %+.0f", m, m2))

print("[4] the roll")
-- odds table for the report: P(band) over the uniform roll
local profiles = {
    { "new (Acro 15, Agi 45, Luck 40)", 15, 45, 40 }, { "trained (Acro 40, Agi 55, Luck 50)", 40, 55, 50 },
    { "acrobat (Acro 75, Agi 70, Luck 50)", 75, 70, 50 }, { "master (Acro 100, Agi 80, Luck 60)", 100, 80, 60 },
}
for _, pr in ipairs(profiles) do
    for _, fat in ipairs({ 1.0, 0.3 }) do
        for _, v in ipairs({ 1200, 2000, 2800 }) do
            set(pr[2], pr[3], pr[4], fat)
            local cnt = { clean = 0, close = 0, fail = 0, severe = 0 }
            local high
            for k = 0, 300 do
                local mm; mm, high = SkillCheck.fallCheck(v, Plan.roll(function() return k / 300 end))
                local o = Plan.outcome(mm); cnt[o] = cnt[o] + 1
            end
            print(string.format("ODDS|%s|%d%%|%d|%s|%d|%d|%d|%d", pr[1], fat * 100, v, high and "high" or "normal",
                math.floor(cnt.clean / 3.01 + 0.5), math.floor(cnt.close / 3.01 + 0.5), math.floor(cnt.fail / 3.01 + 0.5), math.floor(cnt.severe / 3.01 + 0.5)))
        end
    end
end
local lo, hi = Plan.roll(function() return 0 end), Plan.roll(function() return 1 end)
check("the roll spans +/-15", lo == -15 and hi == 15, lo .. " " .. hi)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
