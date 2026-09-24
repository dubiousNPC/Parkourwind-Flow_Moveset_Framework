---@omw-context player
--[[
    states/ladder.lua

    Climb a ladder static. Entered from Idle or Airborne when the player is
    facing a recognised ladder and presses forward into it.

    DETECTION IS BY RECORD ID, and that is the whole design constraint.
    OpenMW has no notion of a climbable surface, so the only thing separating a
    ladder from any other wall is what the object is called. nearby.castRay
    returns hitObject (openmw.LObject|nil per Cod3x 1.0), so hitObject.recordId
    is available and the test is a string match.

    Two things follow from that, and both matter more than the code:

      * The match list is USER-EDITABLE, not hardcoded. Ladder ids vary wildly
        between vanilla, Tamriel Rebuilt, OAAB and every interior overhaul, and
        no list written here could be right for an arbitrary install.

      * FLOW'S OWN RAYCAST, not SharedRay. SharedRay is bundled by many mods and
        whichever copy wins the interface decides what a result contains - one
        of them omits `distance`, which cost a session of logspam. hitObject is
        exactly the kind of optional field that goes missing. A dedicated cast
        is one ray on a keypress and cannot be taken away.

    MOVEMENT is the Hookshot/LedgeHang model: suspend gravity with a Levitate
    effect, then drive position directly. Locked to the vertical axis - lateral
    input does nothing while climbing, which is what makes a ladder read as a
    ladder rather than as flying.
]]--

local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')
local BaseState = require('states/base_state')
local Anim = require('playerAnim')
local Settings = require('settings')

local LadderState = BaseState.new("Ladder")

-- ==============================================
-- CONFIGURATION
-- ==============================================
local CLIMB_SPEED = 110.0      -- units/sec, up or down
local DETECT_REACH = 70.0      -- how far ahead to look for a ladder
local DETECT_HEIGHT = 70.0     -- cast from roughly chest height
local WALL_OFFSET = 28.0       -- how far to sit off the ladder face
local TOP_CLEARANCE = 40.0     -- headroom needed before stepping off the top
local EXIT_PUSH = 45.0         -- how far forward to place the player on exit

-- Levitate magnitude used to suspend gravity, matching ledge_hang.lua.
local LEVITATE_MAG = 200

-- Substrings matched against a lowercased recordId. Kept here rather than in
-- settings.lua because it is a content list, not a preference - but see the
-- README note: this is the first thing to edit for a given install, and the
-- Debug HUD prints the recordId of whatever you are facing so the list can be
-- built from what is actually there rather than guessed.
local LADDER_IDS = {
    "ladder",
    "_lad_",
}

local RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door,
}

-- ==============================================
-- DETECTION
-- ==============================================
local function looksLikeLadder(obj)
    if not obj then return false end
    local id = obj.recordId
    if type(id) ~= "string" then return false end
    id = string.lower(id)
    for i = 1, #LADDER_IDS do
        if string.find(id, LADDER_IDS[i], 1, true) then return true end
    end
    return false
end

-- Cast forward at chest height. Returns the hit position and surface normal
-- when a ladder is found, otherwise nil.
--
-- Called only on a forward keypress, never per frame.
function LadderState.probe()
    -- The transition would be refused by the state manager anyway; this saves
    -- the ray that would have justified asking for it. Returning nil is already
    -- this function's "no ladder here", so no caller needs to change.
    if not Settings.stateEnabled("Ladder") then return nil end

    local pos = mwSelf.position
    local yaw = mwSelf.rotation:getYaw()
    local forward = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))

    local origin = pos + util.vector3(0, 0, DETECT_HEIGHT)
    local res = nearby.castRay(origin, origin + forward * DETECT_REACH, RAY_OPTS)

    if Settings.debugMode() and res.hit and res.hitObject then
        print("[FLOW][ladder] facing: " .. tostring(res.hitObject.recordId))
    end

    if res.hit and looksLikeLadder(res.hitObject) then
        return res.hitPos, res.hitNormal
    end
    return nil
