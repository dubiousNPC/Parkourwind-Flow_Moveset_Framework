---@omw-context player
-- FLOW's animation priorities, as explicit per-bone-group tables.
--
-- Never a bare PRIORITY enum: it is uniform across all four bone groups, and
-- Animation::play ERASES every other state whose priority is equal on all
-- four. The engine plays uniform tuples constantly (shield = Block, torch =
-- Torch, hit = Hit), so a uniform priority here is deleted, not outranked.
-- Only states whose blend mask contains a bone group compete for it, so the
-- tuples below change nothing about arbitration. Derivation: RESEARCH.md §1.29.
local animation = require('openmw.animation')

local BG = animation.BONE_GROUP
local P = animation.PRIORITY

return {
    -- Default for one-shot moves.
    FLOW = {
        [BG.LowerBody] = P.Weapon,
        [BG.Torso] = P.Weapon,
        [BG.LeftArm] = P.Weapon,
        [BG.RightArm] = P.Block,
    },

    -- Over everything, including the engine's own knockdown. Uniform is safe
    -- only here: the engine never plays at uniform Scripted (only mwscript
    -- PlayGroup and other mods do). Used by Stumble's "knockdown" alone.
    FLOW_SCRIPTED = {
        [BG.LowerBody] = P.Scripted,
        [BG.Torso] = P.Scripted,
        [BG.LeftArm] = P.Scripted,
        [BG.RightArm] = P.Scripted,
    },

    -- Committed poses (hang, ladder, roll...). Not uniform Block: that is the
    -- tuple "shield" plays at, so raising a shield deleted these poses.
    -- LowerBody is Torch, NOT Weapon: upperBodyReady() is false while any
    -- state holds Weapon, and the camera then QUEUES a POV switch - so a
    -- looping hang or ladder pose would have blocked first/third person.
    FLOW_MAJOR = {
        [BG.LowerBody] = P.Torch,
        [BG.Torso] = P.Block,
        [BG.LeftArm] = P.Block,
        [BG.RightArm] = P.Block,
    },
}
