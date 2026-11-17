---@omw-context player
-- The surfacing window: a very brief WaterWalking so a swimmer facing a rock
-- can stand on the water for a moment and climb out with the ordinary Vault /
-- Mantle ladder.
--
-- Why it is needed, measured in OpenMW 0.52 on real data: a swimmer floats with
-- its feet 120-133 units under the surface, and Mantle reaches 0.95 of the
-- body (about 122) above the feet. So a lip 15 above the water is already out
-- of reach from a swim, and what FLOW did instead was grab it as a LedgeHang
-- with the body still under water. Standing on the water puts the feet at the
-- surface and the same lip is 15 above them: a vault.
--
-- What it does NOT do: move the actor. WaterWalking on a swimmer makes the
-- engine lift it to the surface by itself (measured: feet -122 -> 0 within a
-- frame), and the climb is the existing state's own teleport.
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local Owned = require('scripts/Flow/core/owned')
local Body = require('scripts/Flow/core/body')
local Geom = require('scripts/Flow/core/geom')
local Sensor = require('scripts/Flow/core/sensor')

local Surface = {}

Surface.WINDOW = 0.5          -- seconds of water walking: long enough to stand and jump
Surface.WINDOW_LOW = 1.0      -- a lip under Vault's minimum is walked onto, not jumped: more time
Surface.WINDOW_MAX = 2.0      -- the window never outlasts this, airborne or not
Surface.REACH = 115           -- the forward sensor's standing reach (95) plus a stroke
Surface.LIP_PAST_FACE = 20    -- how far past the rock's face to look down for its top
Surface.MIN_LIP = 12          -- below this the swimmer can just swim onto it
Surface.STAND_GRACE = 0.25    -- standing on the water this long with no climb started: drop back in
Surface.STAND_GRACE_FRAMES = 5 -- ...and at least this many frames: the sensor's wall ray is async,
                               -- so at a low frame rate 0.25 s is only 2-3 frames (measured: 10 fps
                               -- over the sea in the harness closed it before the climb could start)
Surface.MAX_FACE_NZ = 0.5     -- the face must be steep: a beach or a sloped rock is swum onto, not climbed
Surface.MIN_TOP_NZ = 0.7      -- and its top flat enough to stand on (Shimmy's lip test)
-- What Mantle demands of its destination (states/mantle.lua). Copied, not
-- required, so this module does not load a state.
local TOP_PUSH_IN, TOP_LIFT, TOP_HEAD, TOP_FLOOR, TOP_TOL = 45.0, 35.0, 90.0, 200.0, 60.0
local VAULT_MIN_FRAC = 0.18   -- Sensor's: below this the engine's step takes it
Surface.MAX_LIP_FRAC = 0.95   -- Sensor's MANTLE_MAX_FRAC, from feet standing on the water
Surface.SURFACE_SLACK = 1.25  -- feet this many body-heights under is "at the surface" (floats measured 120-133)

local RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
        + nearby.COLLISION_TYPE.Door,
}

local open = false
local timeLeft = 0
local climbPending = false
local lastLip = nil
local lipPoint = nil
local openFor = 0
local standing = 0
local standingFrames = 0

-- The cell's flat water level, or nil in a dry cell. `hasWater and waterLevel`
-- is FALSE (not nil) in a dry cell; see AirPose.inWater.
function Surface.waterLevel()
    local cell = mwSelf.cell
    if not (cell and cell.hasWater and cell.waterLevel) then return nil end
    return cell.waterLevel
end

function Surface.swimming()
    return Surface.inWater()
end

-- Feet below the surface (positive = under). nil without water.
function Surface.depth()
    local wl = Surface.waterLevel()
    if not wl then return nil end
    return wl - mwSelf.position.z
end

-- In the water for FLOW's purposes. isSwimming alone flickers: a swimmer
-- bobbing at the surface reads not-swimming AND on the ground for frames at a
-- time (measured at feet -105 under, which put 0.86 in Idle there). So half a
-- body under with no ground beneath the feet also counts. The ray runs only
-- in that ambiguous band, never on land.
function Surface.inWater()
    if types.Actor.isSwimming(mwSelf) then return true end
    local d = Surface.depth()
    if not d or d < Body.height() * 0.5 then return false end
    local p = mwSelf.position
    return not nearby.castRay(p + util.vector3(0, 0, 5), p - util.vector3(0, 0, 15), RAY_OPTS).hit
end

function Surface.atSurface()
    local d = Surface.depth()
    return d ~= nil and d <= Body.height() * Surface.SURFACE_SLACK
end

