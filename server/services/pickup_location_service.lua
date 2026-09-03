NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Location = NightShift.Domain and NightShift.Domain.Location

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
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    return os.time()
end

local function errorResult(code, message, details)
    return Result.err(code, message, details)
end

local function unwrap(value, fallback)
    if type(value) ~= 'table' then
        return nil, errorResult(fallback or Codes.PICKUP_LOCATION_INVALID, 'pickup resolver returned an invalid result')
    end
    if value.ok == false then return nil, value end
    if value.ok == true then return value.value or value.data end
    if value.success == true then return value.value or value.data end
    return value
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return nil, false end
    local ok, value = pcall(fn, ...)
    return value, ok
end

local function allowed(value)
    if type(value) == 'table' and value.ok ~= nil then
        return value.ok == true and (value.value == nil or value.value == true or value.value.allowed == true)
    end
    return value == true
end

local function normalizeTarget(value)
    if type(value) ~= 'table' then return nil end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' then return nil end
    local output = { kind = kind }
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local coordinate = tonumber(value[axis])
        local limit = axis == 'z' and 10000 or 100000
        if not finite(coordinate) or math.abs(coordinate) > limit then return nil end
        output[axis] = coordinate
    end
    if value.heading ~= nil then
        local heading = tonumber(value.heading)
        if not finite(heading) or math.abs(heading) > 360 then return nil end
        output.heading = heading
    end
    return output
end

local function targetOf(value)
    if type(value) ~= 'table' then return nil end
    return normalizeTarget(value.worldTarget or value.target or value.position or value.coords or value)
end

local function distance(left, right)
    if type(left) ~= 'table' or type(right) ~= 'table' then return nil end
    if not finite(left.x) or not finite(left.y) or not finite(left.z) or
        not finite(right.x) or not finite(right.y) or not finite(right.z) then return nil end
    return math.sqrt((left.x - right.x) ^ 2 + (left.y - right.y) ^ 2 + (left.z - right.z) ^ 2)
end

local function normalizeCandidate(raw, index)
    if type(raw) ~= 'table' then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate must be a table', { index = index })
    end
    local allowedFields = {
        id = true, locationRef = true, location_ref = true, ref = true, district = true,
        locationType = true, type = true, worldTarget = true, world_target = true,
        coords = true, position = true, priority = true, available = true, reservable = true,
        roadSuitable = true, road_suitable = true, navSuitable = true, nav_suitable = true,
        blocked = true, blockedTags = true, blocked_tags = true, minDistance = true,
        maxDistance = true, distanceFromDestination = true, distance = true
    }
    for key in pairs(raw) do
        if not allowedFields[key] then
            return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate field is not allowlisted', { field = tostring(key) })
        end
    end
    local locationRef = raw.locationRef or raw.location_ref or raw.ref or raw.id
    if not token(locationRef, 160) then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate requires a server location reference', { index = index })
    end
    local district = raw.district
    if district ~= nil then
        if not token(tostring(district), 64) then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate district is invalid') end
        district = tostring(district):lower()
    end
    local locationType = tostring(raw.locationType or raw.type or 'SAFE_ROADSIDE'):upper()
    if not (NightShift.Enums and NightShift.Enums.LocationTypes and NightShift.Enums.LocationTypes[locationType]) then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate location type is invalid')
    end
    local target = normalizeTarget(raw.worldTarget or raw.world_target or raw.coords or raw.position)
    if raw.worldTarget ~= nil or raw.world_target ~= nil or raw.coords ~= nil or raw.position ~= nil then
        if not target then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate world target is invalid', { locationRef = locationRef }) end
    end
    local priority = integer(raw.priority == nil and 100 or raw.priority, 0, 1000000)
    if priority == nil then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate priority is invalid') end
    local output = {
        locationRef = tostring(locationRef), district = district, locationType = locationType,
        worldTarget = target, priority = priority,
        available = raw.available == nil and true or raw.available == true,
        reservable = raw.reservable == nil and true or raw.reservable == true,
        roadSuitable = raw.roadSuitable == nil and raw.road_suitable or raw.roadSuitable,
        navSuitable = raw.navSuitable == nil and raw.nav_suitable or raw.navSuitable,
        blocked = raw.blocked == true,
        blockedTags = copy(raw.blockedTags or raw.blocked_tags or {}),
        minDistance = raw.minDistance, maxDistance = raw.maxDistance,
        distanceFromDestination = raw.distanceFromDestination or raw.distance
    }
    for _, key in ipairs({ 'minDistance', 'maxDistance', 'distanceFromDestination' }) do
        if output[key] ~= nil then
            output[key] = tonumber(output[key])
            if not finite(output[key]) or output[key] < 0 or output[key] > 100000 then
                return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate distance is invalid', { field = key })
            end
        end
    end
    if output.roadSuitable ~= nil and type(output.roadSuitable) ~= 'boolean' then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate road suitability is invalid')
    end
    if output.navSuitable ~= nil and type(output.navSuitable) ~= 'boolean' then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate navigation suitability is invalid')
    end
    return output
