NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local activeStates = { RESERVED = true, TRAVELLING = true, ARRIVED = true, ACTIVE = true }
local releasableStates = { RESERVED = true, TRAVELLING = true, ARRIVED = true, ACTIVE = true, COMPLETED = true, SETTLED = true, INTERRUPTED = true, CANCELLED = true, EXPIRED = true }

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.PICKUP_VEHICLE_INVALID, message, details)
end

local function unwrap(value, fallback)
    if type(value) ~= 'table' then return nil, Result.err(fallback or Codes.PICKUP_VEHICLE_INVALID, 'pickup vehicle dependency returned an invalid result') end
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

local function normalizeBookingId(value)
    if integer(value, 1, 2147483647) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

local function normalizeVehicleId(value)
    if integer(value, 1, 2147483647) then return tostring(value) end
    return token(value, 96) and tostring(value) or nil
end

local function actorFromIdentity(identity, playerSource)
    local source = integer(playerSource, 1, 65535)
    if not source then return nil, invalid('pickup vehicle player source is invalid') end
    if type(identity) == 'table' and type(identity.resolve) == 'function' then
        local ok, result = pcall(identity.resolve, identity, source)
        if not ok then return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'pickup vehicle identity lookup failed') end
        local value, errorResult = unwrap(result, Codes.IDENTITY_UNAVAILABLE)
        if not value then return nil, errorResult end
        local ref = value.identityKey or value.key or value.ref
        if not text(ref, 200) then return nil, Result.err(Codes.IDENTITY_INVALID, 'pickup vehicle identity has no safe reference') end
        return { type = 'PLAYER', ref = tostring(ref), source = source }
    end
    return { type = 'PLAYER', ref = tostring(source), source = source }
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('pickup vehicle options must be a table') end
    local booking = options.bookingService or options.booking
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' then return nil, invalid('pickup vehicle binding requires a booking service') end
    local vehicle = options.vehicleLocationService or options.vehicleService or options.vehicleLocation
    if type(vehicle) ~= 'table' and type(vehicle) ~= 'function' then return nil, invalid('pickup vehicle binding requires a vehicle resolver') end
    return setmetatable({
        _booking = booking, _identity = options.identityService or options.identity,
        _vehicle = vehicle, _clock = options.clock,
        _seatCheck = options.seatCheck or options.seatAvailabilityCheck or options.hasSeat,
        _proximityCheck = options.npcNearby or options.npcProximityCheck or options.isNpcNearby,
        _accessCheck = options.accessCheck or options.vehicleAccessCheck,
        _allowChange = options.allowVehicleChange == true,
        _onEnter = options.onEnter,
        _bindings = {}, _sequence = 0
    }, Service)
end

function Service:_getBooking(id)
    local ok, result = pcall(self._booking.get, self._booking, id)
    if not ok then return nil, Result.err(Codes.BOOKING_NOT_FOUND, 'pickup booking lookup failed') end
    local value, errorResult = unwrap(result, Codes.BOOKING_NOT_FOUND)
    if not value then return nil, errorResult end
    if tostring(value.id or value.bookingId) ~= tostring(id) then return nil, invalid('pickup booking lookup returned a mismatched booking') end
    return value
end

function Service:_owner(source, booking, allowTerminal)
    local actor, actorError = actorFromIdentity(self._identity, source)
    if not actor then return nil, actorError end
    if tostring(booking.clientType or ''):upper() ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then
        return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'player does not own this pickup booking')
    end
    if tostring(booking.meetingMode or booking.mode or ''):upper() ~= 'PICKUP' then
        return nil, Result.err(Codes.PICKUP_VEHICLE_INVALID, 'vehicle binding requires a PICKUP booking')
    end
    if tostring(booking.workerType or ''):upper() ~= 'NPC' or not token(booking.workerRef, 160) then
        return nil, Result.err(Codes.PICKUP_VEHICLE_INVALID, 'pickup booking has no NPC worker')
    end
    local bookingState = tostring(booking.status or ''):upper()
    if not activeStates[bookingState] and not (allowTerminal == true and releasableStates[bookingState]) then
        return nil, Result.err(Codes.PICKUP_VEHICLE_CONFLICT, 'pickup booking is not in a bindable state', { status = booking.status })
    end
    return actor
