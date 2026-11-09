-- Scenario tests: the real main.lua and backend against mock OpenMW modules.
--   python3 tools/sim/run_lua.py tools/sim/test_fsm.lua .
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
local function count(t, v) local n = 0; for _, x in ipairs(t) do if x == v then n = n + 1 end end; return n end
local function settle()
    M.pressed = {}
    for _ = 1, 600 do
        M.step()
        if M.state() == "Idle" and M.grounded() then break end
    end
    M.run(0.3)
end

-------------------------------------------------------------------------------
print("[1] sensors are demand-gated")
M.reset(v3(0, 0, 0), 0)
M.box("crate", -60, 60, 0, 60, 120, 50)
M.run(0.2)
M.rays, M.navQueries = 0, 0
M.run(1.0)
check("idle, no input: FLOW casts no rays", M.rays == 0, M.rays)
M.pressed.MoveForward = true
M.rays = 0
M.run(1.0)
check("walking forward: only the throttled ladder probe (~10/s)", M.rays > 0 and M.rays <= 11, M.rays)
M.pressed = {}

-------------------------------------------------------------------------------
print("[2] vault from the ground")
M.reset(v3(0, 0, 0), 0)
M.box("crate", -60, 60, 0, 60, 100, 50)   -- 50 units = 39% of 128
M.run(0.2)
M.events = {}
M.pressed.Jump = true
M.step()
check("jump held at a crate -> Vault", M.state() == "Vault", M.state())
check("vault holds movement + combat overrides", M.override.movement and M.override.combat)
M.pressed = {}
M.run(1.2)
check("vault lands past the crate", M.player.position.y > 100, M.player.position)
M.run(0.6)
check("back to Idle, overrides released", M.state() == "Idle" and not M.override.movement, M.state())
check("vault start sent once", count(M.events, "FLOW_Vault_Start") == 1)

-------------------------------------------------------------------------------
print("[3] refused vault changes nothing")
M.reset(v3(0, 0, 0), 0)
M.box("crate", -60, 60, 0, 60, 100, 50)
M.box("lintel", -200, 100, 70, 200, 300, 200)   -- no headroom past the crate
M.run(0.2)
M.events = {}
local writes = M.override.writes
M.pressed.Jump = true
M.step()
check("still Idle (refused in canEnter)", M.state() == "Idle", M.state())
check("no cancel or start event for a move that never started",
    count(M.events, "FLOW_Vault_Cancel") == 0 and count(M.events, "FLOW_Vault_Start") == 0, table.concat(M.events, ","))
check("override flag untouched", M.override.writes == writes)
M.pressed = {}

-------------------------------------------------------------------------------
print("[4] mantle from the ground")
M.reset(v3(0, 0, 0), 0)
M.box("wall", -100, 60, 0, 100, 200, 100)    -- 78% of height
M.run(0.2)
M.pressed.Jump = true
M.step()
check("jump held at a waist-to-head wall -> Mantle", M.state() == "Mantle", M.state())
M.pressed = {}
M.run(1.2)
check("mantle ends on top", M.player.position.z >= 99 and M.state() == "Idle", tostring(M.player.position) .. " " .. M.state())

-------------------------------------------------------------------------------
print("[5] ledge grab, held jump does not chain")
local function grab()
    M.reset(v3(0, 0, 60), 0)
    M.box("cliff", -300, 60, 0, 300, 400, 220)   -- above the mantle band
    M.player.vz = 250
    M.pitch = 0.4
    M.pressed.Jump = true
    for _ = 1, 30 do M.step(); if M.state() == "LedgeHang" then break end end
end
grab()
check("airborne + jump held + lip in reach -> LedgeHang", M.state() == "LedgeHang", M.state())
check("hang levitates once", M.effects.Levitate == 200, M.effects.Levitate)
M.run(0.6)
check("holding jump does not auto-mantle", M.state() == "LedgeHang", M.state())
M.pressed.MoveRight = true
M.step()
check("strafe with jump still held -> Shimmy, not WallBoost", M.state() == "Shimmy", M.state())
M.run(0.1)
check("held jump inside Shimmy does not launch", M.state() == "Shimmy", M.state())
check("Levitate still exactly once across the hand-off", M.effects.Levitate == 200, M.effects.Levitate)
local writes2 = M.override.writes
for _ = 1, 200 do M.step(); if M.state() == "LedgeHang" then break end end
check("step completes back into LedgeHang", M.state() == "LedgeHang", M.state())
check("no override churn between hang and shimmy", M.override.writes == writes2)
M.pressed = {}
M.run(0.35)   -- past the climb cooldown
M.pressed.Jump = true
M.step()
check("fresh press on the hang -> Mantle", M.state() == "Mantle", M.state())
check("Levitate released on leaving the hang", M.effects.Levitate == nil, M.effects.Levitate)
settle()

