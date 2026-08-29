NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Location = NightShift.Domain.Location

local Service = {}
Service.__index = Service
local meetingModes = { COME_TO_ME = true, PICKUP = true, MEET_THERE = true }
local activeBookingStates = { ACCEPTED=true, RESERVED=true, TRAVELLING=true, ARRIVED=true, ACTIVE=true, OFFERED=true }

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function validId(value)
    if type(value) == 'number' then return value == value and value > 0 and value ~= math.huge and value ~= -math.huge and math.floor(value) == value end
    return type(value) == 'string' and value:match('^[A-Za-z0-9_.%-]+$') ~= nil and #value <= 96
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function errorResult(code, message, details)
    return Result.err(code, message, details)
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function allowed(result)
    if type(result) == 'table' and result.ok ~= nil then
        return result.ok == true and (result.value == nil or result.value == true or result.value.allowed == true)
    end
    return result == true
end

local function coords(vehicle)
    local value = vehicle.coords or vehicle.position or vehicle.location
    if type(value) ~= 'table' then return nil end
    local target = { kind = 'coords', x = tonumber(value.x), y = tonumber(value.y), z = tonumber(value.z) }
    if value.heading ~= nil then target.heading = tonumber(value.heading) end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local limit = axis == 'z' and 10000 or 100000
        if not finite(target[axis]) or math.abs(target[axis]) > limit then return nil end
    end
    if target.heading ~= nil and (not finite(target.heading) or math.abs(target.heading) > 360) then return nil end
    return target
end

function Service.new(options)
    options = options or {}
    local getVehicle = options.getVehicle or options.vehicleResolver
    if type(getVehicle) ~= 'function' then return nil, errorResult(Codes.VEHICLE_INVALID, 'vehicle location service requires a server vehicle lookup') end
    local maxSpeed = tonumber(options.maxSpeed or options.maxStationarySpeed or 0.5)
    if not finite(maxSpeed) or maxSpeed < 0 or maxSpeed > 100 then return nil, errorResult(Codes.VEHICLE_INVALID, 'vehicle stationary speed threshold is invalid') end
    return setmetatable({
        _getVehicle = getVehicle,
        _hasAccess = options.hasAccess or options.accessCheck,
        _allowedZone = options.isAllowedZone or options.zoneCheck,
        _waterCheck = options.waterCheck,
        _bookingLookup = options.bookingLookup,
        _npcNearby = options.npcNearby or options.isNpcNearby,
        _assignmentCheck = options.assignmentCheck or options.isAssigned,
        _clock = options.clock,
        _maxSpeed = maxSpeed,
        _requirePrivate = options.requirePrivate ~= false
    }, Service)
end

