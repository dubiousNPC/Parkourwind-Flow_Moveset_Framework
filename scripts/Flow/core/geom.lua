---@omw-context player
-- Shared geometry: facing vectors and the landing-spot probe Vault and Mantle
-- both run.
local nearby = require('openmw.nearby')
local util = require('openmw.util')

local Geom = {}

-- How far a probe starts OFF a surface it was derived from. A ray that starts
-- exactly on a collision surface hits that surface, at distance 0 - measured
-- in OpenMW 0.52 on real meshes: up from the top of ex_dwrv_block00 it hit
-- the block itself, normal (0,0,-1); started 0.5 higher it was clear. Every
-- headroom and clearance probe FLOW cast from a hit point therefore found its
-- own floor, and on real geometry every vault, mantle and ledge grab was
-- refused ("Ceiling Blocked", "no headroom", lip not clear).
Geom.SURFACE_LIFT = 2.0

local Y = util.vector3(0, 1, 0)
local X = util.vector3(1, 0, 0)
local UP = util.vector3(0, 0, 1)
Geom.UP = UP

function Geom.forward(obj)
    return util.transform.rotateZ(obj.rotation:getYaw()):apply(Y)
end

function Geom.right(obj)
    return util.transform.rotateZ(obj.rotation:getYaw()):apply(X)
end

-- Unit XY direction, or nil for a near-vertical vector.
function Geom.flat(v)
    local f = util.vector3(v.x, v.y, 0)
    if f:length() < 0.01 then return nil end
    return f:normalize()
end

-- A spot the actor can stand on: floor within `tolerance` below `pos`, found
-- by a ray from `head` above it down to `floor` below, and nothing between
-- the spot and the head height.
function Geom.standable(pos, head, floor, tolerance, opts)
    local top = pos + util.vector3(0, 0, head)
    local floorRes = nearby.castRay(top, pos - util.vector3(0, 0, floor), opts)
    if not floorRes.hit then return false, "no floor" end
    if (pos.z - floorRes.hitPos.z) > tolerance then return false, "floor too low" end
    if nearby.castRay(pos + util.vector3(0, 0, Geom.SURFACE_LIFT), top, opts).hit then
        return false, "no headroom"
    end
    return true
end

return Geom
