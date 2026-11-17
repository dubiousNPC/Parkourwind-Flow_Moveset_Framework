---@omw-context player
-- The landing you did not choose, one mechanism for three entries:
--   "stumble"   - after a botched manoeuvre: a fall clip, then pwfall1up
--   "knockdown" - after a skydive, by the landing check: an acrobatic tumble or
--                 handspring (high skill), or a fall and getting up (failed)
--   "fallen"    - after a botched fall that showed the Falling pose: getting up
-- All three are planned by Anim.planLanding from the landing check's band and
-- the authored clip layout (core/fall_plan.lua), which also gives the length.

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
local planned = false

function StumbleState:enter(payload)
    timeInState = 0
    kind = (payload and DURATION[payload.kind]) and payload.kind or "stumble"
    SkillCheck.clearBotch()
    local planLength = Anim.planLanding(kind, payload and payload.landing)
    planned = planLength ~= nil
    duration = planLength or DURATION[kind]
    Anim.setVariant(kind)
end

function StumbleState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    if types.Actor.isDead(mwSelf) then return "Idle" end
    if not types.Actor.canMove(mwSelf) and not planned then return "Idle" end

    mwSelf.controls.movement = 0
    mwSelf.controls.sideMovement = 0
    mwSelf.controls.jump = false
    mwSelf.controls.run = false

    Anim.tickChain()

    if timeInState >= duration then return "Idle" end

    return nil
end

return StumbleState
