---@omw-context player
-- Underwater. A bridge state, like Airborne: FLOW holds nothing here and
-- plays nothing (the engine swims), but the state is NAMED, so other mods can
-- read it (I.Flow.getState() == "Underwater", I.Flow.getWater()) and FLOW's
-- own states stop treating a swim as a fall.
--
-- Before this a swimmer was "Airborne" (not on the ground), which in 0.86
-- measured as: Roll arming and firing under water, LedgeHang grabbing a lip
-- with the body still submerged, and every other mod reading the swim as a
-- fall.
--
-- The one action: at the surface, facing a climbable rock, Jump opens a very
-- brief WaterWalking window (core/surface.lua). The engine lifts the swimmer
-- onto the water, which ends the swim; Idle then takes the jump into the
-- ordinary Vault / Mantle ladder.
local BaseState = require('scripts/Flow/states/base_state')
local Surface = require('scripts/Flow/core/surface')
local SkillCheck = require('scripts/Flow/core/skill_check')

local UnderwaterState = BaseState.new("Underwater", {})

function UnderwaterState:enter()
    -- Nothing from the air survives into water: no botch to pay on the shore.
    SkillCheck.clearBotch()
end

function UnderwaterState:update(dt, syncData, inputData)
    if not Surface.inWater() then
        -- Standing on the water in the window counts as ground: Idle, which
        -- then sees the pending climb.
        if syncData.isGrounded then return "Idle" end
        return "Airborne"
    end

    if inputData.jumpPressed and Surface.atSurface() then
        Surface.tryOpen()
    end
    return nil
end

return UnderwaterState
