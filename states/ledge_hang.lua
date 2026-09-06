---@omw-context player
--[[
    states/ledge_hang.lua

    Detection (targetPos/wallNormal/etc) comes from
    core/optional/sensor_ext.lua. The climb-up-to-Mantle handoff still
    writes into core/sensor.lua's Sensor.data, since states/mantle.lua only
    ever reads from there.
]]--

local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local ShimmyState = require('states/shimmy')

local LedgeHangState = BaseState.new("LedgeHang")

local KICK_RAY_OPTS = { ignore = mwSelf }

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local LEVITATE_MAG = 200      
local HANG_OFFSET_Z = 125     
local WALL_OFFSET = 35        
local KICK_FORCE_BACK = 350
local KNEE_CHECK_DIST = 60
local CLIMB_COOLDOWN = 0.3    -- [NEW] Time to wait before allowing climb-up

-- =============================================================================
-- INTERNAL STATE
-- =============================================================================
local levitationApplied = false
local wallNormal = nil
local timeInState = 0         -- [NEW] Track how long we've been hanging
local cachedTargetPos = nil   -- [NEW] Store the ledge position

-- =============================================================================
-- HELPERS
-- =============================================================================

local function applyGravityHack(enable)
    local activeEffects = types.Actor.activeEffects(mwSelf)
    if not activeEffects then return end

    if enable then
        if not levitationApplied then
            activeEffects:modify(LEVITATE_MAG, core.magic.EFFECT_TYPE.Levitate)
            levitationApplied = true
        end
    else
        if levitationApplied then
            activeEffects:modify(-LEVITATE_MAG, core.magic.EFFECT_TYPE.Levitate)
            levitationApplied = false
        end
    end
end

local function snapTo(pos, rot)
    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = pos,
        rotation = rot 
    })
end

-- =============================================================================
-- STATE INTERFACE
-- =============================================================================

function LedgeHangState:enter(syncData)
    print("[FLOW_STATE] >>> ENTERING LEDGE HANG")
    
    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("LedgeHang", SensorExt.data.debugReason, "GRABBED")

    timeInState = 0 -- Reset timer

    -- 1. Suspend Gravity
    applyGravityHack(true)
    
    -- 2. Snap Position & Rotation
    --
    -- A lip handed back by Shimmy wins over the sensor. Returning from a step
    -- the sensor may not re-detect on that exact frame -- updateLedgeHang
    -- clears targetPos at the top of every call -- and without this the whole
    -- snap block below was skipped, leaving wallNormal stale from the previous
    -- step and the body un-anchored.
    local resumeLip, resumeNormal = ShimmyState.consumeResultLip()
    local lipSource = resumeLip or SensorExt.data.targetPos

    if lipSource then
        -- [CRITICAL] Cache the target position so we don't lose it if the sensor misses next frame
        cachedTargetPos = lipSource

        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        wallNormal = resumeNormal or SensorExt.data.wallNormal or -forward
        
        local hangPos = cachedTargetPos - util.vector3(0, 0, HANG_OFFSET_Z)
        hangPos = hangPos + (wallNormal * WALL_OFFSET)
        
        local lookDir = -wallNormal
        local targetYaw = math.atan2(lookDir.x, lookDir.y)
        local targetRot = util.transform.rotateZ(targetYaw)
        
        snapTo(hangPos, targetRot)
    end
    
    -- Animation is owned entirely by playerAnim.lua now (called right
    -- after this enter() returns, via state_manager.lua's setState choke
    -- point) - this used to call anim.playBlended('swimidle', ...)
    -- directly, which raced with playerAnim.lua's own attempt to play
    -- whatever's configured for "LedgeHang" and is exactly why the
    -- configured custom animation wasn't reliably showing. See
    -- playerAnim.lua's GROUPS.LedgeHang entry for the tuning (priority,
    -- blendMask) that used to live here.
    
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
end