-- Height of a climbable lip straight ahead, above the WATER, or nil, plus why
-- not. Only called on a Jump press, so it costs nothing while swimming.
--
-- Everything the climb itself would refuse is refused HERE, before the lift:
-- lifting first and letting Vault / Mantle say no stood the swimmer on the
-- water and dropped it back in, which read as a jump out of nowhere (measured:
-- a 60 lip under a roof gave Underwater > lifted > Idle > back in).
function Surface.lipAhead()
    local wl = Surface.waterLevel()
    if not wl then return nil end
    local pos = mwSelf.position
    local fwd = Geom.forward(mwSelf)
    local origin = util.vector3(pos.x, pos.y, wl + 5)
    local face = nearby.castRay(origin, origin + fwd * Surface.REACH, RAY_OPTS)
    if not face.hit then return nil, "no face" end
    if face.hitNormal and math.abs(face.hitNormal.z) > Surface.MAX_FACE_NZ then return nil, "face not steep" end
    local past = face.hitPos + fwd * Surface.LIP_PAST_FACE
    local height = Body.height()
    local maxLip = height * Surface.MAX_LIP_FRAC
    local top = nearby.castRay(util.vector3(past.x, past.y, wl + maxLip + 5),
        util.vector3(past.x, past.y, wl - 5), RAY_OPTS)
    if not top.hit then return nil, "no top" end
    local h = top.hitPos.z - wl
    if h < Surface.MIN_LIP or h > maxLip then return nil, "lip out of range" end
    if top.hitNormal and top.hitNormal.z < Surface.MIN_TOP_NZ then return nil, "top not flat" end

    -- Room to rise out of the water where the swimmer is.
    if nearby.castRay(util.vector3(pos.x, pos.y, wl + Geom.SURFACE_LIFT),
            util.vector3(pos.x, pos.y, wl + height + 10), RAY_OPTS).hit then
        return nil, "no headroom over the water"
    end
    -- The sensor that will pick the climb wants HEAD_CLEARANCE of air over
    -- the lip for either move ("Ceiling Blocked"); ask for the same here.
    if nearby.castRay(top.hitPos + util.vector3(0, 0, Geom.SURFACE_LIFT),
            top.hitPos + util.vector3(0, 0, Sensor.HEAD_CLEARANCE), RAY_OPTS).hit then
        return nil, "ceiling over the lip"
    end
    -- And somewhere to end up on top: Mantle's own destination test. A lip
    -- low enough to step onto is walked, and needs none of this.
    if h >= height * VAULT_MIN_FRAC then
        local flat = Geom.flat(fwd) or fwd
        local dest = top.hitPos + flat * TOP_PUSH_IN + util.vector3(0, 0, TOP_LIFT)
        if not Geom.standable(dest, TOP_HEAD, TOP_FLOOR, TOP_TOL, RAY_OPTS) then
            return nil, "nowhere to stand on top"
        end
    end
    return h, nil, top.hitPos
end

local function hasOwnWaterWalking()
    local e = types.Actor.activeEffects(mwSelf):getEffect(core.magic.EFFECT_TYPE.WaterWalking)
    return e and (e.magnitude or 0) > 0
end

-- Opens the window if there is something to climb. Returns the lip height.
function Surface.tryOpen()
    if open then return lastLip end
    local lip, _, point = Surface.lipAhead()
    if not lip then return nil end
    lastLip, lipPoint = lip, point
    -- Too low to vault (Sensor's VAULT_MIN_FRAC, 0.18): nothing in the ladder
    -- takes it, the engine's step does, so there is no climb to wait for.
    local low = lip < Body.height() * VAULT_MIN_FRAC
    climbPending = not low
    timeLeft = low and Surface.WINDOW_LOW or Surface.WINDOW
    openFor = 0
    standing = 0
    standingFrames = 0
    -- A swimmer who already has the effect is not swimming; no need, no double count.
    if not hasOwnWaterWalking() then
        Owned.effect(core.magic.EFFECT_TYPE.WaterWalking, 1)
        open = true
    end
    return lip
end

function Surface.close()
    if open then Owned.effect(core.magic.EFFECT_TYPE.WaterWalking, -1) end
    open, climbPending, timeLeft = false, false, 0
end

-- The jump that opened the window still counts once the swimmer is standing,
-- even if the key was let go: a tap at the rock is enough.
function Surface.climbPending()
    return climbPending
end

-- The lip the window was opened for: Idle hands it to Mantle when the forward
-- sensor does not offer a climb (it reads a sill against a wall as a wall).
function Surface.lipPoint()
    return lipPoint
end

function Surface.consumeClimb()
    climbPending = false
end

function Surface.isOpen()
    return open or climbPending
end

-- Counts down only while standing (on the water or the rock): a jump taken
-- from the water keeps it until the landing, so a short hop that comes down
-- short of the rock lands on the water again instead of through it.
--
-- And it never leaves the player standing on open water: once lifted, a climb
-- must start within STAND_GRACE (the ladder had its frame and said no), and a
-- low lip must be walked at (forward held), or the window shuts and the
-- player drops back into the swim instead of standing there able to jump.
function Surface.tick(dt, intents)
    if not (open or climbPending) then return end
    openFor = openFor + dt
    local grounded = types.Actor.isOnGround(mwSelf)
    if grounded or types.Actor.isSwimming(mwSelf) then
        timeLeft = timeLeft - dt
    end
    local onWater = grounded and open and math.abs(Surface.depth() or 99) < 3
    -- Standing on the water, the engine would turn the Jump that opened the
    -- window into a real jump off the surface before the ladder had its frame
    -- (the sensor's wall ray is async, a frame behind): that was the "partial
    -- jump". The climb reads Jump from input, not from controls, so this only
    -- takes the engine's own jump away, and only while lifted.
    if onWater then mwSelf.controls.jump = false end
    if onWater then
        standing = standing + dt
        standingFrames = standingFrames + 1
        local walking = intents and intents.moveVector and intents.moveVector.y > 0.1
        if standing >= Surface.STAND_GRACE and standingFrames >= Surface.STAND_GRACE_FRAMES
           and (climbPending or not walking) then
            Surface.close()
            return
        end
    end
    if timeLeft <= 0 or openFor >= Surface.WINDOW_MAX then Surface.close() end
end

function Surface.debugString()
    if not (open or climbPending) then return "" end
    return string.format("SURFACE %.2f lip %.0f%s", timeLeft, lastLip or -1, climbPending and " PEND" or "")
end

return Surface
