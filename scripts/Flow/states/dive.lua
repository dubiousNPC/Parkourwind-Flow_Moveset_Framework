---@omw-context player
-- Dive. A jump pressed as the roll finishes, carried into the air with the
-- pwfalling pose over it. Entered only from Roll; see states/roll.lua.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local BaseState = require('scripts/Flow/states/base_state')
local SkillCheck = require('scripts/Flow/core/skill_check')

local DiveState = BaseState.new("Dive")

-- One push, then the engine owns the arc.
local DIVE_APEX = 150.0
local DIVE_PUSH = 520.0
local DIVE_FLIGHT = 1.2

-- Clear the ground before isGrounded is trusted again.
local MIN_AIR_TIME = 0.20

local timeInState = 0

function DiveState:enter(syncData)
    timeInState = 0

    if SkillCheck.evaluate("Dive") ~= "ok" then
        self.abort = true
        return
    end
    self.abort = false

    SkillCheck.spend("Dive")

    local yaw = mwSelf.rotation:getYaw()
    local fwd = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))

    core.sendGlobalEvent('FLOW_Boost_Start', {
        actor = mwSelf,
        apexHeight = DIVE_APEX,
        pushVelocity = fwd * DIVE_PUSH,
        maxDuration = DIVE_FLIGHT,
    })

    -- No movement override: the pose is cosmetic and air control stays vanilla.
    I.Controls.overrideCombatControls(true)
end

function DiveState:exit()
    I.Controls.overrideCombatControls(false)
    core.sendGlobalEvent('FLOW_Move_Cancel', { actor = mwSelf })
end

function DiveState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end

    timeInState = timeInState + dt

    if timeInState < MIN_AIR_TIME then return nil end

    if syncData.isGrounded then return "Idle" end

    -- Hand over airborne, so the whole ladder is reachable out of a dive.
    if timeInState >= DIVE_FLIGHT then return "Airborne" end

    return nil
end

return DiveState
