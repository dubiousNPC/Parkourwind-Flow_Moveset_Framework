---@omw-context player
--[[
    Shared Raycast Service v2

    Provides a single async rendering raycast per frame for all mods to consume.
	Can be bundled in every mod, only runs once (the latest version)
	
    Examples:
        local result = I.SharedRay.get()
        if result.hit then
            -- player is looking at something in activation range
        end

        -- one-shot, result clipped to your distance
        I.SharedRay.request(2048, function(result)
            if result.hit then
                -- something within 2048, fires one frame later
            end
        end)

        -- persistent, unclipped result after every cast
        I.SharedRay.subscribe("MyMod", function(result)
            if result.hit and result.distance <= 2048 then
                -- do the distance check yourself
            end
        end)

    Result fields (all delivery paths):
        hit         - boolean
        hitPos      - Vector3 or nil
        hitNormal   - Vector3 or nil
        hitObject   - GameObject or nil
        hitTypeName - string (e.g. "Container", "NPC") or nil
		vanishedObject - if the hitObject isnt valid or has 0-count for some reason it lands here
        distance    - number or nil, hit distance from camera

    v2 notes:
        - get() is v1 behavior
        - requestDistance(d) raises the ray length for the session, never lowers it
        - getRequestedDistance() returns the highest requested distance so far, activation distance not included, 0 if nobody requested anything
        - getUnclipped() returns the raw hit at full ray length, subscribers check distance themselves
        - the cast is async, results lag one frame behind the camera
        - requestSynchronous() switches the cast back to sync for the session, never reverts, results are same-frame again (avoid for performance reasons)
        - isSynchronous() returns whether the cast is currently sync
        - hitObject is validated on delivery (isValid and count > 0), positional data always stays but hitObject might move to vanishedObject
        - setRayType is a deprecated no-op
        - hitPos precision is ~0.01 units on long rays, hitNormal is as unreliable as always
        - all results are live views, not a snapshot: they change every frame, copy fields to keep them (do not store the tables)
        - request(d, callback) makes the next cast at least d units long and calls back once with the result if anything is within that distance
        - subscribe(key, callback) registers a persistent callback, called with the unclipped result after every cast, misses included
        - subscribe(key, nil) unregisters again
        - callbacks run in pcall, an error is printed and does not stop delivery
]]
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local async = require('openmw.async')
local I = require('openmw.interfaces')
local iMaxActivateDist = core.getGMST("iMaxActivateDist") or 192
local activeEffects = types.Actor.activeEffects(self)
local TELEKINESIS = core.magic.EFFECT_TYPE.Telekinesis
local rayOptions = { ignore = self }

local MY_VERSION = 2
local requestedDist = 0
local syncRequested = false
local emptyResult = { hit = false }
local cachedResult = emptyResult
local cachedUnclipped = emptyResult
local cachedUnclippedRaw = { hit = true }
local pendingRequests = nil
local inFlightRequests = nil
local subscribers = {}
local firedPos = nil
local firedMax = 0

if I.SharedRay and I.SharedRay.version >= MY_VERSION then
	return
end

local function getCameraVector()
	local yaw = camera.getYaw()
	local pitch = camera.getPitch()
	local cosPitch = math.cos(pitch)
	return util.vector3(
		math.sin(yaw) * cosPitch,
		math.cos(yaw) * cosPitch,
		-math.sin(pitch)
	)
end

-- consumer errors must not break the shared delivery
local function fireCallback(callback, result)
	local ok, err = pcall(callback, result)
	if not ok then
		print("[SharedRay] callback error: " .. tostring(err))
	end
end

