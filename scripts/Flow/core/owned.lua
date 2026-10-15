---@omw-context player
-- Engine-side changes FLOW currently holds. Saved so onLoad can undo them.
local types = require('openmw.types')
local mwSelf = require('openmw.self')

local Owned = {}

local held = { effects = {}, attributes = {}, skills = {} }

local function bump(t, key, amount)
    local v = (t[key] or 0) + amount
    t[key] = (v ~= 0) and v or nil
end

local function applyEffect(key, amount)
    local id, arg = key:match('^([^|]+)|?(.*)$')
    types.Actor.activeEffects(mwSelf):modify(amount, id, arg ~= '' and arg or nil)
end

local function applyAttribute(id, amount)
    local stat = types.Actor.stats.attributes[id](mwSelf)
    stat.modifier = stat.modifier + amount
end

local function applySkill(id, amount)
    local stat = types.NPC.stats.skills[id](mwSelf)
    stat.modifier = stat.modifier + amount
end

function Owned.effect(effectId, amount, arg)
    local key = arg and (effectId .. '|' .. arg) or effectId
    applyEffect(key, amount)
    bump(held.effects, key, amount)
end

function Owned.attribute(id, amount)
    applyAttribute(id, amount)
    bump(held.attributes, id, amount)
end

function Owned.skill(id, amount)
    applySkill(id, amount)
    bump(held.skills, id, amount)
end

function Owned.save()
    return held
end

function Owned.undo(saved)
    if type(saved) ~= 'table' then return end
    for key, amount in pairs(saved.effects or {}) do applyEffect(key, -amount) end
    for id, amount in pairs(saved.attributes or {}) do applyAttribute(id, -amount) end
    for id, amount in pairs(saved.skills or {}) do applySkill(id, -amount) end
    held = { effects = {}, attributes = {}, skills = {} }
end

return Owned
