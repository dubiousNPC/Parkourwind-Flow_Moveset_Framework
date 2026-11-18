-- Unit tests: the authored fall layout and the landing bands. No OpenMW.
--   python3 tools/sim/run_lua.py tools/sim/test_fall_plan.lua .
package.path = (arg and arg[1] or ".") .. "/?.lua;" .. package.path
local Plan = require("scripts/Flow/core/fall_plan")
local clips = require("scripts/Flow/core/fall_clips")
local pass, fail = 0, 0
local function check(name, ok, got)
    if ok then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (got ~= nil and ("  -- " .. tostring(got)) or "")) end
end
local function seqs(t) return table.concat(t, ",") end
local all = function() return true end
local known = {}
for _, c in ipairs(clips) do known[c.group] = true end
local real = function(g) return known[g] == true end   -- the measured skeleton

print("[1] direction and side from the travel bearing")
local cases = {
    { nil, "fwd", "straight" }, { 0, "fwd", "straight" }, { 20, "fwd", "straight" }, { 45, "fwd", "right" },
    { -60, "fwd", "left" }, { 90, "fwd", "right" }, { 120, "back", "right" }, { 170, "back", "straight" },
    { -170, "back", "straight" }, { -135, "back", "left" }, { 225, "back", "left" },
}
for _, c in ipairs(cases) do
    local d, s = Plan.direction(c[1])
    check(("bearing %s -> %s %s"):format(tostring(c[1]), c[2], c[3]), d == c[2] and s == c[3], d .. " " .. s)
end

print("[2] the check margin into bands")
check("+30 clean", Plan.outcome(30) == "clean"); check("+15 clean", Plan.outcome(15) == "clean")
check("+5 close", Plan.outcome(5) == "close"); check("0 close", Plan.outcome(0) == "close")
check("-10 fail", Plan.outcome(-10) == "fail"); check("-25 fail", Plan.outcome(-25) == "fail")
check("-26 severe", Plan.outcome(-26) == "severe")

