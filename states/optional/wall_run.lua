---@omw-context player
-- WallRun. Optional, not loaded by default.
local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local camera = require('openmw.camera')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local anim = require('openmw.animation') 
local SensorExt = require('core/optional/sensor_ext')
local Settings = require('settings')
local nearby = require('openmw.nearby')

local WallRunState = BaseState.new("WallRun")

local DEBUG_MODE = true           
local DEBUG_INTERVAL = 0.2        

local TILT_ANGLE = 15.0           
local TILT_SPEED = 8.0            
local FATIGUE_COST = 15.0         
local LEVITATE_MAG = 10           
local WALL_COYOTE_TIME = 0.35     -- Increased slightly for high speed transitions

-- [TUNED] Physics & Collision Avoidance
local SAFE_WALL_DIST = 60.0       -- Increased distance to prevent clipping at high speed
local CORRECTION_STIFFNESS = 10.0 -- Softer correction to prevent jittery snapping
local OUTWARD_BIAS = 0.2          -- "Surf" factor: 0.0 = Parallel, 1.0 = 45 deg away from wall.
                                  -- 0.2 helps glide over uneven geometry.

-- [TUNED] Speed & Gravity
local WALL_SPEED_MULT = 2.5       -- Base multiplier (2.5x run speed)
local MIN_WALL_SPEED = 900.0      -- High minimum floor for athletic feel
local WALL_GRAVITY = 280.0        -- Gravity
local INITIAL_ARC = 600.0         -- Initial vertical pop
local LAUNCH_DURATION = 0.30      -- Duration of the "Hard Lift" phase
local LAUNCH_LIFT = 8.0           -- Vertical units per frame added during launch

local currentRoll = 0
local levitationApplied = false
local activeSide = "None"
local debugTimer = 0

local wallLostTimer = 0
local lastWallNormal = nil
local lastRunDir = nil
local lastDist = SAFE_WALL_DIST
local hasReleasedJump = false
local verticalVelocity = 0
local forwardSpeed = 0            
local timeInState = 0             

local function lerp(a, b, t)
    return a + (b - a) * math.max(0, math.min(t, 1))
end

local function debugPrint(msg)
    if DEBUG_MODE then print("[FLOW:WallRun] " .. msg) end
end

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

function WallRunState:enter(syncData)
    if SensorExt.data.wallRun.side == "None" then
        self.abort = true
        return
    end

    activeSide = SensorExt.data.wallRun.side
    lastWallNormal = SensorExt.data.wallRun.normal
    lastRunDir = SensorExt.data.wallRun.runVector
    lastDist = SensorExt.data.wallRun.dist
    
    wallLostTimer = 0
    hasReleasedJump = false 
    timeInState = 0
    
    local entryZ = (syncData and syncData.verticalVelocity) or 0
    verticalVelocity = math.max(entryZ * 0.5, INITIAL_ARC)
    
    -- 2. Calculate Speed (Horizontal)
    local entrySpeed = (syncData and syncData.forwardVelocity) or 0
    local baseRunSpeed = types.Actor.getRunSpeed(mwSelf)
    
    -- Calculate target speed
    forwardSpeed = math.max(entrySpeed, baseRunSpeed * WALL_SPEED_MULT)
    forwardSpeed = math.max(forwardSpeed, MIN_WALL_SPEED)
    
    debugPrint(string.format("ENTER: Side=%s | Spd=%.0f | Arc=%.0f", activeSide, forwardSpeed, verticalVelocity))
    
    applyGravityHack(true)
    I.Controls.overrideMovementControls(true) 
    
    anim.playBlended(mwSelf, 'runforward', {
        priority = anim.PRIORITY.Weapon,
        loops = -1,
        speed = 1.35,
        blendMask = anim.BLEND_MASK.LowerBody, 
        autoDisable = false 
    })

    currentRoll = camera.getExtraRoll() or 0
    debugTimer = 0
    self.abort = false

    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("WallRun", activeSide, "STARTED")
end

function WallRunState:exit()
    I.Controls.overrideMovementControls(false)
    applyGravityHack(false)
    anim.cancel(mwSelf, 'runforward')

    camera.setExtraRoll(0)
    currentRoll = 0
