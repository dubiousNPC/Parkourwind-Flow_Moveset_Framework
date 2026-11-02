-- Mock OpenMW runtime for FLOW. Loads the real main.lua and global backend,
-- with a box world, a ray caster, simple gravity and a clock.
local ROOT = assert(MOD_ROOT, "set MOD_ROOT")
package.path = ROOT .. "/?.lua;" .. package.path

local M = { log = {}, events = {}, rays = 0, navQueries = 0 }

---------------------------------------------------------------- util
local V3 = {}
V3.__index = V3
local function v3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V3) end
V3.__add = function(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
V3.__sub = function(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
V3.__unm = function(a) return v3(-a.x, -a.y, -a.z) end
V3.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return v3(a.x * b, a.y * b, a.z * b)
end
V3.__div = function(a, b) return v3(a.x / b, a.y / b, a.z / b) end
V3.__tostring = function(a) return string.format("(%.1f, %.1f, %.1f)", a.x, a.y, a.z) end
function V3:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V3:normalize() local l = self:length(); return l > 0 and self / l or self end
function V3:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V3:cross(o)
    return v3(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
end
local V2 = {}
V2.__index = V2
local function v2(x, y) return setmetatable({ x = x, y = y }, V2) end
function V2:length() return math.sqrt(self.x ^ 2 + self.y ^ 2) end

local Rot = {}
Rot.__index = Rot
local function rotZ(a) return setmetatable({ yaw = a }, Rot) end
function Rot:getYaw() return self.yaw end
function Rot:apply(v)
    -- yaw 0 faces +Y; positive yaw turns toward +X
    local c, s = math.cos(self.yaw), math.sin(self.yaw)
    return v3(v.x * c + v.y * s, -v.x * s + v.y * c, v.z)
end

local util = {
    vector3 = v3, vector2 = v2,
    transform = { rotateZ = rotZ },
    color = { rgb = function() return {} end },
    clamp = function(x, a, b) return math.max(a, math.min(b, x)) end,
}
M.v3 = v3

---------------------------------------------------------------- world
M.boxes = {}
function M.box(id, minx, miny, minz, maxx, maxy, maxz)
    M.boxes[#M.boxes + 1] = { id = id, min = v3(minx, miny, minz), max = v3(maxx, maxy, maxz) }
end
function M.resetWorld()
    M.boxes = {}
    M.box("ground", -5000, -5000, -100, 5000, 5000, 0)
end

local function rayBox(from, to, b)
    local d = to - from
    local tmin, tmax, nrm = 0, 1, nil
    for _, ax in ipairs({ "x", "y", "z" }) do
        if math.abs(d[ax]) < 1e-9 then
            if from[ax] < b.min[ax] or from[ax] > b.max[ax] then return nil end
        else
            local t1 = (b.min[ax] - from[ax]) / d[ax]
            local t2 = (b.max[ax] - from[ax]) / d[ax]
            local n1 = -1
            if t1 > t2 then t1, t2 = t2, t1; n1 = 1 end
            if t1 > tmin then
                tmin = t1
                nrm = v3(ax == "x" and n1 or 0, ax == "y" and n1 or 0, ax == "z" and n1 or 0)
            end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    if not nrm then return nil end -- origin inside: Bullet does not hit
    return tmin, nrm
end

local function castRay(from, to)
    M.rays = M.rays + 1
    local best, bn, bb = 2, nil, nil
    for _, b in ipairs(M.boxes) do
        local t, n = rayBox(from, to, b)
        if t and t < best then best, bn, bb = t, n, b end
    end
    if not bb then return { hit = false } end
    return { hit = true, hitPos = from + (to - from) * best, hitNormal = bn,
             hitObject = { recordId = bb.id } }
end
M.castRay = castRay

---------------------------------------------------------------- clock / events
M.now = 0
local queued = {}

---------------------------------------------------------------- actor
local stat = function(base) return setmetatable({ base = base, modifier = 0, damage = 0 }, {
    __index = function(t, k) if k == "modified" then return t.base + t.modifier end end }) end

local player = {
    id = "player",
    position = v3(0, 0, 0),
    rotation = rotZ(0),
    cell = { isExterior = true, hasWater = false },
    controls = { movement = 0, sideMovement = 0, jump = false, run = false },
    vz = 0,
}
player.object = player
function player:isValid() return true end
function player:getBoundingBox() return { halfSize = v3(20, 20, 64) } end
function player:teleport(cell, pos, opts)
    self.position = pos
    if opts and opts.rotation then self.rotation = opts.rotation end
    self.vz = 0
    M.teleports = (M.teleports or 0) + 1
end
M.player = player

M.stats = {
    fatigue = { current = 200, base = 200, modifier = 0 },
    health = { current = 100, base = 100, modifier = 0 },
    acrobatics = stat(30), agility = stat(40),
}
M.effects = {}

---------------------------------------------------------------- modules
local pre = package.preload
pre['openmw.util'] = function() return util end
pre['openmw.self'] = function() return player end
pre['openmw.async'] = function() return { callback = function(_, f) return f end } end
pre['openmw.vfs'] = function() return { fileExists = function() return false end } end
pre['openmw.camera'] = function() return {
    getPosition = function() return player.position + v3(0, 0, 110) end,
    setExtraPitch = function() end, setExtraRoll = function() end,
} end
pre['openmw.ui'] = function() return {
    printToConsole = function(t) M.log[#M.log + 1] = t end,
    showMessage = function() end,
    CONSOLE_COLOR = { Default = 0, Error = 1, Success = 2, Info = 3 },
    TYPE = { Flex = 1, Text = 2 }, ALIGNMENT = { End = 1 },
    content = function(t) return t end,
    create = function(l) return { layout = l, update = function() end, destroy = function() end } end,
} end
pre['openmw.core'] = function() return {
    getRealTime = function() return M.now end,
    getSimulationTime = function() return M.now end,
    isWorldPaused = function() return false end,
    sendGlobalEvent = function(name, data)
        queued[#queued + 1] = { name, data }
        M.events[#M.events + 1] = name
    end,
    magic = { EFFECT_TYPE = setmetatable({}, { __index = function(_, k) return k end }) },
} end
M.settings = {}
local subscribers = {}
function M.setSetting(k, v)
    M.settings[k] = v
    for _, cb in ipairs(subscribers) do cb() end
end
pre['openmw.storage'] = function() return {
    playerSection = function() return {
        get = function(_, k) return M.settings[k] end,
        subscribe = function(_, cb) subscribers[#subscribers + 1] = cb end,
    } end,
} end
M.pressed = {}
M.triggers = {}
pre['openmw.input'] = function() return {
    ACTION = setmetatable({}, { __index = function(_, k) return k end }),
    isActionPressed = function(a) return M.pressed[a] == true end,
    registerTriggerHandler = function(name, cb) M.triggers[name] = cb end,
} end
M.anim = { played = {}, playing = {} }
pre['openmw.animation'] = function() return {
    BONE_GROUP = { LowerBody = 0, Torso = 1, LeftArm = 2, RightArm = 3 },
    PRIORITY = setmetatable({}, { __index = function(_, k) return k end }),
    BLEND_MASK = { All = 15 },
    playBlended = function(_, g, o)
        M.anim.played[#M.anim.played + 1] = g; M.anim.playing[g] = true
    end,
    cancel = function(_, g) M.anim.playing[g] = nil end,
    isPlaying = function(_, g) return M.anim.playing[g] == true end,
    hasGroup = function() return true end,
    getTextKeyTime = function() return nil end,
} end

local function grounded()
    local below = castRay(player.position + v3(0, 0, 2), player.position - v3(0, 0, 2))
    M.rays = M.rays - 1
    return below.hit and player.vz <= 0
end
M.grounded = grounded
local function activeEffects()
    return { modify = function(_, amount, id, arg)
        local k = arg and (id .. "|" .. arg) or id
        M.effects[k] = (M.effects[k] or 0) + amount
        if M.effects[k] == 0 then M.effects[k] = nil end
    end }
end
pre['openmw.types'] = function() return {
    Actor = {
        isOnGround = function() return grounded() end,
        canMove = function() return true end,
        isSwimming = function() return false end,
        getEncumbrance = function() return 0 end,
        getCapacity = function() return 100 end,
        activeEffects = activeEffects,
        stats = {
            dynamic = {
                fatigue = function() return M.stats.fatigue end,
                health = function() return M.stats.health end,
            },
            attributes = setmetatable({}, { __index = function(_, k)
                return function() return M.stats[k] or stat(40) end end }),
        },
    },
    NPC = { stats = { skills = setmetatable({}, { __index = function(_, k)
        return function() return M.stats[k] or stat(30) end end }) } },
} end
pre['openmw.nearby'] = function() return {
    COLLISION_TYPE = { World = 1, Door = 2, Actor = 4, HeightMap = 8, Projectile = 16, Water = 32 },
    castRay = function(a, b) return castRay(a, b) end,
    findNearestNavMeshPosition = function(p)
        M.navQueries = M.navQueries + 1
        local r = castRay(p + v3(0, 0, 60), p - v3(0, 0, 200))
        return r.hit and r.hitPos or nil
    end,
} end

M.pitch = 0  -- camera pitch, radians, positive = up
M.override = { movement = false, combat = false, writes = 0 }
local I = {
    Controls = {
        overrideMovementControls = function(b) M.override.movement = b; M.override.writes = M.override.writes + 1 end,
        overrideCombatControls = function(b) M.override.combat = b end,
    },
    UI = { getMode = function() return nil end },
    Settings = { registerPage = function() end, registerGroup = function() end },
    AnimationController = { addTextKeyHandler = function() end },
    SharedRay = {
        version = 2,
        requestDistance = function() end,
        getUnclipped = function()
            local cam = player.position + v3(0, 0, 110)
            local fwd = rotZ(player.rotation:getYaw()):apply(v3(0, 1, 0))
            local dir = v3(fwd.x * math.cos(M.pitch), fwd.y * math.cos(M.pitch), math.sin(M.pitch))
            local r = castRay(cam, cam + dir * 500)
            M.rays = M.rays - 1   -- shared ray: not FLOW's cost
            return r
        end,
    },
}
pre['openmw.interfaces'] = function() return I end

---------------------------------------------------------------- load
local function loadfileOr(path)
    local chunk = assert(loadfile(ROOT .. "/" .. path))
    return chunk()
end
M.main = loadfileOr("scripts/Flow/main.lua")
M.backend = loadfileOr("scripts/Flow/global/flow_amf_backend.lua")
M.SM = require('scripts/Flow/core/state_manager')
M.Sensor = require('scripts/Flow/core/sensor')
M.SkillCheck = require('scripts/Flow/core/skill_check')

function M.state() return M.SM.getActiveStateName() end

local function backendBusy()
    -- the backend's table is local; infer from the last teleport frame
    return M.movedThisFrame
end

local GRAVITY = 627.2
function M.step(dt)
    dt = dt or (1 / 60)
    M.now = M.now + dt
    M.main.engineHandlers.onUpdate(dt)
    local q = queued; queued = {}
    for _, e in ipairs(q) do
        local h = M.backend.eventHandlers[e[1]]
        if h then h(e[2]) end
    end
    local before = M.teleports or 0
    M.backend.engineHandlers.onUpdate(dt)
    M.movedThisFrame = (M.teleports or 0) > before
    -- physics: gravity unless levitating or the backend drove the actor
    if not M.movedThisFrame and not (M.effects.Levitate and M.effects.Levitate > 0) then
        player.vz = player.vz - GRAVITY * dt
        local nz = player.position.z + player.vz * dt
        local floor = castRay(player.position + v3(0, 0, 1), v3(player.position.x, player.position.y, nz - 1))
        M.rays = M.rays - 1
        if floor.hit and player.vz < 0 then
            nz = floor.hitPos.z; player.vz = 0
        end
        player.position = v3(player.position.x, player.position.y, nz)
    end
    -- engine-driven lateral motion while FLOW holds the override (Shimmy, Roll)
    if M.override.movement then
        local c = player.controls
        local fwd = rotZ(player.rotation:getYaw()):apply(v3(0, 1, 0))
        local right = rotZ(player.rotation:getYaw()):apply(v3(1, 0, 0))
        local move = fwd * ((c.movement or 0) * 150 * dt) + right * ((c.sideMovement or 0) * 60 * dt)
        local target = player.position + move
        if not castRay(player.position + v3(0, 0, 60), target + v3(0, 0, 60)).hit then
            player.position = target
        end
        M.rays = M.rays - 1
    end
end

function M.run(seconds, dt)
    dt = dt or (1 / 60)
    for _ = 1, math.floor(seconds / dt + 0.5) do M.step(dt) end
end

function M.reset(pos, yaw)
    M.resetWorld()
    player.position = pos or v3(0, 0, 0)
    player.rotation = rotZ(yaw or 0)
    player.vz = 0
    M.pressed = {}
    M.pitch = 0
    M.step()                       -- sample released input
    M.SM.setState("Idle")
    M.SkillCheck.clearBotch()
end

M.resetWorld()
M.main.engineHandlers.onInit()
M.main.engineHandlers.onActive()
return M
