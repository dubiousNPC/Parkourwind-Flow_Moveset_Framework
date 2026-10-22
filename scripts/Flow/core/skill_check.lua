---@omw-context player
-- Skill check and fatigue cost for every move. One formula, one cost table.
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Settings = require('scripts/Flow/settings')

local SkillCheck = {}

-- Formula and per-move numbers: see README.
local BASE = 30.0
local SKILL_WEIGHT = 0.55
local AGILITY_WEIGHT = 0.35

local FATIGUE_TERM_BASE = 1.25
local FATIGUE_TERM_SPAN = 0.50

-- Difficulty is what `chance` must beat; the threshold setting scales it.
local MOVES = {
    Vault     = { difficulty = 10, fatigue = 4 },
    Mantle    = { difficulty = 25, fatigue = 8 },
    LedgeHang = { difficulty = 30, fatigue = 6 },
    Shimmy    = { difficulty = 20, fatigue = 2 },
    Ladder    = { difficulty = 0,  fatigue = 2 },
    Roll      = { difficulty = 20, fatigue = 5 },
    WallBoost = { difficulty = 45, fatigue = 12 },
    WallJump  = { difficulty = 55, fatigue = 14 },
    Dive      = { difficulty = 40, fatigue = 10 },
    Skydive   = { difficulty = 35, fatigue = 0 },
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

-- Deterministic on purpose: no dice roll. See README.
function SkillCheck.passes(moveName)
    if not Settings.skillChecks() then return true end
    return SkillCheck.chance() >= SkillCheck.difficulty(moveName)
end

function SkillCheck.affordable(moveName)
    local cost = SkillCheck.fatigueCost(moveName)
    if cost <= 0 then return true end
    return types.Actor.stats.dynamic.fatigue(mwSelf).current >= cost
end

function SkillCheck.spend(moveName)
    local cost = SkillCheck.fatigueCost(moveName)
    if cost <= 0 then return end
    local f = types.Actor.stats.dynamic.fatigue(mwSelf)
    f.current = math.max(0, f.current - cost)
end

-- Entry gate: "ok" / "degraded" / "refused". Vault and Mantle never refuse.
local DEGRADES = { Vault = true, Mantle = true }

function SkillCheck.evaluate(moveName)
    if not SkillCheck.affordable(moveName) then
        return DEGRADES[moveName] and "degraded" or "refused"
    end
    if SkillCheck.passes(moveName) then return "ok" end
    return DEGRADES[moveName] and "degraded" or "refused"
end

function SkillCheck.debugString(moveName)
    return string.format("%s chance=%.0f need=%.0f fat=%.0f",
        moveName, SkillCheck.chance(), SkillCheck.difficulty(moveName),
        SkillCheck.fatigueCost(moveName))
end

return SkillCheck