end

function Service:_resolve(source, request)
    local resolver = self._vehicle
    local result, ok
    if type(resolver) == 'table' and type(resolver.resolve) == 'function' then
        result, ok = call(resolver.resolve, resolver, source, request)
    elseif type(resolver) == 'function' then
        result, ok = call(resolver, source, request)
    end
    if not ok or type(result) ~= 'table' then return nil, Result.err(Codes.PICKUP_VEHICLE_NOT_FOUND, 'server vehicle lookup failed') end
    local value, errorResult = unwrap(result, Codes.PICKUP_VEHICLE_NOT_FOUND)
    if not value then
        if errorResult and errorResult.error and errorResult.error.code == Codes.VEHICLE_NOT_FOUND then
            return nil, Result.err(Codes.PICKUP_VEHICLE_NOT_FOUND, 'pickup vehicle was not found')
        end
        return nil, errorResult
    end
    return value
end

function Service:_vehicleId(value, request)
    local id = value.vehicleId or value.vehicleRef or value.id
    id = normalizeVehicleId(id or request.vehicleId or request.vehicleRef or request.id)
    if not id then return nil end
    local requested = normalizeVehicleId(request.vehicleId or request.vehicleRef or request.id)
    if requested and requested ~= id then return nil end
    if value.locationRef and tostring(value.locationRef) ~= 'vehicle:' .. id then return nil end
    return id
end

function Service:_checkSeat(source, vehicle, seat, booking)
    if type(self._seatCheck) == 'function' then
        local result, ok = call(self._seatCheck, source, copy(vehicle), seat, copy(booking))
        if not ok or result == nil then return nil, Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'vehicle seat verifier is unavailable') end
        return allowed(result), allowed(result) and nil or Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'requested vehicle seat is unavailable')
    end
    local record = vehicle.vehicleRecord or vehicle.record or vehicle
    if type(record.seatAvailable) == 'boolean' then
        return record.seatAvailable, record.seatAvailable and nil or Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'requested vehicle seat is unavailable')
    end
    if type(record.passengerSeatAvailable) == 'boolean' then
        return record.passengerSeatAvailable, record.passengerSeatAvailable and nil or Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'requested vehicle seat is unavailable')
    end
    if type(record.seats) == 'table' and record.seats[seat] ~= nil then
        local free = record.seats[seat] == true or record.seats[seat] == 'AVAILABLE' or record.seats[seat] == 'FREE'
        return free, free and nil or Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'requested vehicle seat is unavailable')
    end
    return nil, Result.err(Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'vehicle seat availability cannot be verified')
end

function Service:_checkProximity(source, vehicle, booking)
    if type(self._proximityCheck) == 'function' then
        local result, ok = call(self._proximityCheck, source, copy(vehicle), copy(booking))
        if not ok or result == nil then return nil, Result.err(Codes.PICKUP_VEHICLE_PROXIMITY_INVALID, 'NPC proximity verifier is unavailable') end
        return allowed(result), allowed(result) and nil or Result.err(Codes.PICKUP_VEHICLE_PROXIMITY_INVALID, 'NPC is not near the vehicle')
    end
    local near = vehicle.npcNearby
    if near == nil and type(vehicle.vehicle) == 'table' then near = vehicle.vehicle.npcNearby end
    if type(near) == 'boolean' then
        return near, near and nil or Result.err(Codes.PICKUP_VEHICLE_PROXIMITY_INVALID, 'NPC is not near the vehicle')
    end
    return nil, Result.err(Codes.PICKUP_VEHICLE_PROXIMITY_INVALID, 'NPC proximity cannot be verified')
end

