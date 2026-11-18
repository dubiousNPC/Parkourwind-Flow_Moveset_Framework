---@omw-context player
-- Fall-damage knockdowns. The engine decides them on landing (character.cpp:
-- fall damage > Acrobatics x fatigue term sets KnockedDown) and plays its own
-- "knockdown". FLOW cannot set or read that flag, but canMove() turns false
-- with it. So Airborne arms this on an ORDINARY landing (a skydive or a botch
-- already lands in Stumble), and Idle asks it for a short while afterwards:
-- a knockdown inside the window is the fall's, and FLOW plays its stumble set
-- over the engine's clip (Stumble "falldown", Scripted priority).
local core = require('openmw.core')
local types = require('openmw.types')
local mwSelf = require('openmw.self')

local Watch = {}

Watch.WINDOW = 0.5      -- seconds after touchdown; the engine sets it on the landing frame

-- The engine deals no fall damage below this height (fFallDamageDistanceMin,
-- 400 in Morrowind.esm), so no landing below it can be a fall knockdown.
local MIN_HEIGHT = core.getGMST("fFallDamageDistanceMin") or 400

local armedAt, impact = nil, 0

-- `fallHeight`: the drop from the fall's highest point to the landing.
function Watch.arm(impactSpeed, fallHeight)
    if (fallHeight or 0) < MIN_HEIGHT then armedAt = nil; return end
    armedAt = core.getSimulationTime()
    impact = impactSpeed or 0
end

-- canMove() is "max speed > 0": also false when over-encumbered or paralysed.
-- Neither is a fall's knockdown, and an over-encumbered player would otherwise
-- "fall down" on every landing.
local function otherReason()
    local cap = types.Actor.getCapacity(mwSelf)
    if cap > 0 and types.Actor.getEncumbrance(mwSelf) > cap then return true end
    local para = types.Actor.activeEffects(mwSelf):getEffect(core.magic.EFFECT_TYPE.Paralyze)
    return para ~= nil and (para.magnitude or 0) > 0
end

function Watch.clear() armedAt = nil end

-- The landing's impact speed when the engine has knocked the player down
-- within the window, else nil. Free when not armed.
function Watch.knockdown()
    if not armedAt then return nil end
    if core.getSimulationTime() - armedAt > Watch.WINDOW then armedAt = nil; return nil end
    if types.Actor.isDead(mwSelf) then armedAt = nil; return nil end
    if types.Actor.canMove(mwSelf) then return nil end
    armedAt = nil
    if otherReason() then return nil end
    return impact
end

return Watch