print("[3] landings, ordinary skill")
check("clean: nothing (an ordinary landing)", #Plan.landing("clean", { bearing = 0 }, all) == 0)
check("close: nothing either", #Plan.landing("close", { bearing = 0 }, all) == 0)
check("fail forward right: 1a then 1up", seqs(Plan.landing("fail", { bearing = 60 }, all)) == "pwfall1a,pwfall1up")
check("fail forward left: 1b then 1up", seqs(Plan.landing("fail", { bearing = -60 }, all)) == "pwfall1b,pwfall1up")
check("fail straight down: 1c then 1up", seqs(Plan.landing("fail", {}, all)) == "pwfall1c,pwfall1up")
check("fail back right: 2a then 1up", seqs(Plan.landing("fail", { bearing = 130 }, all)) == "pwfall2a,pwfall1up")
check("fail back straight: 2c then 1up", seqs(Plan.landing("fail", { bearing = 180 }, all)) == "pwfall2c,pwfall1up")
check("severe forward: 1ds then 1up", seqs(Plan.landing("severe", { bearing = 10 }, all)) == "pwfall1ds,pwfall1up")
check("severe back: 2ds then 1up", seqs(Plan.landing("severe", { bearing = -175 }, all)) == "pwfall2ds,pwfall1up")
check("already down (fallen): only 1up", seqs(Plan.landing("severe", { fallen = true }, all)) == "pwfall1up")

print("[4] landings, high skill")
check("clean: the 3df handspring", seqs(Plan.landing("clean", { highSkill = true }, all)) == "pwfall3df")
check("close forward right: the 3a tumble", seqs(Plan.landing("close", { highSkill = true, bearing = 50 }, all)) == "pwfall3a")
check("close left: 3b", seqs(Plan.landing("close", { highSkill = true, bearing = -50 }, all)) == "pwfall3b")
check("close straight: 3c", seqs(Plan.landing("close", { highSkill = true }, all)) == "pwfall3c")
check("close BACKWARD: the 3bkup back tumble", seqs(Plan.landing("close", { highSkill = true, bearing = 180 }, real)) == "pwfall3bkup")
check("close back-right: still 3bkup (one back tumble)", seqs(Plan.landing("close", { highSkill = true, bearing = 130 }, real)) == "pwfall3bkup")
check("close back after a backward air clip: 3bkup", seqs(Plan.landing("close", { highSkill = true, bearing = 0, dir = "back" }, real)) == "pwfall3bkup")
check("a group renamed pwfall3bk is taken first", seqs(Plan.landing("close", { highSkill = true, bearing = 180 }, all)) == "pwfall3bk")
local noBk = function(g) return real(g) and g ~= "pwfall3bkup" end
check("no back tumble on this skeleton (female, 1st person): 3c", seqs(Plan.landing("close", { highSkill = true, bearing = 180 }, noBk)) == "pwfall3c")
check("clean backward: still the 3df display", seqs(Plan.landing("clean", { highSkill = true, bearing = 180 }, real)) == "pwfall3df")
check("failed: 3es then 1up (3up stays reserved)", seqs(Plan.landing("fail", { highSkill = true }, all)) == "pwfall3es,pwfall1up")
check("severe: also 3es then 1up", seqs(Plan.landing("severe", { highSkill = true, bearing = 170 }, all)) == "pwfall3es,pwfall1up")
local used = {}
for _, o in ipairs({ "clean", "close", "fail", "severe" }) do
    for _, h in ipairs({ true, false }) do for _, b in ipairs({ 0, 60, -60, 180, 130, -130 }) do
        for _, f in ipairs({ true, false }) do
            for _, g in ipairs(Plan.landing(o, { highSkill = h, bearing = b, fallen = f }, real)) do used[g] = true end
        end
    end end
end
check("pwfall3up and pwfall2up are never played", not used.pwfall3up and not used.pwfall2up)
check("pwfall3bkup is reachable", used.pwfall3bkup == true)
local missing = {}
for g in pairs(used) do if not known[g] then missing[#missing + 1] = g end end
check("every group the plan uses is in the measured manifest", #missing == 0, table.concat(missing, ","))

check("after a backward air clip, a fail lands backward", seqs(Plan.landing("severe", { bearing = 10, dir = "back" }, all)) == "pwfall2ds,pwfall1up")
check("dirOf: 2c is back, 1a is fwd, 3df is neither", Plan.dirOf("pwfall2c") == "back" and Plan.dirOf("pwfall1a") == "fwd" and Plan.dirOf("pwfall3df") == nil)

print("[4b] skydive landings: set 101, never set 3")
local sky = function(o, b, h, has) return seqs(Plan.landing(o, { skydive = true, bearing = b, highSkill = h }, has or real)) end
check("made (clean), ordinary skill: 101df", sky("clean", nil, false) == "pwfall101df")
check("made (close), high skill: still 101df, no 3x tumble", sky("close", 50, true) == "pwfall101df")
check("clean at high skill: 101df, not the 3df display", sky("clean", nil, true) == "pwfall101df")
check("fail straight: 101c then 101up", sky("fail", nil, false) == "pwfall101c,pwfall101up")
check("fail drifting right: 101a then 101up", sky("fail", 60, false) == "pwfall101a,pwfall101up")
check("fail drifting left: 101b then 101up", sky("fail", -60, false) == "pwfall101b,pwfall101up")
check("fail at high skill: 101, not 3es", sky("fail", nil, true) == "pwfall101c,pwfall101up")
check("severe: 101ds then 101up", sky("severe", nil, false) == "pwfall101ds,pwfall101up")
local beast = function(g) return real(g) and g ~= "pwfall101ds" or g == "pwfall101es" end
check("severe on the beast set (keyed 101es)", sky("severe", nil, false, beast) == "pwfall101es,pwfall101up")
local no101 = function(g) return real(g) and not g:find("^pwfall101") end
check("no set 101 (female / 1st person), made: a plain landing", sky("clean", nil, true, no101) == "")
check("no set 101, fail: set 1 then 1up", sky("fail", 60, false, no101) == "pwfall1a,pwfall1up")
check("no set 101, severe at high skill: 1ds then 1up, still no set 3", sky("severe", nil, true, no101) == "pwfall1ds,pwfall1up")
local skyUsed = {}
for _, o in ipairs({ "clean", "close", "fail", "severe" }) do for _, h in ipairs({ true, false }) do
    for _, b in ipairs({ 0, 60, -60, 180 }) do for _, hs in ipairs({ real, no101 }) do
        for _, g in ipairs(Plan.landing(o, { skydive = true, highSkill = h, bearing = b }, hs)) do skyUsed[g] = true end
    end end
end end
local any3 = false
for g in pairs(skyUsed) do if g:find("^pwfall3") then any3 = true end end
check("no skydive outcome, on any skeleton, reaches set 3", not any3)
check("manoeuvres never reach set 101", (function()
    for _, o in ipairs({ "clean", "close", "fail", "severe" }) do for _, h in ipairs({ true, false }) do
        for _, g in ipairs(Plan.landing(o, { highSkill = h, bearing = 0 }, real)) do if g:find("101") then return false end end
    end end
    return true end)())

print("[5] the skeleton rail")
local no3df = function(g) return g ~= "pwfall3df" end
check("no 3df on this skeleton: the side tumble instead", seqs(Plan.landing("clean", { highSkill = true, bearing = 50 }, no3df)) == "pwfall3a")
local no1a = function(g) return g ~= "pwfall1a" end
check("no 1a: the file's straight clip", seqs(Plan.landing("fail", { bearing = 60 }, no1a)) == "pwfall1c,pwfall1up")
local none = function() return false end
check("nothing on the skeleton: empty (Stumble's fallback variant)", #Plan.landing("fail", {}, none) == 0)

print("[6] the air pose")
check("forward right: 1a", Plan.airClip(60, false, all) == "pwfall1a")
check("back left: 2b", Plan.airClip(-120, false, all) == "pwfall2b")
check("heavy forward: 1ds", Plan.airClip(0, true, all) == "pwfall1ds")
check("heavy back: 2ds", Plan.airClip(180, true, all) == "pwfall2ds")
check("re-draw after 1a: a sibling from the same file", Plan.airClip(60, false, all, "pwfall1a") == "pwfall1c")
check("re-draw never leaves the file", Plan.airClip(180, false, all, "pwfall2c"):sub(1, 7) == "pwfall2")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