function Service:_checkAccess(source, vehicle, booking)
    if type(self._accessCheck) ~= 'function' then return true end
    local result, ok = call(self._accessCheck, source, copy(vehicle), copy(booking))
    if not ok or result == nil then return nil, Result.err(Codes.PICKUP_VEHICLE_ACCESS_DENIED, 'vehicle access verifier is unavailable') end
    if not allowed(result) then return nil, Result.err(Codes.PICKUP_VEHICLE_ACCESS_DENIED, 'player cannot access this vehicle') end
    return true
end

function Service:bind(playerSource, request)
    if type(request) ~= 'table' then return invalid('pickup vehicle binding request must be a table') end
    local fields = { bookingId = true, vehicleId = true, vehicleRef = true, id = true, seat = true, networkId = true, entity = true, expectedVersion = true }
    for key in pairs(request) do if not fields[key] then return invalid('pickup vehicle request field is not allowlisted', { field = tostring(key) }) end end
    local bookingId = normalizeBookingId(request.bookingId)
    local vehicleId = normalizeVehicleId(request.vehicleId or request.vehicleRef or request.id)
    if not bookingId or not vehicleId then return invalid('pickup vehicle binding requires booking and vehicle IDs') end
    local requestEntity = request.entity == nil and nil or integer(request.entity, 1, 2147483647)
    local requestNetworkId = request.networkId == nil and nil or integer(request.networkId, 1, 2147483647)
    if request.entity ~= nil and not requestEntity then return invalid('pickup vehicle entity handle is invalid') end
    if request.networkId ~= nil and not requestNetworkId then return invalid('pickup vehicle network handle is invalid') end
    local booking, bookingError = self:_getBooking(bookingId)
    if not booking then return bookingError end
    local actor, ownerError = self:_owner(playerSource, booking)
    if not actor then return ownerError end
    local existing = self._bindings[bookingId]
    if existing and existing.vehicleId ~= vehicleId then
        if not self._allowChange or existing.state ~= 'BOUND' then
            return Result.err(Codes.PICKUP_VEHICLE_CONFLICT, 'pickup vehicle is already bound and cannot be changed', { vehicleId = existing.vehicleId })
        end
        self._bindings[bookingId] = nil
    elseif existing then
        local valid = self:validate(playerSource, { bookingId = bookingId })
        if valid.ok then return Result.ok(copy(valid.value), { idempotent = true, serverAuthoritative = true }) end
        if valid.error and valid.error.code ~= Codes.PICKUP_VEHICLE_DESTROYED then return valid end
        self._bindings[bookingId] = nil
    end
    local resolved, resolveError = self:_resolve(actor.source, {
        vehicleId = vehicleId, bookingId = bookingId, meetingMode = 'PICKUP'
    })
    if not resolved then return resolveError end
    local resolvedId = self:_vehicleId(resolved, { vehicleId = vehicleId })
    if not resolvedId then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'server vehicle identity does not match the request') end
    if resolved.exists == false or resolved.serverVisible == false then return Result.err(Codes.PICKUP_VEHICLE_NOT_FOUND, 'pickup vehicle is no longer available') end
    local access, accessError = self:_checkAccess(actor.source, resolved, booking)
    if not access then return accessError end
    local seat = integer(request.seat == nil and 0 or request.seat, -1, 15)
    if seat == nil then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'pickup vehicle seat is invalid') end
    local free, seatError = self:_checkSeat(actor.source, resolved, seat, booking)
    if free ~= true then return seatError end
    local near, proximityError = self:_checkProximity(actor.source, resolved, booking)
    if near ~= true then return proximityError end
    self._sequence = self._sequence + 1
    local binding = {
        bookingId = bookingId, ownerRef = actor.ref, ownerSource = actor.source,
        vehicleId = resolvedId, vehicleRef = 'vehicle:' .. resolvedId,
        networkId = requestNetworkId or resolved.networkId, entity = requestEntity or resolved.entity,
        seat = seat, state = 'BOUND', boundAt = now(self._clock),
        bindingToken = ('pickup-vehicle:%s:%d'):format(bookingId, self._sequence),
        vehicle = copy(resolved), serverAuthoritative = true
    }
    self._bindings[bookingId] = binding
    return Result.ok(copy(binding), { created = true, serverAuthoritative = true })
