NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Location
local locationTypes = NightShift.Enums and NightShift.Enums.LocationTypes or {}

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function errorResult(code, message, details)
    return Result.err(code, message, details)
end

local function unwrap(value)
    if type(value) ~= 'table' then return value end
    if value.ok == false then return nil, value end
    if value.ok == true then return value.value end
    return value
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return value end
    end
    return os.time()
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function normalizedTags(values)
    local output = {}
    if type(values) ~= 'table' then return output end
    for _, value in ipairs(values) do
        if type(value) == 'string' then output[value:upper()] = true end
    end
    return output
end

local function hasIntersection(left, right)
    left, right = normalizedTags(left), normalizedTags(right)
    for tag in pairs(left) do if right[tag] then return true, tag end end
    return false
end

local function validateTarget(target)
    if type(target) ~= 'table' or tostring(target.kind or 'coords'):lower() ~= 'coords' then return nil end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local limit = axis == 'z' and 10000 or 100000
        if not finite(tonumber(target[axis])) or math.abs(tonumber(target[axis])) > limit then return nil end
    end
    if target.heading ~= nil and (not finite(tonumber(target.heading)) or math.abs(tonumber(target.heading)) > 360) then return nil end
    return copy(target)
end

local providerTypes = { MOTEL_ROOM='motel', HOTEL_ROOM='motel', PROPERTY='housing', VENUE_ROOM='venue', CUSTOM_PROVIDER=nil }

function Service.new(options)
    options = options or {}
    local locations = options.locations or options.config or {}
    if type(locations) ~= 'table' then return nil, errorResult(Codes.LOCATION_INVALID, 'location service definitions must be a table') end
    local byRef = {}
    for _, value in ipairs(locations) do
        local location, errorResultValue = Domain.new(value)
        if not location then return nil, errorResultValue end
        if byRef[location.locationRef] then return nil, errorResult(Codes.LOCATION_INVALID, 'duplicate location reference', { locationRef = location.locationRef }) end
        byRef[location.locationRef] = location
    end
    local providers = options.providers or options.providerMap or {}
    if type(providers) == 'table' and type(providers.optional) == 'table' then providers = providers.optional end
    return setmetatable({
        _locations = byRef,
        _repository = options.repository or options.locationRepository,
        _providers = providers,
        _clock = options.clock,
        _accessCheck = options.accessCheck or options.authorize,
        _zoneCheck = options.zoneCheck or options.isAllowedZone,
        _interiorCheck = options.interiorCheck or options.isValidInterior,
        _waterCheck = options.waterCheck,
        _routeCheck = options.routeCheck,
        _vehicleService = options.vehicleService
    }, Service)
end

function Service:get(locationRef)
    if not token(locationRef, 160) then return nil end
    local location = self._locations[locationRef]
    if location then return location:copy() end
    if type(self._repository) == 'table' and type(self._repository.findByRef) == 'function' then
        local result = self._repository:findByRef(locationRef)
        if type(result) == 'table' and result.ok and type(result.value) == 'table' then
            if type(result.value.copy) == 'function' then return result.value:copy() end
            local value, errorResult = Domain.new(result.value)
            if value then return value end
            return nil
        end
    end
    return nil
end

