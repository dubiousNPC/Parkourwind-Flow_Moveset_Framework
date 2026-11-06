-- FLOW alongside mods that take hold of the player: WhyWalk (Core mounts,
-- Boats, Caravans) and Hookshot (pull, swing, hang). Each is emulated by what
-- it actually does to the player, read from its source:
--
--   WhyWalk Core   overrideMovementControls(true), Levitate +1, rider placed
--                  every frame; Space is the MOUNT's jump (whywalk_player)
--   WhyWalk Boats  overrideMovementControls(true), pilot placed every frame
--   Caravans       no lock at all; passenger placed on the deck every frame,
--                  which the engine never reports as on the ground
--   Hookshot hang  overrideMovementControls(true), Levitate +10, pinned to the
--                  wall; Jump RELEASES the hang (player.lua 'Jump' trigger)
--
-- and each calls I.Flow.yield/resume the way the shipped integration does.
--   python3 tools/sim/run_lua.py tools/sim/test_interop.lua .
MOD_ROOT = arg[1] or "."
local here = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local M = require("mock")
local v3 = M.v3

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or "")) end
end
local function has(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end

-- A mod taking the player, in the order the integration requires: yield
-- FIRST, so FLOW's stand-down writes the shared override flag before the
-- holder does, never after.
local function hold(owner, lev)
    if M.I.Flow then M.I.Flow.yield(owner) end
    M.I.Controls.overrideMovementControls(true)
    if lev then M.effects.Levitate = (M.effects.Levitate or 0) + lev end
end
local function release(owner, lev)
    M.I.Controls.overrideMovementControls(false)
    if lev then
        M.effects.Levitate = M.effects.Levitate - lev
        if M.effects.Levitate == 0 then M.effects.Levitate = nil end
    end
    if M.I.Flow then M.I.Flow.resume(owner) end
end

-- Step with the player placed at pin(t) every frame, as the holders do.
-- Records every state FLOW was in and every clip it started.
local function pinned(seconds, pin)
    local seen, t = {}, 0
    local firstClip = #M.anim.played + 1
    for _ = 1, math.floor(seconds * 60 + 0.5) do
        t = t + 1 / 60
        M.player.position = pin(t)
        M.player.vz = 0
        M.step()
        seen[M.state()] = true
    end
    local clips = {}
    for i = firstClip, #M.anim.played do clips[#clips + 1] = M.anim.played[i] end
    return seen, clips
end
local function only(seen, name)
    for k in pairs(seen) do if k ~= name then return false, k end end
    return true
end
local function settle()
    M.pressed = {}; M.notGrounded = false
    for _ = 1, 600 do
        M.step()
        if M.state() == "Idle" and M.grounded() then break end
    end
    M.run(0.3)
end

check("FLOW exposes I.Flow", M.I.Flow ~= nil and type(M.I.Flow.yield) == "function")
local BASELINE = M.I.Flow == nil   -- the build before I.Flow: run what applies

-------------------------------------------------------------------------------
print("[1] riding a mount: FLOW stands aside for the whole ride")
M.reset(v3(0, 0, 0), 0)
-- A rock face the mount gallops at: its top in a rider's grab range by the
-- time Space is pressed.
M.box("rock", -300, 500, 0, 300, 900, 260)
M.run(0.2)
hold("WhyWalk", 1)
local ride = function(t) return v3(0, 300 * t, 120) end
local seen, clips = pinned(1.0, ride)
check("mounted: FLOW stays Idle", only(seen, "Idle"))
-- Space while mounted: WhyWalk sends the mount's jump. FLOW sees the same key.
M.pressed.Jump = true; M.pressed.MoveForward = true; M.pitch = 0.4
if M.triggers.Jump then M.triggers.Jump() end
seen, clips = pinned(0.5, function(t) return ride(1 + t) end)
check("mount jump beside a ledge: no Vault/Mantle/LedgeHang", only(seen, "Idle"),
    (function() local s = {} for k in pairs(seen) do s[#s + 1] = k end return table.concat(s, ",") end)())
check("no FLOW clip over the riding pose", #clips == 0, table.concat(clips, ","))
check("the rider's control lock is still on", M.override.movement == true)
M.pressed = {}; M.pitch = 0
release("WhyWalk", 1)
local acro = M.stats.acrobatics.modifier
settle()
check("dismounted: no landing Roll armed during the ride", not has(M.anim.played, "pwroll1"))
check("acrobatics untouched", M.stats.acrobatics.modifier == 0 and acro == 0, M.stats.acrobatics.modifier)
check("FLOW active again afterwards", BASELINE or not M.I.Flow.isYielded())

-------------------------------------------------------------------------------
print("[2] a mount leaping off a cliff")
M.reset(v3(0, 0, 0), 0)
M.box("plateau", -200, -200, 3900, 200, 200, 4000)
M.player.position = v3(0, 0, 4000)
M.run(0.2)
hold("WhyWalk", 1)
M.anim.played = {}
-- Free fall with the mount, 4000 units of air below.
local G = 627.2
seen, clips = pinned(2.2, function(t) return v3(0, 400 + 300 * t, 4000 - 0.5 * G * t * t) end)
check("no Skydive on a falling mount", not has(clips, "skydive1"), table.concat(clips, ","))
check("no Skydive buffs on the rider", M.stats.acrobatics.modifier == 0 and M.effects.Jump == nil)
seen, clips = pinned(0.3, function() return v3(0, 1060, 120) end)
check("mount lands: no knockdown Stumble", only(seen, "Idle") and not has(clips, "pwfalling"))
release("WhyWalk", 1)
settle()

-------------------------------------------------------------------------------
print("[3] the override flag across a hand-over")
-- FLOW holds the flag (Vault) when a mod takes the player; it must end held
-- by the mod, and stay released after the mod lets go.
M.reset(v3(0, 0, 0), 0)
M.box("crate", -60, 60, 0, 60, 100, 50)
M.run(0.2)
M.pressed.Jump = true
M.step()
M.pressed = {}
check("FLOW mid-Vault holding the flag", M.state() == "Vault" and M.override.movement)
hold("Hookshot", 10)
M.step()
check("taken mid-move: FLOW stood down to Idle", M.state() == "Idle", M.state())
check("the mod's override survives FLOW's stand-down", M.override.movement == true)
check("FLOW's own hold released (only the mod's Levitate 10 left)", M.effects.Levitate == 10, M.effects.Levitate)
M.run(1.0)
release("Hookshot", 10)
M.run(0.5)
check("after release, nothing re-asserts the flag", M.override.movement == false)
settle()

-------------------------------------------------------------------------------
print("[4] Hookshot hang: the Jump that releases it is not a FLOW grab")
M.reset(v3(0, 0, 0), 0)
M.box("cliff", -300, 60, 0, 300, 400, 260)
M.run(0.2)
hold("Hookshot", 10)
local wall = function() return v3(0, 30, 90) end   -- hanging on the face, lip in reach
pinned(0.5, wall)
-- Space: Hookshot's Jump trigger drops the hang. The key is still down when
-- the hold ends, and FLOW resumes with the player under a lip, jump held.
M.pressed.Jump = true; M.pitch = 0.4
if M.triggers.Jump then M.triggers.Jump() end
pinned(1 / 60, wall)
release("Hookshot", 10)
local grabbed = false
for _ = 1, 3 do M.step(); if M.state() ~= "Idle" and M.state() ~= "Airborne" then grabbed = M.state() end end
check("the releasing Jump does not chain into a grab", not grabbed, grabbed)
-- Still under the lip and falling: let go of Space, press it again.
M.pressed.Jump = nil; M.step()
M.pressed.Jump = true
local fresh = false
for _ = 1, 10 do M.step(); if M.state() == "LedgeHang" or M.state() == "Mantle" then fresh = M.state() end end
check("a fresh press after release does reach the ladder", fresh, M.state())
M.pressed = {}; M.pitch = 0
settle()

-------------------------------------------------------------------------------
print("[5] caravan passenger: placed on the deck, never grounded, no lock")
M.reset(v3(0, 0, 0), 0)
M.box("deck", -150, -150, 1100, 150, 150, 1223)
M.box("howdah", -150, 80, 1223, 150, 150, 1400)   -- the shell's wall, in reach
M.run(0.1)
M.notGrounded = true
if M.I.Flow then M.I.Flow.yield("WhyWalk.Caravans") end
M.pressed.Jump = true; M.pressed.MoveForward = true
if M.triggers.Jump then M.triggers.Jump() end
seen, clips = pinned(2.0, function() return v3(0, 0, 1226) end)
check("passenger pressing Jump at the shell: FLOW stays Idle", only(seen, "Idle"))
M.pressed = {}
if M.I.Flow then M.I.Flow.resume("WhyWalk.Caravans") end
M.notGrounded = false
M.player.position = v3(0, -400, 0)
settle()

-------------------------------------------------------------------------------
print("[6] yields are per owner")
local F = M.I.Flow
if F then
F.yield("A"); F.yield("B"); F.yield("A")
F.resume("A")
check("one owner of two resumes: still yielded", F.isYielded())
F.resume("nobody")
check("an owner that never yielded changes nothing", F.isYielded())
F.resume("B")
check("last owner resumes: active", not F.isYielded())
F.yield("C")
M.setSetting('modEnabled', false); M.step()
M.setSetting('modEnabled', nil); M.step()
check("toggling the mod does not drop a yield", F.isYielded())
F.resume("C")
-- The event route, for a global script or a mod that will not take a
-- dependency on the interface.
M.main.eventHandlers.Flow_Yield({ owner = "G", yield = true })
check("Flow_Yield event yields", F.isYielded())
M.main.eventHandlers.Flow_Yield({ owner = "G", yield = false })
check("Flow_Yield event resumes", not F.isYielded())
check("a yield with no owner is refused", not pcall(F.yield, nil) and not F.isYielded())
else check("I.Flow present", false) end

-------------------------------------------------------------------------------
print("[7] held aloft without falling (a mod that does not yield, or a Levitate spell)")
M.reset(v3(0, 0, 0), 0)
M.run(0.2)
M.anim.played = {}
M.effects.Levitate = 5
seen, clips = pinned(3.0, function() return v3(0, 0, 2400) end)
check("hovering with 2400 units of air below: no Skydive", not has(clips, "skydive1"), table.concat(clips, ","))
M.effects.Levitate = nil
M.player.vz = 0
local dove = false
for _ = 1, 150 do M.step(); if has(M.anim.played, "skydive1") then dove = true; break end end
check("the fall that follows still skydives", dove)
settle()

-------------------------------------------------------------------------------
print("[8] an ordinary long fall: the whole Skydive, unchanged")
-- 9000 units: 5.4 s of fall, room for the 1.2 s arm and the default 3 s
-- windup (settings skydiveWindup) before the ground.
M.reset(v3(0, 0, 0), 0)
M.box("tower", -100, -100, 8900, 100, 100, 9000)
M.player.position = v3(0, 0, 9000)
M.run(0.2)
M.anim.played = {}
M.player.position = v3(0, 160, 9000); M.player.vz = 0
local armedAt, releasedAt, buffed
local states = {}
for i = 1, 600 do
    M.step()
    if not armedAt and has(M.anim.played, "skydive1") then armedAt = i / 60 end
    if not releasedAt and has(M.anim.played, "skydive") then
        releasedAt = i / 60
        buffed = M.stats.acrobatics.modifier == 250 and M.effects.Jump == 150
    end
    states[#states + 1] = M.state()
    if M.grounded() and M.state() == "Idle" and armedAt then break end
end
check("off a tower: Skydive arms near 1.2 s", armedAt and armedAt >= 1.2 and armedAt < 1.5, armedAt)
check("released after the windup", releasedAt and armedAt and releasedAt - armedAt >= 2.9, releasedAt)
check("released: Acrobatics +250 and Jump +150", buffed)
-- Knockdown picks pwfalling or dbsfall at random (playerAnim pickAvailable);
-- what tells it from a botch stumble is the 1.5 s hold against 1.0.
local held = 0
for _, st in ipairs(states) do if st == "Stumble" then held = held + 1 end end
check("lands as the knockdown Stumble (held 1.5 s)", held >= 88 and held <= 92, held / 60)
check("buffs gone after the landing", M.stats.acrobatics.modifier == 0 and M.effects.Jump == nil,
    M.stats.acrobatics.modifier)
settle()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