function Service:resolve(source, request)
    if type(request) ~= 'table' or not validId(request.vehicleId or request.vehicleRef or request.id) then
        return errorResult(Codes.VEHICLE_INVALID, 'a server-visible vehicle ID is required')
    end
    local vehicleId = request.vehicleId or request.vehicleRef or request.id
    if request.meetingMode ~= nil and not meetingModes[tostring(request.meetingMode):upper()] then
        return errorResult(Codes.LOCATION_INCOMPATIBLE, 'vehicle does not support the requested meeting mode')
    end
    local vehicle = call(self._getVehicle, vehicleId, source)
    if type(vehicle) ~= 'table' or vehicle.serverVisible == false or vehicle.exists == false then
        return errorResult(Codes.VEHICLE_NOT_FOUND, 'vehicle is not server-visible', { vehicleId = vehicleId })
    end
    if type(self._hasAccess) == 'function' then
        if not allowed(call(self._hasAccess, source, vehicle)) then
            return errorResult(Codes.VEHICLE_ACCESS_DENIED, 'player cannot access this vehicle', { vehicleId = vehicleId })
        end
    elseif vehicle.ownerSource ~= nil and tostring(vehicle.ownerSource) ~= tostring(source) then
        return errorResult(Codes.VEHICLE_ACCESS_DENIED, 'player cannot access this vehicle', { vehicleId = vehicleId })
    elseif vehicle.ownerSource == nil then
        return errorResult(Codes.VEHICLE_ACCESS_DENIED, 'vehicle access cannot be verified', { vehicleId = vehicleId })
    end
    local speed = tonumber(vehicle.speed or vehicle.velocity or vehicle.speedMps or 0)
    if not finite(speed) or speed < 0 then return errorResult(Codes.VEHICLE_INVALID, 'vehicle speed is invalid') end
    if speed > self._maxSpeed then return errorResult(Codes.LOCATION_INCOMPATIBLE, 'vehicle must be stationary before booking') end
    if self._requirePrivate and vehicle.private ~= true and vehicle.isPrivate ~= true then
        return errorResult(Codes.LOCATION_INCOMPATIBLE, 'vehicle is not a private vehicle') end
    if type(self._allowedZone) == 'function' and not allowed(call(self._allowedZone, source, vehicle)) then
        return errorResult(Codes.LOCATION_BLOCKED, 'vehicle is outside an allowed meeting zone', { vehicleId = vehicleId })
    end
    local target = coords(vehicle)
    if not target then return errorResult(Codes.LOCATION_TARGET_INVALID, 'vehicle has no safe server position') end
    local water = call(self._waterCheck, target, source, vehicle)
    if type(self._waterCheck) == 'function' and water == nil then
        return errorResult(Codes.LOCATION_TARGET_INVALID, 'vehicle water-safety check was unavailable')
    end
    if type(water) == 'table' and water.ok == false then
        return errorResult(Codes.LOCATION_TARGET_INVALID, 'vehicle water-safety check failed')
    end
    if water == true or type(water) == 'table' and water.ok == true and water.value == true then
        return errorResult(Codes.LOCATION_TARGET_INVALID, 'vehicle position is not safe for a meeting')
    end
    if request.bookingId ~= nil and type(self._bookingLookup) == 'function' then
        local booking = call(self._bookingLookup, request.bookingId, source)
        if type(booking) == 'table' and booking.ok ~= nil then booking = booking.ok and booking.value or nil end
        if type(booking) ~= 'table' or not activeBookingStates[tostring(booking.status or ''):upper()] then
            return errorResult(Codes.VEHICLE_INVALID, 'vehicle location booking binding is invalid')
        end
        if type(self._assignmentCheck) == 'function' and not allowed(call(self._assignmentCheck, source, vehicle, booking)) then
            return errorResult(Codes.VEHICLE_ACCESS_DENIED, 'vehicle is not assigned to the booking')
        end
        if type(self._npcNearby) == 'function' and not allowed(call(self._npcNearby, source, vehicle, booking)) then
            return errorResult(Codes.LOCATION_INCOMPATIBLE, 'assigned NPC is not nearby the vehicle')
        end
    elseif request.bookingId ~= nil then
        return errorResult(Codes.VEHICLE_INVALID, 'vehicle location booking binding cannot be verified')
    end
    local location, locationError = Location.new({
        id = 'vehicle:' .. tostring(vehicleId),
        type = 'VEHICLE',
        category = 'vehicle',
        worldTarget = target,
        accessRequirements = { public = true },
        meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' },
        available = true,
        reservable = true
    })
    if not location then return locationError end
    local value = location:copy()
    value.vehicleId = vehicleId
    value.vehicleHandle = vehicle.serverHandle or vehicle.handle or vehicle.netId
    value.vehicle = { id = vehicle.id or vehicleId, serverVisible = true }
    value.worldTarget = target
    value.resolvedAt = type(self._clock) == 'table' and type(self._clock.now) == 'function' and self._clock:now() or os.time()
    value.location = location:copy()
    return Result.ok(value)
end

Service.resolveLocation = Service.resolve
NightShift.VehicleLocationService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.VehicleLocation = Service
