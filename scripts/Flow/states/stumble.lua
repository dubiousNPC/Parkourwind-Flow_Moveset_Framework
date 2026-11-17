---@omw-context player
-- The landing you did not choose. Two presentations, one mechanism:
--   "stumble"   - dbsfall, after a botched manoeuvre
--   "knockdown" - after a skydive: a dive-roll, or a hard landing and getting up
--   "fallen"    - after a botched fall that showed the Falling pose: getting up
-- The last two are planned from the measured fall manifest by Anim.planLanding,
-- which also says how long they take.
--
-- There is no Lua setter for an engine knockdown; canMove() only reads one. So
-- this holds the controls for the clip's length instead, which does not depend
-- on the fall damage landing hard enough.
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local BaseState = require('scripts/Flow/states/base_state')
local Anim = require('scripts/Flow/playerAnim')
local SkillCheck = require('scripts/Flow/core/skill_check')

local StumbleState = BaseState.new("Stumble", { overrides = "movement", anim = "oneshot" })

local DURATION = { stumble = 1.00, knockdown = 1.50, fallen = 1.50 }

local timeInState = 0
local kind = "stumble"
local duration = DURATION.stumble

-- payload { kind = "stumble" | "knockdown" | "fallen" }; anything else is a stumble.
-- Airborne sets the fall context (impact, bearing) before handing over.
function StumbleState:enter(payload)
    timeInState = 0
    kind = (payload and DURATION[payload.kind]) and payload.kind or "stumble"
    SkillCheck.clearBotch()
    duration = (kind ~= "stumble" and Anim.planLanding(kind)) or DURATION[kind]
    Anim.setVariant(kind)
end

function StumbleState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if types.Actor.isDead(mwSelf) then return "Idle" end
    if not types.Actor.canMove(mwSelf) and kind == "stumble" then return "Idle" end

    mwSelf.controls.movement = 0
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.jump = false
    mwSelf.controls.run = false

    Anim.tickChain()

    if timeInState >= duration then return "Idle" end

    return nil
end

return StumbleState