function LedgeHangState:exit()
    print("[FLOW_STATE] <<< EXITING LEDGE HANG")
    applyGravityHack(false)
    
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    
    cachedTargetPos = nil
end

function LedgeHangState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- 0. SHIMMY - lateral input, no jump involved, so it cannot contend with
    -- the jump-gated branches below. The destination is probed BEFORE the
    -- transition so a blocked step never starts an animation or a move.
    local lateralInput = inputData.moveVector.x
    if math.abs(lateralInput) > 0.1 and wallNormal and cachedTargetPos then
        local dir = (lateralInput > 0) and 1 or -1
        -- probeStep needs BOTH the body (clearance sweep) and the lip
        -- (continuation probe); passing only the body made it always fail.
        local newLip = ShimmyState.probeStep(mwSelf.position, cachedTargetPos, wallNormal, dir)
        if newLip then
            -- The lip rides along with the step. Assigning it to
            -- cachedTargetPos here would be pointless: exit() runs before the
            -- next enter() and nils it.
            ShimmyState.setStep(dir, wallNormal, newLip)
            return "Shimmy"
        end
    end

    -- 1. WALL KICK / JUMP AWAY
    --
    -- [BUGFIX] This MUST be tested before the climb-up below. Both branches
    -- are gated on inputData.jump, and the climb had no directional
    -- condition at all - so once CLIMB_COOLDOWN elapsed it swallowed every
    -- jump press, including jump+back. The kick was unreachable for the
    -- entire life of the hang after the first 0.3s, and KICK_FORCE_BACK sat
    -- as a dead constant. Checking the more specific condition first
    -- restores it.
    if inputData.jump and inputData.moveVector.y < 0 then
        local kneePos = mwSelf.position + util.vector3(0,0, 30)
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local kickTarget = kneePos + (forward * KNEE_CHECK_DIST)
        
        local res = nearby.castRay(kneePos, kickTarget, KICK_RAY_OPTS)
        
        -- Face the way you are kicking. Hanging, the player is turned INTO
        -- the wall; releasing without turning leaves them looking at the
        -- surface they just pushed off.
        --
        -- 90 degrees, not 180. A full reversal points the camera straight down
        -- the flight path and hides the wall entirely, which loses the sense of
        -- having pushed off something. A quarter turn puts the wall in
        -- peripheral view while opening up the direction of travel - the
        -- player can see both where they came from and where they are going.
        --
        -- Sign follows the shimmy direction so the turn continues the way the
        -- player was already moving; a kick from a standing hang defaults to
        -- turning right.
        local turnSign = (ShimmyState.lastDirection() < 0) and -1 or 1
        local awayYaw = mwSelf.rotation:getYaw() + (turnSign * math.pi * 0.5)
        local awayRot = util.transform.rotateZ(awayYaw)

        if res.hit then
            local nudge = mwSelf.position + (-forward * (KICK_FORCE_BACK * 0.15)) + (util.vector3(0,0,20))
            snapTo(nudge, awayRot)
        else
            -- Nothing to push off, but still turn to face the fall.
            snapTo(mwSelf.position, awayRot)
        end
        return "Airborne"
    end

    -- 2. CLIMB UP (Mantle) - any jump press that isn't a deliberate
    -- kick-away, once the entry cooldown has elapsed.
    if inputData.jump and timeInState > CLIMB_COOLDOWN then

        -- [CRITICAL] Restore the cached target position into the Sensor data
        -- This ensures Mantle receives the valid ledge position even if the sensor missed this frame.
        Sensor.data.interaction = "Mantle"
        Sensor.data.targetPos = cachedTargetPos  -- core Sensor, so mantle.lua picks it up

        return "Mantle"
    end

    -- 3. DROP
    if inputData.crouch then
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local nudge = mwSelf.position + (-forward * 20) 
        snapTo(nudge)
        return "Airborne"
    end

    return nil
end

return LedgeHangState