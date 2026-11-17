-- Underwater: the bridge state, and the surfacing window that lets a swimmer
-- climb out onto a rock. Real main.lua, states and backend; mock water.
--   python3 tools/sim/run_lua.py tools/sim/test_underwater.lua .
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
local function trace(sec, stop)
    local seq, last = {}, nil
    for _ = 1, math.floor(sec * 60) do
        M.step()
        local s = M.state()
        if s ~= last then seq[#seq + 1] = s; last = s end
        if stop and stop(s) then break end
    end
    return table.concat(seq, ">")
end
local function has(seq, s) return seq:find(s, 1, true) ~= nil end
local I = require('openmw.interfaces')

-- Sea at z 0, seabed far below; a rock whose top is `lip` above the water,
-- its face `d` ahead of a swimmer facing +y.
local function sea(lip, d)
    M.reset(v3(0, 0, -125), 0)
    M.boxes = {}
    M.box("seabed", -5000, -5000, -1100, 5000, 5000, -1000)
    M.water = 0
    if lip then M.box("rock", -300, d or 70, -1000, 300, 600, lip) end
    M.run(0.3)
end

-------------------------------------------------------------------------------
print("[1] swimming is Underwater, not Airborne")
sea(nil)
check("floating swimmer -> Underwater", M.state() == "Underwater", M.state())
local w = I.Flow.getWater()
check("I.Flow.getWater: swimming, at the surface, depth ~125", w.swimming and w.atSurface and math.abs(w.depth - 125) < 5,
    string.format("swim=%s surf=%s depth=%s", tostring(w.swimming), tostring(w.atSurface), tostring(w.depth)))
check("I.Flow version 2", I.Flow.version == 2, I.Flow.version)

print("[2] no Roll and no skydive in the water")
sea(nil)
M.pressed = { MoveForward = true }
M.run(1.0)
M.pressed = { MoveForward = true, Jump = true }
if M.triggers.Jump then M.triggers.Jump() end
local s = trace(1.0)
M.pressed = {}
check("W + Jump while swimming: never Roll", not has(s, "Roll"), s)

print("[3] Jump at a rock: brief water walk, then the ordinary climb")
sea(40, 70)
M.pressed = { MoveForward = true, Jump = true }
s = trace(2.5, function(st) return st == "Idle" and M.player and false end)
M.pressed = {}
M.run(1.0)
check("lip 40: Underwater > Idle > Vault/Mantle", has(s, "Idle") and (has(s, "Vault") or has(s, "Mantle")), s)
check("ends on the rock", M.SM and require('openmw.self').position.z > 35, string.format("%.0f", require('openmw.self').position.z))
check("water walking given back", (M.effects.WaterWalking or 0) == 0, M.effects.WaterWalking)

print("[3b] a lip under Vault's minimum: walk onto it, or drop back in")
local Surface = require('scripts/Flow/core/surface')
sea(15, 70)
M.pressed = { Jump = true }
M.step()
M.pressed = { MoveForward = true }
check("lip 15: window open, nothing for the ladder to take", Surface.isOpen() and not Surface.climbPending())
M.run(Surface.WINDOW + 0.1)
check("lip 15, walking at it: still open past the short window", (M.effects.WaterWalking or 0) == 1, M.effects.WaterWalking)
M.run(Surface.WINDOW_MAX)
M.pressed = {}
check("lip 15: closed by the cap", (M.effects.WaterWalking or 0) == 0, M.effects.WaterWalking)
sea(15, 70)
M.pressed = { Jump = true }
M.step()
M.pressed = {}
M.run(Surface.STAND_GRACE + 0.8)
check("lip 15, not walking: dropped back in after the grace, not left standing", (M.effects.WaterWalking or 0) == 0
    and M.state() == "Underwater", M.state())

print("[3c] a lip the climb would refuse is refused before the lift")
sea(60, 70)
M.box("roof", -300, 60, 100, 300, 600, 400)        -- 40 over the lip: no room on top
M.pressed = { MoveForward = true, Jump = true }
local why0 = select(2, Surface.lipAhead())
s = trace(1.5)
M.pressed = {}
check("roofed 60 lip: no water walking, no lift", (M.effects.WaterWalking or 0) == 0 and s == "Underwater", s)
check("...and it says why", why0 == "ceiling over the lip", why0)
sea(60, 70)
M.box("overhang", -300, -100, 90, 300, 69, 110)    -- a ceiling over the swimmer
M.pressed = { Jump = true }
M.step()
M.pressed = {}
check("no headroom over the water: refused", (M.effects.WaterWalking or 0) == 0, select(2, Surface.lipAhead()))

print("[4] a tap is enough: the jump is held over into the window")
sea(40, 70)
M.pressed = { MoveForward = true, Jump = true }
M.step(); M.step()
M.pressed = { MoveForward = true }
s = trace(2.5)
M.pressed = {}
M.run(1.0)
check("tap Jump at the rock -> climbs", has(s, "Vault") or has(s, "Mantle"), s)

print("[5] nothing to climb: nothing happens")
sea(nil)
M.pressed = { Jump = true }
s = trace(1.0)
M.pressed = {}
check("open water + Jump: stays Underwater, no water walking", s == "Underwater" and (M.effects.WaterWalking or 0) == 0, s)
sea(400, 70)
M.pressed = { MoveForward = true, Jump = true }
s = trace(1.5)
M.pressed = {}
check("a cliff 400 above the water: refused, still swimming", not has(s, "Vault") and not has(s, "Mantle")
    and (M.effects.WaterWalking or 0) == 0, s)

print("[6] the window closes by itself")
local Surface = require('scripts/Flow/core/surface')
sea(40, 70)
M.pressed = { Jump = true }
M.step()
check("Jump at the rock opens the window", Surface.isOpen() and (M.effects.WaterWalking or 0) == 1, M.effects.WaterWalking)
-- the rock goes away before the climb can start: nothing left to climb
M.boxes = {}
M.box("seabed", -5000, -5000, -1100, 5000, 5000, -1000)
M.pressed = {}
s = trace(Surface.WINDOW + 0.5)
check("after the window: water walking removed", (M.effects.WaterWalking or 0) == 0 and not Surface.isOpen(), M.effects.WaterWalking)
check("...and back to swimming", M.state() == "Underwater", s)

print("[7] yielding to another mod closes it at once")
sea(40, 70)
M.pressed = { Jump = true }
M.step()
I.Flow.yield("test")
M.step()
check("yield: water walking removed", (M.effects.WaterWalking or 0) == 0, M.effects.WaterWalking)
I.Flow.resume("test")
M.pressed = {}
M.run(0.2)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