-------------------------------------------------------------------------------
print("[6] WallBoost from a hang")
grab()
M.pressed = {}
M.step()
M.pressed.MoveLeft = true; M.pressed.Jump = true
M.step()
check("strafe + jump PRESS on the hang -> WallBoost", M.state() == "WallBoost", M.state())
check("acrobatics +40 during boost", M.stats.acrobatics.modifier == 40, M.stats.acrobatics.modifier)
local z0 = M.player.position.z
M.pressed = {}
M.run(0.3)
check("boost rises", M.player.position.z > z0 + 60, M.player.position.z - z0)
M.run(0.4)
check("boost hands off to Airborne", M.state() == "Airborne" or M.state() == "Idle", M.state())
check("acrobatics bonus removed", M.stats.acrobatics.modifier == 0, M.stats.acrobatics.modifier)
settle()

print("[6b] WallBoost under a ceiling is cut short")
grab()
-- an overhang behind the climber, just above the crown of the hang
M.box("overhang", -300, -400, 240, 300, 55, 300)
M.pressed = {}
M.step()
M.pressed.MoveLeft = true; M.pressed.Jump = true
local maxZ = M.player.position.z
M.step()
local st = M.state()
for _ = 1, 40 do M.step(); maxZ = math.max(maxZ, M.player.position.z) end
check("boost never puts the crown through the overhang",
    maxZ + 128 * 0.95 <= 240 + 1, string.format("state=%s crown=%.1f", st, maxZ + 121.6))
M.pressed = {}
settle()

-------------------------------------------------------------------------------
print("[7] landing roll uses Acrobatics")
M.reset(v3(0, 0, 600), 0)
M.step()
check("falling -> Airborne", M.state() == "Airborne", M.state())
M.run(0.8)
M.pressed.MoveForward = true
M.step()
M.triggers.Jump()
check("tap with forward after 0.75s arms +50 Acrobatics", M.stats.acrobatics.modifier == 50, M.stats.acrobatics.modifier)
check("no Agility or Fortify writes", M.stats.agility.modifier == 0 and next(M.effects) == nil)
local landedAcro
for _ = 1, 300 do
    M.step()
    if M.state() == "Roll" then landedAcro = M.stats.acrobatics.modifier; break end
end
check("touchdown -> Roll with the bonus still on", landedAcro == 50, landedAcro)
M.run(0.3)
check("bonus dropped after the impact window", M.stats.acrobatics.modifier == 0, M.stats.acrobatics.modifier)
M.pressed = {}
M.run(1.0)
check("roll returns to Idle", M.state() == "Idle", M.state())

-------------------------------------------------------------------------------
print("[8] botched fall pose plays")
M.reset(v3(0, 0, 400), 0)
M.step()
M.SkillCheck.botch()
M.anim.played = {}
M.run(0.1)
check("pwfalling played while botched in the air", count(M.anim.played, "pwfalling") == 1, table.concat(M.anim.played, ","))
for _ = 1, 300 do M.step(); if M.state() ~= "Airborne" then break end end
check("botch lands as Stumble", M.state() == "Stumble", M.state())
M.run(1.2)
check("stumble releases to Idle", M.state() == "Idle" and not M.override.movement)

-------------------------------------------------------------------------------
print("[9] mantle fatigue: one charge, scaled")
M.reset(v3(0, 0, 0), 0)
M.box("wall", -100, 60, 0, 100, 200, 100)
M.stats.fatigue.current = 200
M.run(0.2)
M.pressed.Jump = true
M.step()
check("mantle charges 8 once (no encumbrance)", math.abs(200 - M.stats.fatigue.current - 8) < 0.01, 200 - M.stats.fatigue.current)
M.pressed = {}
settle()
M.reset(v3(0, 0, 0), 0)
M.box("wall", -100, 60, 0, 100, 200, 100)
M.setSetting('staminaScale', 0)
M.stats.fatigue.current = 3   -- would have failed the old fat > 10 gate
M.run(0.2)
M.pressed.Jump = true
M.step()
check("near-empty bar still mantles (no gate); Fatigue Cost 0 spends nothing",
    M.state() == "Mantle" and M.stats.fatigue.current == 3, M.state() .. " " .. M.stats.fatigue.current)
M.setSetting('staminaScale', nil)
M.stats.fatigue.current = 200
M.pressed = {}
settle()

-------------------------------------------------------------------------------
print("[10] ladder")
local function ladderWorld(top)
    M.reset(v3(0, 0, 0), 0)
    M.box("ex_ladder_01", -20, 40, 0, 20, 45, top)
    M.box("wall", -200, 45, 0, 200, 80, 900)   -- wall carries on past the ladder