end

local function normalizeBookingId(value)
    if integer(value, 1, 2147483647) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, errorResult(Codes.PICKUP_INVALID, 'pickup location options must be a table') end
    local source = options.candidates or options.candidatePool or options.locations or NightShift.PickupLocationConfig or {}
    if type(source) ~= 'table' then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate pool must be a table') end
    local candidates, byRef = {}, {}
    for index, raw in ipairs(source) do
        local candidate, candidateError = normalizeCandidate(raw, index)
        if not candidate then return nil, candidateError end
        if byRef[candidate.locationRef] then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate reference is duplicated', { locationRef = candidate.locationRef }) end
        byRef[candidate.locationRef] = candidate
        candidates[#candidates + 1] = candidate
    end
    if #candidates == 0 then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate pool is empty') end
    local minimum = tonumber(options.minDistance or options.minimumDistance or 0)
    local maximum = tonumber(options.maxDistance or options.maximumDistance or 5000)
    if not finite(minimum) or minimum < 0 or not finite(maximum) or maximum <= 0 or minimum > maximum then
        return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup distance bounds are invalid')
    end
    local ttl = integer(options.reservationTtlSeconds or options.defaultTtl or 900, 1, 86400)
    if not ttl then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup reservation TTL is invalid') end
    table.sort(candidates, function(left, right)
        if left.priority == right.priority then return left.locationRef < right.locationRef end
        return left.priority < right.priority
    end)
    return setmetatable({
        _candidates = candidates, _byRef = byRef,
        _resolver = options.locationService or options.locationResolver,
        _reservation = options.locationReservationService or options.locationReservation,
        _clock = options.clock, _routeCheck = options.routeCheck or options.navCheck or options.roadCheck,
        _blockedCheck = options.blockedZoneCheck or options.zoneCheck or options.isBlocked,
        _bookingLookup = options.bookingLookup,
        _minimumDistance = minimum, _maximumDistance = maximum, _defaultTtl = ttl,
        _reservations = {}, _byLocation = {}
    }, Service)
end

function Service:_bookingDestination(request)
    local destination = request.destination or request.destinationLocation or request.destinationTarget
    return targetOf(destination)
end

function Service:_resolveServerLocation(source, candidate, request)
    local resolver = self._resolver
    if resolver ~= nil then
        local ok, value
        if type(resolver) == 'table' and type(resolver.resolve) == 'function' then
            ok, value = pcall(resolver.resolve, resolver, source, {
                locationType = candidate.locationType, locationRef = candidate.locationRef,
                meetingMode = 'PICKUP'
            })
        elseif type(resolver) == 'function' then
            ok, value = pcall(resolver, source, {
                locationType = candidate.locationType, locationRef = candidate.locationRef,
                meetingMode = 'PICKUP'
            })
        end
        if not ok then return nil, errorResult(Codes.PICKUP_LOCATION_UNAVAILABLE, 'pickup location resolver failed') end
        local resolved, resolveError = unwrap(value, Codes.PICKUP_LOCATION_UNAVAILABLE)
        if not resolved then return nil, resolveError end
        local location = resolved.location or resolved
        if type(location) ~= 'table' or tostring(location.locationRef or location.ref or '') ~= candidate.locationRef then
            return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup resolver returned a mismatched location')
        end
        local target = normalizeTarget(location.worldTarget or location.target)
        if not target then return nil, errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup resolver returned no safe target') end
        local output = copy(location)
        output.locationRef = candidate.locationRef
        output.locationType = tostring(location.locationType or candidate.locationType):upper()
        output.type = output.locationType
        output.worldTarget = target
        output.meetingMode = 'PICKUP'
        return output
    end
    if not candidate.worldTarget then return nil, errorResult(Codes.PICKUP_LOCATION_UNAVAILABLE, 'pickup candidate has no server target') end
    if type(Location) ~= 'table' or type(Location.new) ~= 'function' then
        return nil, errorResult(Codes.PICKUP_LOCATION_UNAVAILABLE, 'location domain is unavailable')
    end
    local location, locationError = Location.new({
        id = candidate.locationRef, type = candidate.locationType, category = 'roadside',
        worldTarget = candidate.worldTarget, accessRequirements = { public = true },
        meetingModes = { 'PICKUP' }, available = candidate.available, reservable = candidate.reservable
    })
    if not location then return nil, locationError end
    local output = location:copy()
    output.meetingMode = 'PICKUP'
    return output
end

function Service:_candidateAllowed(source, candidate, request, destination)
    if not candidate.available or not candidate.reservable or candidate.blocked then return false end
    if candidate.roadSuitable == false or candidate.navSuitable == false then return false end
    if type(self._blockedCheck) == 'function' then
        local result, ok = call(self._blockedCheck, source, copy(candidate), copy(request))
        if not ok or result == nil then return nil, errorResult(Codes.PICKUP_LOCATION_BLOCKED, 'pickup blocked-zone verifier is unavailable') end
        if not allowed(result) then return false end
    end
    if type(self._routeCheck) == 'function' then
        local result, ok = call(self._routeCheck, source, copy(candidate), copy(request), copy(destination))
        if not ok or result == nil then return nil, errorResult(Codes.LOCATION_ROUTE_UNAVAILABLE, 'pickup road/nav verifier is unavailable') end
        if type(result) == 'table' and result.ok == false then return false end
        if type(result) == 'table' and result.ok == true then result = result.value end
        if result == false or type(result) == 'table' and (result.reachable == false or result.allowed == false) then return false end
    end
    local candidateDistance = candidate.distanceFromDestination
    if candidateDistance == nil then candidateDistance = distance(candidate.worldTarget, destination) end
    local minimum = candidate.minDistance == nil and self._minimumDistance or candidate.minDistance
    local maximum = candidate.maxDistance == nil and self._maximumDistance or candidate.maxDistance
    if candidateDistance ~= nil and (candidateDistance < minimum or candidateDistance > maximum) then return false end
    return true
end

function Service:resolve(source, request)
    if type(request) ~= 'table' then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup location request must be a table') end
    for key in pairs(request) do
        if key == 'coords' or key == 'worldTarget' or key == 'world_target' or key == 'x' or key == 'y' or key == 'z' or key == 'heading' then
            return errorResult(Codes.PICKUP_LOCATION_INVALID, 'client coordinates cannot select a pickup point')
        end
        local allowedFields = { bookingId = true, district = true, candidateRef = true, locationRef = true, destination = true, destinationLocation = true, destinationTarget = true, zoneTags = true, tags = true }
        if not allowedFields[key] then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup request field is not allowlisted', { field = tostring(key) }) end
    end
    local bookingId = request.bookingId and normalizeBookingId(request.bookingId) or nil
    if request.bookingId ~= nil and not bookingId then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup booking ID is invalid') end
    if bookingId and self._reservations[bookingId] then return Result.ok(copy(self._reservations[bookingId]), { idempotent = true, serverAuthoritative = true }) end
    local district = request.district
    if district ~= nil and not token(tostring(district), 64) then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup district is invalid') end
    district = district and tostring(district):lower() or nil
    local requestedRef = request.candidateRef or request.locationRef
    if requestedRef ~= nil and not token(tostring(requestedRef), 160) then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup candidate reference is invalid') end
    local destination = self:_bookingDestination(request)
    local lastError
    for _, candidate in ipairs(self._candidates) do
        if (not district or candidate.district == district) and (not requestedRef or candidate.locationRef == requestedRef) then
            local eligible, eligibilityError = self:_candidateAllowed(source, candidate, request, destination)
            if eligibilityError then lastError = eligibilityError
            elseif eligible then
                local location, locationError = self:_resolveServerLocation(source, candidate, request)
                if location then
                    local value = {
                        serverGenerated = true, district = candidate.district, locationType = candidate.locationType,
                        locationRef = candidate.locationRef, candidate = copy(candidate), location = copy(location),
                        worldTarget = copy(location.worldTarget), resolvedAt = now(self._clock)
                    }
                    return Result.ok(value, { serverAuthoritative = true })
                end
                lastError = locationError
            end
        end
    end
    if lastError then return lastError end
    if requestedRef and not self._byRef[requestedRef] then
        return errorResult(Codes.PICKUP_LOCATION_INVALID, 'requested pickup candidate is not in the server pool')
    end
    return errorResult(Codes.PICKUP_LOCATION_UNAVAILABLE, 'no safe pickup location is available', { district = district })
end

function Service:reserve(bookingId, request, context)
    local id = normalizeBookingId(bookingId)
    if not id then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup reservation booking ID is invalid') end
    if self._reservations[id] then
        return Result.ok(copy(self._reservations[id]), { idempotent = true, serverAuthoritative = true })
    end
    request = copy(request or {})
    local ttlSeconds = request.ttlSeconds
    request.ttlSeconds = nil
    request.bookingId = id
    local resolved, resolveError = self:resolve(context and context.source, request)
    if not resolved.ok then return resolved end
    local selected = resolved.value
    local existingBooking = self._byLocation[selected.locationRef]
    if existingBooking and existingBooking ~= id then
        return errorResult(Codes.PICKUP_LOCATION_CONFLICT, 'pickup location is already reserved', { locationRef = selected.locationRef })
    end
    local externalReservation
    if self._reservation and type(self._reservation.reserve) == 'function' then
        local result, ok = call(self._reservation.reserve, self._reservation, id, {
            locationType = selected.locationType, locationRef = selected.locationRef,
            meetingMode = 'PICKUP', ttlSeconds = tonumber(ttlSeconds) or self._defaultTtl
        }, context)
        if not ok or type(result) ~= 'table' then return errorResult(Codes.PICKUP_LOCATION_UNAVAILABLE, 'pickup reservation service failed') end
        externalReservation, resolveError = unwrap(result, Codes.PICKUP_LOCATION_UNAVAILABLE)
        if not externalReservation then return resolveError end
    end
    local reservation = {
        reservationKey = externalReservation and (externalReservation.reservationKey or externalReservation.key or externalReservation.id)
            or ('pickup:' .. selected.locationRef .. ':' .. id),
        bookingId = id, locationRef = selected.locationRef, locationType = selected.locationType,
        status = 'RESERVED', holdUntil = now(self._clock) + (tonumber(ttlSeconds) or self._defaultTtl),
        pickup = copy(selected), location = copy(selected.location), external = copy(externalReservation),
        serverGenerated = true
    }
    self._reservations[id], self._byLocation[selected.locationRef] = reservation, id
    return Result.ok(copy(reservation), { created = true, serverAuthoritative = true })
end

function Service:get(bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup booking ID is invalid') end
    local reservation = self._reservations[id]
    if not reservation then return Result.err(Codes.PICKUP_LOCATION_UNAVAILABLE, 'pickup location reservation was not found') end
    return Result.ok(copy(reservation))
end

function Service:occupy(bookingId)
    local id = normalizeBookingId(bookingId)
    local reservation = id and self._reservations[id]
    if not reservation then return Result.err(Codes.PICKUP_LOCATION_UNAVAILABLE, 'pickup location reservation was not found') end
    if reservation.status == 'OCCUPIED' then return Result.ok(copy(reservation), { idempotent = true }) end
    reservation.status = 'OCCUPIED'
    return Result.ok(copy(reservation))
end

function Service:release(bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return errorResult(Codes.PICKUP_LOCATION_INVALID, 'pickup booking ID is invalid') end
    local reservation = self._reservations[id]
    if not reservation then return Result.ok({ bookingId = id, status = 'RELEASED' }, { idempotent = true }) end
    if self._reservation and type(self._reservation.release) == 'function' and reservation.external then
        pcall(self._reservation.release, self._reservation, id, reservation.external.reservationKey or reservation.external.key or reservation.external.id)
    end
    self._reservations[id], self._byLocation[reservation.locationRef] = nil, nil
    return Result.ok({ bookingId = id, locationRef = reservation.locationRef, status = 'RELEASED' })
end

Service.resolvePickup = Service.resolve
Service.select = Service.resolve
Service.reservePickup = Service.reserve
Service.releasePickup = Service.release

NightShift.PickupLocationService = Service
NightShift.Services.PickupLocation = Service