-- delivery, usually one frame after the cast
local function processRay(ray)
	if ray.hit then
		local hitObject = ray.hitObject
		local vanishedObject = nil
		-- object removed mid flight, keep positional data
		if hitObject and not (hitObject:isValid() and hitObject.count > 0) then
			vanishedObject = hitObject
			hitObject = nil
		end
		--cachedUnclipped = {
		--	hit = true,
		--	hitPos = ray.hitPos,
		--	hitNormal = ray.hitNormal,
		--	hitObject = hitObject,
		--	hitTypeName = hitObject and tostring(hitObject.type) or nil,
		--	vanishedObject = vanishedObject,
		--	distance = (ray.hitPos - firedPos):length(),
		--}
		-- memory saving:
		cachedUnclippedRaw.hitPos = ray.hitPos
		cachedUnclippedRaw.hitNormal = ray.hitNormal
		cachedUnclippedRaw.hitObject = hitObject
		cachedUnclippedRaw.hitTypeName = hitObject and tostring(hitObject.type) or nil
		cachedUnclippedRaw.vanishedObject = vanishedObject
		cachedUnclippedRaw.distance = (ray.hitPos - firedPos):length()

		cachedUnclipped = cachedUnclippedRaw
	else
		cachedUnclipped = emptyResult
	end

	-- legacy result masks hits beyond activation range
	if cachedUnclipped.hit and cachedUnclipped.distance <= firedMax then
		cachedResult = cachedUnclipped
	else
		cachedResult = emptyResult
	end

	-- one-shot requests, clipped to their own distance
	local requests = inFlightRequests
	if requests then
		inFlightRequests = nil
		for i = 1, #requests do
			local req = requests[i]
			if cachedUnclipped.hit and cachedUnclipped.distance <= req.dist then
				fireCallback(req.callback, cachedUnclipped)
			else
				fireCallback(req.callback, emptyResult)
			end
		end
	end

	-- persistent subscribers, unclipped
	for _, callback in pairs(subscribers) do
		fireCallback(callback, cachedUnclipped)
	end
end
local rayCallback = async:callback(processRay)

local function onFrame()
	-- Defer to higher version if one exists
	if I.SharedRay.version > MY_VERSION then
		return
	end

	local cameraPos = camera.getPosition()
	local defaultMax = iMaxActivateDist + camera.getThirdPersonDistance()

	local telekinesis = activeEffects:getEffect(TELEKINESIS)
	if telekinesis then
		defaultMax = defaultMax + telekinesis.magnitude * 22
	end

	-- requests ride the next cast, delivery always lands before the following onFrame
	if pendingRequests then
		inFlightRequests = pendingRequests
		pendingRequests = nil
	end

	-- Single cast at the longest requested distance
	local rayLen = math.max(defaultMax, requestedDist)
	if inFlightRequests then
		for i = 1, #inFlightRequests do
			local dist = inFlightRequests[i].dist
			if dist > rayLen then
				rayLen = dist
			end
		end
	end

	firedPos = cameraPos
	firedMax = defaultMax
	local endPos = cameraPos + getCameraVector() * rayLen
	if syncRequested then
		processRay(nearby.castRenderingRay(cameraPos, endPos, rayOptions))
	else
		nearby.asyncCastRenderingRay(rayCallback, cameraPos, endPos, rayOptions)
	end
end

local function get()
	return cachedResult
end

local function getUnclipped()
	return cachedUnclipped
end

local function request(dist, callback)
	if not pendingRequests then
		pendingRequests = {}
	end
	pendingRequests[#pendingRequests + 1] = {
		dist = dist,
		callback = callback,
	}
end

local function subscribe(key, callback)
	subscribers[key] = callback
end

local function requestDistance(dist)
	if dist > requestedDist then
		requestedDist = dist
	end
end

local function getRequestedDistance()
	return requestedDist
end

local function requestSynchronous()
	syncRequested = true
end

local function isSynchronous()
	return syncRequested
end

local function setRayType(func)
	-- deprecated no-op, allowing changing it to a physics ray was a bad idea
end

return {
	interfaceName = "SharedRay",
	interface = {
		version = MY_VERSION,
		get = get,
		getUnclipped = getUnclipped,
		request = request,
		subscribe = subscribe,
		requestDistance = requestDistance,
		getRequestedDistance = getRequestedDistance,
		requestSynchronous = requestSynchronous,
		isSynchronous = isSynchronous,
		setRayType = setRayType,
	},
	engineHandlers = {
		onFrame = onFrame,
	},
}