end

-- ==============================================
-- ENTRY DATA
-- ==============================================
local pendingPos = nil
local pendingNormal = nil

function LadderState.setLadder(hitPos, hitNormal)
    pendingPos = hitPos
    pendingNormal = hitNormal
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local wallNormal = nil
local levitateApplied = false
local lastDir = 0          -- -1 down, 0 idle, +1 up

local function applyLevitate(enable)
    if enable == levitateApplied then return end
    types.Actor.activeEffects(mwSelf):modify(
        enable and LEVITATE_MAG or -LEVITATE_MAG,
        core.magic.EFFECT_TYPE.Levitate)
    levitateApplied = enable
end

-- The clip is chosen by travel direction, so the variant has to be set before
-- the transition that plays it. Group names stay in playerAnim.lua.
local function setClipFor(dir)
    if dir > 0 then Anim.setVariant("up")
    elseif dir < 0 then Anim.setVariant("down")
    else Anim.setVariant("idle") end
end

function LadderState:enter(syncData)
    wallNormal = pendingNormal
    lastDir = 0
    pendingNormal = nil

    applyLevitate(true)
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)

    -- Face the ladder and sit a fixed distance off its face, so the climb is
    -- straight regardless of the angle of approach.
    if pendingPos and wallNormal then
        local flat = util.vector3(wallNormal.x, wallNormal.y, 0)
        if flat:length() > 0.01 then
            flat = flat:normalize()
            local snapPos = util.vector3(pendingPos.x, pendingPos.y, mwSelf.position.z)
                            + flat * WALL_OFFSET
            local faceYaw = math.atan2(flat.x, flat.y) + math.pi
            core.sendGlobalEvent('FLOW_SnapTo', {
                actor = mwSelf,
                position = snapPos,
                rotation = util.transform.rotateZ(faceYaw),
            })
        end
    end
    pendingPos = nil
end

function LadderState:exit()
    applyLevitate(false)
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    wallNormal = nil
    lastDir = 0
end

function LadderState:update(dt, syncData, inputData)
    -- Drop off deliberately.
    if inputData.crouch then
        return "Airborne"
    end

    -- Locked to the vertical axis: only forward/back drive the climb, and
    -- lateral input is ignored entirely rather than being allowed to slide the
    -- player along the ladder face.
    local dir = 0
    if inputData.moveVector.y > 0.1 then dir = 1
    elseif inputData.moveVector.y < -0.1 then dir = -1 end

    -- Re-issue the clip only when the direction actually changes, so holding a
    -- direction does not restart the animation every frame.
    if dir ~= lastDir then
        lastDir = dir
        setClipFor(dir)
        Anim.replay()
    end

    if dir == 0 then return nil end

    local pos = mwSelf.position
    local nextPos = pos + util.vector3(0, 0, CLIMB_SPEED * dir * dt)

    if dir > 0 then
        -- Reached the top: is there floor to step onto? Probe forward over the
        -- lip, and only leave the ladder when something is actually there.
        local flat = wallNormal and util.vector3(wallNormal.x, wallNormal.y, 0)
        if flat and flat:length() > 0.01 then
            flat = flat:normalize()
            local headOrigin = pos + util.vector3(0, 0, DETECT_HEIGHT + TOP_CLEARANCE)
            local ahead = nearby.castRay(headOrigin, headOrigin - flat * EXIT_PUSH, RAY_OPTS)
            if not ahead.hit then
                -- Nothing blocking above the lip: step off onto the top.
                core.sendGlobalEvent('FLOW_SnapTo', {
                    actor = mwSelf,
                    position = pos + util.vector3(0, 0, TOP_CLEARANCE) - flat * EXIT_PUSH,
                    rotation = mwSelf.rotation,
                })
                return "Idle"
            end
        end
    else
        -- Reached the bottom.
        if syncData.isGrounded then
            return "Idle"
        end
    end

    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = nextPos,
        rotation = mwSelf.rotation,
    })

    return nil
end

return LadderState
