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
local MOVES = {
    Vault     = { difficulty = 8,  fatigue = 3 },
    Mantle    = { difficulty = 18, fatigue = 6 },
    Shimmy    = { difficulty = 15, fatigue = 2 },
    WallBoost = { difficulty = 35, fatigue = 8 },
    WallJump  = { difficulty = 45, fatigue = 10 },
    Dive      = { difficulty = 30, fatigue = 6 },
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

function SkillCheck.fatigueCost(moveName)
    local move = MOVES[moveName]
    if not move then return 0 end
    return move.fatigue * Settings.staminaScale()
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

function SkillCheck.debugString(moveName)
    return string.format("%s %.0f/%.0f%s", moveName, SkillCheck.chance(),
        SkillCheck.difficulty(moveName), botched and " BOTCH" or "")
end

return SkillCheck