end

function WallRunState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end
    
    timeInState = timeInState + dt
    local isLaunching = timeInState < LAUNCH_DURATION

    -- 1. Input / State Checks
    local runDir, wallNormal, currentDist
    
    if SensorExt.data.wallRun.side ~= "None" then
        wallLostTimer = 0
        lastWallNormal = SensorExt.data.wallRun.normal
        lastRunDir = SensorExt.data.wallRun.runVector
        lastDist = SensorExt.data.wallRun.dist
        
        runDir = lastRunDir
        wallNormal = lastWallNormal
        currentDist = lastDist
        activeSide = SensorExt.data.wallRun.side 
    else
        -- Ignore wall loss during Launch to prevents jittery exits at start
        if not isLaunching then
            wallLostTimer = wallLostTimer + dt
            if wallLostTimer > WALL_COYOTE_TIME then
                debugPrint("ABORT: Wall Lost")
                return "Airborne"
            end
        end
        runDir = lastRunDir
        wallNormal = lastWallNormal
        currentDist = lastDist 
    end

    if inputData.moveVector.y <= 0 then
        debugPrint("ABORT: Forward input released")
        return "Airborne"
    end

    local dyn = types.Actor.stats.dynamic.fatigue(mwSelf)
    if dyn.current <= 0 then
        debugPrint("ABORT: Fatigue exhausted")
        return "Airborne"
    end
    
    dyn.current = math.max(0, dyn.current - (FATIGUE_COST * dt))

    -- 2. Physics Calculation
    
    local surfDir = (runDir + (wallNormal * OUTWARD_BIAS)):normalize()
    local velocityVec = surfDir * forwardSpeed
    
    -- B. Wall Constraint (Spring Arm)
    local distError = currentDist - SAFE_WALL_DIST
    local correctionMag = distError * CORRECTION_STIFFNESS
    correctionMag = math.max(-200, math.min(200, correctionMag))
    local correctionVec = wallNormal * (-correctionMag)
    
    -- C. Vertical Velocity
    verticalVelocity = verticalVelocity - (WALL_GRAVITY * dt)
    local gravityVec = util.vector3(0, 0, verticalVelocity)
    
    -- Combine vectors
    local finalMovement = (velocityVec + correctionVec + gravityVec) * dt
    local nextPos = mwSelf.position + finalMovement

    if isLaunching then
        local liftFactor = (1.0 - (timeInState/LAUNCH_DURATION))
        nextPos = nextPos + util.vector3(0, 0, LAUNCH_LIFT * liftFactor)
    end

    -- 3. Ground Collision Check
    if verticalVelocity < 0 and not isLaunching then
        local floorCheck = nearby.castRay(nextPos + util.vector3(0,0,20), nextPos - util.vector3(0,0,10), {
            collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap,
            ignore = mwSelf
        })
        
        if floorCheck.hit then
            debugPrint("EXIT: Landed")
            return "Idle"  -- was "Sprint" - not registered by default, see states/optional/README.md
        end
    end

    -- 4. Apply Movement
    mwSelf:teleport(mwSelf.cell, nextPos, {
        onGround = false,
        rotation = mwSelf.rotation
    })

    -- 5. Camera Tilt
    local targetAngle = (activeSide == "Right") and -TILT_ANGLE or TILT_ANGLE
    local targetRad = math.rad(targetAngle)
    currentRoll = lerp(currentRoll, targetRad, dt * TILT_SPEED)
    camera.setExtraRoll(currentRoll)

    -- 6. Wall Jump (Exit)
    if not inputData.jump then
        hasReleasedJump = true
    elseif hasReleasedJump and inputData.jump then
        debugPrint("EXIT: Wall Jump")
        return "Airborne"
    end

    if DEBUG_MODE then
        debugTimer = debugTimer + dt
        if debugTimer > DEBUG_INTERVAL then
            if Settings.debugMode() then print(string.format("[FLOW] WallRun | Z: %.0f | Spd: %.0f | Launch: %s", verticalVelocity, forwardSpeed, tostring(isLaunching))) end
            debugTimer = 0
        end
    end

    return nil
end

return WallRunState