end

function Service:validate(playerSource, request)
    if type(request) ~= 'table' then return invalid('pickup vehicle validation request must be a table') end
    local bookingId = normalizeBookingId(request.bookingId)
    if not bookingId then return invalid('pickup vehicle validation requires a booking ID') end
    local booking, bookingError = self:_getBooking(bookingId)
    if not booking then return bookingError end
    local actor, ownerError = self:_owner(playerSource, booking)
    if not actor then return ownerError end
    local binding = self._bindings[bookingId]
    if not binding then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'pickup vehicle is not bound') end
    if binding.ownerRef ~= actor.ref or binding.ownerSource ~= actor.source then return Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup vehicle binding belongs to another player') end
    local resolved, resolveError = self:_resolve(actor.source, { vehicleId = binding.vehicleId, bookingId = bookingId, meetingMode = 'PICKUP' })
    if not resolved then
        binding.state = 'DESTROYED'
        return Result.err(Codes.PICKUP_VEHICLE_DESTROYED, 'bound pickup vehicle no longer exists', { vehicleId = binding.vehicleId })
    end
    if resolved.exists == false or resolved.serverVisible == false then
        binding.state = 'DESTROYED'
        return Result.err(Codes.PICKUP_VEHICLE_DESTROYED, 'bound pickup vehicle no longer exists', { vehicleId = binding.vehicleId })
    end
    local free, seatError = self:_checkSeat(actor.source, resolved, binding.seat, booking)
    if free ~= true then return seatError end
    local near, proximityError = self:_checkProximity(actor.source, resolved, booking)
    if near ~= true then return proximityError end
    binding.vehicle = copy(resolved)
    return Result.ok(copy(binding))
end

function Service:confirmEntry(playerSource, request)
    local checked = self:validate(playerSource, request)
    if not checked.ok then return checked end
    local binding = self._bindings[tostring(request.bookingId)]
    if binding.state == 'OCCUPIED' then return Result.ok(copy(binding), { idempotent = true }) end
    if type(self._onEnter) == 'function' then
        local result, ok = call(self._onEnter, playerSource, copy(binding))
        if not ok or result == false then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'vehicle entry could not be confirmed') end
    end
    binding.state, binding.enteredAt = 'OCCUPIED', now(self._clock)
    return Result.ok(copy(binding), { entered = true, serverAuthoritative = true })
end

function Service:get(bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('pickup vehicle booking ID is invalid') end
    local binding = self._bindings[id]
    if not binding then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'pickup vehicle binding was not found') end
    return Result.ok(copy(binding))
end

function Service:release(playerSource, request)
    local id = normalizeBookingId(type(request) == 'table' and request.bookingId or request)
    if not id then return invalid('pickup vehicle booking ID is invalid') end
    local binding = self._bindings[id]
    if not binding then return Result.ok({ bookingId = id, state = 'RELEASED' }, { idempotent = true }) end
    local booking, bookingError = self:_getBooking(id)
    if not booking then return bookingError end
    local actor, ownerError = self:_owner(playerSource, booking, true)
    if not actor then return ownerError end
    if binding.ownerRef ~= actor.ref then return Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup vehicle binding belongs to another player') end
    self._bindings[id] = nil
    return Result.ok({ bookingId = id, vehicleId = binding.vehicleId, state = 'RELEASED' })
end

Service.bindVehicle = Service.bind
Service.enter = Service.confirmEntry
Service.confirm = Service.confirmEntry
Service.check = Service.validate
Service.unbind = Service.release

NightShift.PickupVehicleService = Service
NightShift.Services.PickupVehicle = Service
