---@omw-context player
-- Skill check and fatigue cost. A failed check never blocks a move; it botches
-- it, and the stumble lands on the player instead. See README.
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Settings = require('scripts/Flow/settings')

local SkillCheck = {}

local BASE = 30.0
local SKILL_WEIGHT = 0.55
local AGILITY_WEIGHT = 0.35

local FATIGUE_TERM_BASE = 1.25
local FATIGUE_TERM_SPAN = 0.50

-- Never checked and never charged: these are traversal, not feats.
local EXEMPT = { LedgeHang = true, Roll = true, Ladder = true, Skydive = true }

-- Difficulty is what `chance` must beat; the threshold setting scales it.
-- Mantle's 8 (8-16 with load) is a deliberate CUT, not a carry-over. v0.83
-- charged 6 here plus a private 20 x (1 + load) in mantle.lua: 26 unloaded,
-- 46 at full load. Reproducing that under the single model would be ~23.
-- 8 keeps chained mantles out of WallBoost's botch band.
local MOVES = {
    Vault     = { difficulty = 8,  fatigue = 3 },
    Mantle    = { difficulty = 18, fatigue = 8 },
    Shimmy    = { difficulty = 15, fatigue = 2 },
    WallBoost = { difficulty = 35, fatigue = 8 },
}

local function fatigueRatio()
    local f = types.Actor.stats.dynamic.fatigue(mwSelf)
    local maximum = f.base + f.modifier
    if maximum <= 0 then return 0 end
    return math.max(0.0, math.min(1.0, f.current / maximum))
end

function SkillCheck.chance()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local agi = types.Actor.stats.attributes.agility(mwSelf).modified or 50
    local raw = BASE + SKILL_WEIGHT * acro + AGILITY_WEIGHT * (agi - 50)
    local term = FATIGUE_TERM_BASE - FATIGUE_TERM_SPAN * (1.0 - fatigueRatio())
    return math.max(0.0, raw * term)
end

function SkillCheck.difficulty(moveName)
    local move = MOVES[moveName]
    if not move then return 0 end
    return move.difficulty * Settings.skillDifficulty()
end

-- Load makes every move dearer: a full pack doubles the cost.
local function encumbranceFactor()
    local cap = types.Actor.getCapacity(mwSelf)
    if cap <= 0 then return 1.0 end
    return 1.0 + math.min(1.0, types.Actor.getEncumbrance(mwSelf) / cap)
end

function SkillCheck.fatigueCost(moveName)
    local move = MOVES[moveName]
    if not move then return 0 end
    return move.fatigue * encumbranceFactor() * Settings.staminaScale()
end

-- Exhaustion is already in the formula, through the fatigue term. There is no
-- separate affordability gate: an empty bar lowers the chance, it does not take
-- the move away.
function SkillCheck.spend(moveName)
    if EXEMPT[moveName] then return end
    local cost = SkillCheck.fatigueCost(moveName)
    if cost <= 0 then return end
    local f = types.Actor.stats.dynamic.fatigue(mwSelf)
    f.current = math.max(0, f.current - cost)
end

-- "ok" or "botched". Never a refusal: the move always happens.
function SkillCheck.evaluate(moveName)
    if EXEMPT[moveName] then return "ok" end
    if not Settings.skillChecks() then return "ok" end
    if SkillCheck.chance() >= SkillCheck.difficulty(moveName) then return "ok" end
    return "botched"
end

local botched = false

-- Set by a state that failed its check; read by Airborne, which shows the
-- falling pose and lands the player in a Stumble.
function SkillCheck.botch()
    botched = true
end

function SkillCheck.botched()
    return botched
end

function SkillCheck.clearBotch()
    botched = false
end

-- One call for a state's entry: charge, check, and flag the botch.
function SkillCheck.attempt(moveName)
    SkillCheck.spend(moveName)
    if SkillCheck.evaluate(moveName) == "ok" then return true end
    SkillCheck.botch()
    return false
end

-- ============================================================================
-- Landing check (falls). Same skill/agility base as the moves, plus LUCK, all
-- scaled by the remaining FATIGUE percentage, against a difficulty that grows
-- with the impact speed. The caller adds the landing's roll (FallPlan.roll):
-- this file stays deterministic, as the move checks require. Returns the
-- margin (chance - difficulty + roll) and whether the player is in the high
-- skill tier that owns the acrobatic set. core/fall_plan.lua bands the margin.
-- ============================================================================
local LUCK_WEIGHT = 0.25            -- per point of Luck off 50 (Agility is 0.35)
local FALL_BASE_DIFFICULTY = 20     -- at or below FALL_EASY_SPEED
local FALL_EASY_SPEED = 600         -- u/s down at touchdown
local FALL_DIFFICULTY_PER_SPEED = 0.035   -- +35 per 1000 u/s above that
-- ...up to here. A released skydive always lands at the engine's ~3000 u/s
-- (measured 2958-2996), so without a cap every skydive landing would be the
-- hardest check there is; past this, faster is not harder.
local FALL_MAX_SPEED = 2000
SkillCheck.HIGH_SKILL = 60          -- Acrobatics (modified) for the acrobatic set

function SkillCheck.fallChance()
    local acro = types.NPC.stats.skills.acrobatics(mwSelf).modified or 0
    local agi = types.Actor.stats.attributes.agility(mwSelf).modified or 50
    local luck = types.Actor.stats.attributes.luck(mwSelf).modified or 50
    local raw = BASE + SKILL_WEIGHT * acro + AGILITY_WEIGHT * (agi - 50) + LUCK_WEIGHT * (luck - 50)
    local term = FATIGUE_TERM_BASE - FATIGUE_TERM_SPAN * (1.0 - fatigueRatio())
    return math.max(0.0, raw * term), acro
end

function SkillCheck.fallDifficulty(impactSpeed)
    local v = math.min(impactSpeed or 0, FALL_MAX_SPEED)
    local extra = math.max(0, v - FALL_EASY_SPEED) * FALL_DIFFICULTY_PER_SPEED
    return (FALL_BASE_DIFFICULTY + extra) * Settings.skillDifficulty()
end

-- With skill checks turned off the landing always succeeds by a clean margin.
function SkillCheck.fallCheck(impactSpeed, roll)
    local chance, acro = SkillCheck.fallChance()
    local high = acro >= SkillCheck.HIGH_SKILL
    if not Settings.skillChecks() then return 100, high, chance, 0 end
    roll = roll or 0
    local difficulty = SkillCheck.fallDifficulty(impactSpeed)
    return chance - difficulty + roll, high, chance, difficulty
end

function SkillCheck.debugString(moveName)
    return string.format("%s %.0f/%.0f%s", moveName, SkillCheck.chance(),
        SkillCheck.difficulty(moveName), botched and " BOTCH" or "")
end

return SkillCheck