function Service:list(options)
    options = options or {}
    local output = {}
    for _, location in pairs(self._locations) do
        if options.locationType == nil or tostring(options.locationType):upper() == location.locationType then
            if options.available ~= true or location.available then output[#output + 1] = location:copy() end
        end
    end
    table.sort(output, function(left, right) return left.locationRef < right.locationRef end)
    return Result.ok(output)
end

local function checkAccess(self, source, location)
    local requirements = location.accessRequirements or {}
    if next(requirements) == nil then return true end
    if requirements.public == true and requirements.owner ~= true and requirements.permission == nil and requirements.ace == nil and requirements.minGrade == nil then return true end
    if type(self._accessCheck) ~= 'function' then return requirements.public == true
    end
    local result = call(self._accessCheck, source, location:copy(), copy(requirements))
    if type(result) == 'table' and result.ok ~= nil then
        return result.ok == true and (result.value == nil or result.value == true or result.value.allowed == true)
    end
    return result == true
end

local function providerFor(self, locationType, location)
    local name = location and location.provider or providerTypes[locationType]
    if not text(name, 64) then return nil end
    return self._providers[name] or self._providers[tostring(name):lower()] or self._providers[tostring(name):upper()]
end

function Service:_providerLocation(source, locationType, locationRef, request)
    local providerName = request.provider or providerTypes[locationType]
    local provider = providerFor(self, locationType, request)
    if not provider then return nil, errorResult(Codes.LOCATION_NOT_FOUND, 'location provider is not configured', { locationType = locationType }) end
    local validate = provider.validate
    local methodStyle = true
    if type(validate) ~= 'function' then validate, methodStyle = provider.validateRoom, false end
    if type(validate) ~= 'function' then return nil, errorResult(Codes.LOCATION_NOT_FOUND, 'location provider cannot validate the reference') end
    local validated = methodStyle and call(validate, provider, source, locationRef, copy(request)) or call(validate, source, locationRef, copy(request))
    local validation, validationError = unwrap(validated)
    if validationError then return nil, validationError end
    if validated == nil or validation == nil or validated == false or validation == false or type(validation) == 'table' and validation.valid == false then
        return nil, errorResult(Codes.LOCATION_NOT_FOUND, 'location reference is not registered by the provider', { locationRef = locationRef })
    end
    local target
    if type(provider.resolveWorldTarget) == 'function' then
        local resolved = call(provider.resolveWorldTarget, provider, locationRef, copy(request))
        local targetValue, targetError = unwrap(resolved)
        if targetError then return nil, targetError end
        target = type(targetValue) == 'table' and (targetValue.worldTarget or targetValue.world_target or targetValue) or nil
    end
    if target == nil and type(validation) == 'table' then target = validation.worldTarget or validation.world_target or validation.coords end
    local value = {
        id = locationRef,
        locationRef = locationRef,
        locationType = locationType,
        type = locationType,
        category = request.category or ({ MOTEL_ROOM = 'motel', HOTEL_ROOM = 'motel', PROPERTY = 'housing', VENUE_ROOM = 'venue', SAFE_ROADSIDE = 'roadside', CUSTOM_PROVIDER = 'custom' })[locationType] or 'configured',
        provider = providerName,
        accessRequirements = request.accessRequirements or {},
        meetingModes = request.meetingModes or { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' },
        blockedTags = request.blockedTags or {},
        maxTravelDistance = request.maxTravelDistance,
        available = true,
        reservable = request.reservable ~= false,
        worldTarget = target
    }
    local location, locationError = Domain.new(value)
    if not location then return nil, locationError end
    return location
end

function Service:_validateRegisteredProvider(source, location, request)
    if not location.provider then return true end
    local provider = providerFor(self, location.locationType, location)
    -- Registered locations remain resolvable from their server-owned descriptor
    -- when an optional provider is offline; the provider is consulted when it
    -- is available and provider-backed references (without a descriptor) still
    -- fail closed in _providerLocation.
    if not provider then return true end
    local validate = provider.validate
    local methodStyle = true
    if type(validate) ~= 'function' then validate, methodStyle = provider.validateRoom, false end
    if type(validate) == 'function' then
        local validated = methodStyle and call(validate, provider, source, location.locationRef, copy(request)) or call(validate, source, location.locationRef, copy(request))
        local validation, validationError = unwrap(validated)
        if validationError then return validationError end
        if validated == nil or validation == nil or validated == false or validation == false or type(validation) == 'table' and validation.valid == false then
            return errorResult(Codes.LOCATION_NOT_FOUND, 'provider rejected the registered location', { locationRef = location.locationRef })
        end
    end
    if type(provider.resolveWorldTarget) == 'function' then
        local resolved = call(provider.resolveWorldTarget, provider, location.locationRef, copy(request))
        local targetValue, targetError = unwrap(resolved)
        if targetError then return targetError end
        local target = type(targetValue) == 'table' and (targetValue.worldTarget or targetValue.world_target or targetValue) or nil
        if target ~= nil then location.worldTarget = target end
    end
    return true
end

function Service:resolve(source, request)
    if type(request) ~= 'table' then return errorResult(Codes.LOCATION_INVALID, 'location request must be a table') end
    local locationType = request.locationType or request.type
    local locationRef = request.locationRef or request.ref or request.locationId
    if type(locationType) ~= 'string' then return errorResult(Codes.LOCATION_INVALID, 'typed location type is required') end
    locationType = locationType:upper()
    if locationType == 'CONFIGURED' then locationType = 'CONFIG_LOCATION' end
    if not locationTypes[locationType] then return errorResult(Codes.LOCATION_INVALID, 'location type is not supported', { locationType = locationType }) end
    if locationType == 'VEHICLE' and self._vehicleService then
        return self._vehicleService:resolve(source, request)
    end
    if type(locationRef) ~= 'string' or not token(locationRef, 160) then
        return errorResult(Codes.LOCATION_INVALID, 'typed location reference is required')
    end
    local location
    location = self:get(locationRef)
    if location and location.locationType ~= locationType then
        return errorResult(Codes.LOCATION_INCOMPATIBLE, 'location type does not match the registered reference', { expected = location.locationType, actual = locationType })
    end
    if not location then
        local providerLocation, providerError = self:_providerLocation(source, locationType, locationRef, request)
        if not providerLocation then return providerError end
        location = providerLocation
    else
        local providerResult = self:_validateRegisteredProvider(source, location, request)
        if providerResult ~= true then return providerResult end
    end
    if not location.available then return errorResult(Codes.LOCATION_UNAVAILABLE, 'location is not currently available', { locationRef = locationRef }) end
    local meetingMode = request.meetingMode or request.mode
    if meetingMode ~= nil then
        meetingMode = tostring(meetingMode):upper()
        local supported = #location.meetingModes == 0
        for _, mode in ipairs(location.meetingModes) do if mode == meetingMode then supported = true; break end end
        if not supported then return errorResult(Codes.LOCATION_INCOMPATIBLE, 'location does not support the requested meeting mode', { locationRef = locationRef, meetingMode = meetingMode }) end
    end
    local blocked, blockedTag = hasIntersection(request.zoneTags or request.tags, location.blockedTags)
    if blocked then return errorResult(Codes.LOCATION_BLOCKED, 'location is in a blocked or restricted zone', { tag = blockedTag }) end
    if not checkAccess(self, source, location) then return errorResult(Codes.LOCATION_ACCESS_DENIED, 'player is not authorized for this location', { locationRef = locationRef }) end
    local target = validateTarget(location.worldTarget)
    if not target then return errorResult(Codes.LOCATION_TARGET_INVALID, 'location has no safe world target', { locationRef = locationRef }) end
    if type(self._zoneCheck) == 'function' then
        local zoneResult = call(self._zoneCheck, source, target, location:copy())
        if zoneResult == nil then return errorResult(Codes.LOCATION_BLOCKED, 'location zone validation was unavailable') end
        if not (zoneResult == true or type(zoneResult) == 'table' and (zoneResult.allowed == true or zoneResult.ok == true and (zoneResult.value == nil or zoneResult.value == true or zoneResult.value.allowed == true))) then
            return errorResult(Codes.LOCATION_BLOCKED, 'location is outside an allowed meeting zone', { locationRef = locationRef })
        end
    end
    if location.locationType == 'PROPERTY' and type(self._interiorCheck) == 'function' then
        local interiorResult = call(self._interiorCheck, source, location:copy(), target)
        if interiorResult == nil or not (interiorResult == true or type(interiorResult) == 'table' and (interiorResult.allowed == true or interiorResult.valid == true or interiorResult.ok == true and interiorResult.value == true)) then
            return errorResult(Codes.LOCATION_TARGET_INVALID, 'property interior is not valid', { locationRef = locationRef })
        end
    end
    local water = call(self._waterCheck, target, source, location:copy())
    if type(self._waterCheck) == 'function' and water == nil then
        return errorResult(Codes.LOCATION_TARGET_INVALID, 'location water-safety check was unavailable')
    end
    if water == true or type(water) == 'table' and water.ok == true and water.value == true then
        return errorResult(Codes.LOCATION_TARGET_INVALID, 'location world target is not safe for meeting')
    end
    local route
    if type(self._routeCheck) == 'function' then
        local routeResult = call(self._routeCheck, source, target, location:copy())
        if routeResult == nil then return errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'route feasibility check was unavailable') end
        local routeValue, routeError = unwrap(routeResult)
        if routeError then return errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'route feasibility check failed', { cause = routeError.error and routeError.error.code }) end
        if type(routeValue) ~= 'table' then return errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'route feasibility check returned an invalid hint') end
        route = routeValue
        if route.reachable ~= nil and type(route.reachable) ~= 'boolean' then return errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'route feasibility hint is invalid') end
        if route.reachable == false then return errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'location route is not feasible') end
        if location.maxTravelDistance and tonumber(route.distance) and tonumber(route.distance) > location.maxTravelDistance then
            return errorResult(Codes.LOCATION_INCOMPATIBLE, 'location exceeds the maximum travel distance', { distance = route.distance, maximum = location.maxTravelDistance })
        end
    end
    local value = location:copy()
    value.worldTarget, value.route, value.meetingMode, value.resolvedAt = target, copy(route), meetingMode, now(self._clock)
    value.location = location:copy()
    return Result.ok(value)
end

Service.resolveLocation = Service.resolve
NightShift.LocationService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.Location = Service
