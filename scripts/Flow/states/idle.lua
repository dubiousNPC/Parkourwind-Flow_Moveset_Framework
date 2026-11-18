---@omw-context player
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')
local StateManager = require('scripts/Flow/core/state_manager')
local Surface = require('scripts/Flow/core/surface')
local LandingWatch = require('scripts/Flow/core/landing_watch')
local FallPlan = require('scripts/Flow/core/fall_plan')

local IdleState = BaseState.new("Idle", { sensors = { forward = true } })

-- Lowest first; each target's canEnter decides. No fatigue gate here: an empty
-- bar lowers the skill check, it never takes the move away (skill_check.lua).
local JUMP_RUNGS = { "Vault", "Mantle" }

-- Safety net: a botch that never reached a Stumble must not survive into
-- the next jump.
function IdleState:enter()
    SkillCheck.clearBotch()
end

function IdleState:update(dt, syncData, inputData)
    -- the engine knocked the player down for the fall just landed: play the
    -- stumble set over its knockdown. It is a failed landing; the check grades it.
    local impact = LandingWatch.knockdown()
    if impact then
        local margin, high = SkillCheck.fallCheck(impact, FallPlan.roll())
        return "Stumble", { kind = "falldown",
            landing = { outcome = FallPlan.outcome(math.min(margin, -1)), highSkill = high } }
    end
    if Surface.inWater() then return "Underwater" end
    if not syncData.isGrounded then
        return "Airborne"
    end

    -- A climb asked for from the water (Surface's window) counts as Jump held.
    local pending = Surface.climbPending()
    if (inputData.jump or pending) and StateManager.tryAny(JUMP_RUNGS) then
        if pending then Surface.consumeClimb() end
        return
    end
    -- Out of the water the lip is already known and was checked for a place
    -- to stand: Mantle onto it directly (its own checks still apply).
    if pending and Surface.lipPoint()
       and StateManager.setState("Mantle", { ledge = Surface.lipPoint() }) then
        Surface.consumeClimb()
        return
    end

    if inputData.moveVector.y > 0.1 then
        return "Ladder"
    end
end

return IdleState
