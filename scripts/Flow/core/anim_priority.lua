---@omw-context player
-- FLOW's animation priorities, as explicit per-bone-group tables.
--
-- A bare PRIORITY enum is uniform across all four bone groups, and
-- Animation::play erases every other state whose AnimPriority compares equal on
-- all four (mwrender/animation.cpp:905-911; operator== in animationpriority.hpp
-- :19-25). The engine builds uniform tuples constantly - "shield" is uniform
-- Block, "torch" uniform Torch, a hit uniform Hit - so a uniform priority here
-- is deleted by ordinary play, not merely outranked.
--
-- Neither tuple below changes arbitration. Only states whose blend mask
-- CONTAINS a bone group compete for it (animation.cpp:1138), and among those the
-- engine never sits at Weapon or Block on LowerBody, nor at Block on RightArm:
-- "shield" and "torch" are LeftArm-masked, so they count for the sweep and never
-- for arbitration. See RESEARCH.md §1.29.
local animation = require('openmw.animation')

local BG = animation.BONE_GROUP
local P = animation.PRIORITY

return {
    -- was: uniform PRIORITY.Weapon
    FLOW = {
        [BG.LowerBody] = P.Weapon,
        [BG.Torso] = P.Weapon,
        [BG.LeftArm] = P.Weapon,
        [BG.RightArm] = P.Block,
    },

    -- was: uniform PRIORITY.Block, which is exactly the tuple the engine plays
    -- "shield" with (character.cpp:1398), so raising a shield deleted these poses.
    --
    -- LowerBody is Torch and NOT Weapon, deliberately. Animation::upperBodyReady()
    -- is false while any active state contains Hit, Weapon, Knockdown or Death in
    -- ANY bone group (animation.cpp:1838-1848), and camera.cpp:226 uses that to
    -- QUEUE a first/third-person switch instead of applying it. Uniform Block
    -- contains none of those, so introducing Weapon here would have made a POV
    -- switch silently do nothing until a looping LedgeHang or Ladder pose ended.
    -- Torch keeps upperBodyReady() exactly as it was.
    FLOW_MAJOR = {
        [BG.LowerBody] = P.Torch,
        [BG.Torso] = P.Block,
        [BG.LeftArm] = P.Block,
        [BG.RightArm] = P.Block,
    },
}