end
ladderWorld(300)
M.run(0.2)
M.pressed.MoveForward = true
for _ = 1, 20 do M.step(); if M.state() == "Ladder" then break end end
check("walking into a ladder -> Ladder", M.state() == "Ladder", M.state())
M.run(6.0)
check("climb stops where the ladder ends, wall or not",
    M.state() == "Ladder" and M.player.position.z < 300, string.format("%s z=%.1f", M.state(), M.player.position.z))
local climbStarts = count(M.events, "FLOW_Climb_Start")
check("one climb event per direction change, not per frame", climbStarts <= 2, climbStarts)
M.pressed = {}; M.pressed.Sneak = true
M.step()
check("sneak drops off", M.state() == "Airborne", M.state())
M.pressed = {}
settle()

ladderWorld(600)
M.box("ceiling", -200, -200, 250, 200, 45, 300)
M.run(0.2)
M.pressed.MoveForward = true
for _ = 1, 20 do M.step(); if M.state() == "Ladder" then break end end
M.run(4.0)
check("climb stops under a ceiling", M.player.position.z + 128 <= 251, M.player.position.z + 128)
M.pressed = {}; M.pressed.Sneak = true
M.step(); M.pressed = {}
settle()

-------------------------------------------------------------------------------
print("[11] standing down releases holds")
grab()
M.setSetting('modEnabled', false)
M.step()
check("mod off mid-hang -> Idle, Levitate and overrides released",
    M.state() == "Idle" and M.effects.Levitate == nil and not M.override.movement)
M.setSetting('modEnabled', nil)
M.pressed = {}
settle()

-------------------------------------------------------------------------------
print("[12] real collision: what the boxes used to hide")
-- Measured in OpenMW 0.52 on real meshes (see mock.lua surfaceStartHits and
-- renderNormal); these refused every move on real geometry before v0.86.
check("the mock hits a surface a ray starts on (engine behaviour)", M.surfaceStartHits == true)
M.reset(v3(0, 0, 0), 0)
-- 115: inside the Mantle band and tall enough that the level camera ray
-- hits it, so the normal really comes from SharedRay.
M.box("wall", -100, 60, 0, 100, 200, 115)
M.renderNormal = v3(0.93, -0.36, 0.08)       -- a carved face, seen by SharedRay
M.run(0.2)
M.pressed.Jump = true
M.step()
check("a skewed SharedRay normal on a square wall still mantles", M.state() == "Mantle", M.state())
M.pressed = {}
M.run(1.2)
settle()
M.renderNormal = nil
-- Something SharedRay sees with no collision behind it (grass, a banner):
-- the physics confirmation finds nothing, so it is not a wall.
M.reset(v3(0, 0, 0), 0)
local realGet = M.I.SharedRay.getUnclipped
M.I.SharedRay.getUnclipped = function()
    return { hit = true, hitPos = M.player.position + v3(0, 50, 60), hitNormal = v3(0, -1, 0),
             hitObject = { recordId = "flora_banner" } }
end
M.pressed.Jump = true
M.step()
check("a render-only hit with no collision is not a wall", M.state() ~= "Mantle" and M.state() ~= "Vault", M.state())
M.I.SharedRay.getUnclipped = realGet
M.pressed = {}
settle()

-------------------------------------------------------------------------------
print("[13] the hang knows when it has lost its ledge")
grab()
check("hanging", M.state() == "LedgeHang", M.state())
M.pressed = {}
M.run(0.5)
-- A Recall scroll, a scripted move: the player is somewhere else entirely.
M.player.position = v3(2000, 2000, 500)
M.run(0.4)
check("teleported away mid-hang -> lets go (Airborne)", M.state() ~= "LedgeHang", M.state())
check("and the hang's Levitate is released", M.effects.Levitate == nil, M.effects.Levitate)
settle()
grab()
M.pressed = {}
M.run(0.5)
-- The ledge's object disabled under the player.
M.resetWorld()
M.run(0.4)
check("ledge removed under the hands -> lets go", M.state() ~= "LedgeHang", M.state())
settle()

print("[14] a climb press right after a shimmy step is not dropped")
grab()
M.pressed = {}
M.run(0.4)
M.pressed.MoveRight = true
for _ = 1, 120 do M.step(); if M.state() == "Shimmy" then break end end
M.pressed = {}
for _ = 1, 180 do M.step(); if M.state() == "LedgeHang" then break end end
check("step finished back on the hang", M.state() == "LedgeHang", M.state())
M.step()
M.pressed.Jump = true          -- within the old 0.3 s cooldown
M.step()
M.pressed = {}
check("jump pressed 2 frames after the step -> Mantle", M.state() == "Mantle", M.state())
M.run(1.5)
settle()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
