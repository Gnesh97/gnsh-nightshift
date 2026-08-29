NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.LocationReservation

local Service = {}
Service.__index = Service

local providerTypes = { MOTEL_ROOM='motel', HOTEL_ROOM='motel', PROPERTY='housing', VENUE_ROOM='venue', CUSTOM_PROVIDER=nil }

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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.RESERVATION_INVALID, message, details)
end

local function providerCall(provider, operation, locationRef, bookingId, ttlSeconds)
    if type(provider) ~= 'table' then return true end
    local method = provider[operation]
    local methodStyle = true
    if type(method) ~= 'function' and operation == 'reserve' then method, methodStyle = provider.reserveRoom, false end
    if type(method) ~= 'function' and operation == 'release' then method, methodStyle = provider.releaseRoom, false end
    if type(method) ~= 'function' and operation == 'occupy' then method, methodStyle = provider.occupyRoom, false end
    if type(method) ~= 'function' then return true end
    local ok, result
    if methodStyle then
        ok, result = pcall(method, provider, locationRef, bookingId, ttlSeconds)
    else
        ok, result = pcall(method, locationRef, bookingId, ttlSeconds)
    end
    if not ok or result == false or type(result) == 'table' and result.ok == false then
        return nil, Result.err(Codes.RESERVATION_PROVIDER_FAILED, 'location reservation provider operation failed', { operation = operation, locationRef = locationRef })
    end
    return true
end

function Service.new(options)
    options = options or {}
    local resolver = options.locationService or options.locationResolver
    if type(resolver) ~= 'table' or type(resolver.resolve) ~= 'function' then return nil, invalid('location reservation service requires a location resolver') end
    local locks = options.locks or options.manager
    if locks == nil and NightShift.Reservations then
        locks = NightShift.Reservations.new({ clock = options.clock, defaultTtl = options.defaultTtl })
    end
    if type(locks) ~= 'table' or type(locks.reserve) ~= 'function' or type(locks.release) ~= 'function' then return nil, invalid('location reservation service requires a lock manager') end
    local ttl = tonumber(options.defaultTtl or 300)
    if not ttl or ttl < 1 or ttl > 86400 or ttl ~= math.floor(ttl) then return nil, invalid('location reservation default TTL is invalid') end
    local providers = options.providers or options.providerMap
    if type(providers) == 'table' and type(providers.optional) == 'table' then providers = providers.optional end
    return setmetatable({
        _resolver = resolver,
        _repository = options.repository or options.locationReservationRepository,
        _locks = locks,
        _providers = providers,
        _clock = options.clock,
        _defaultTtl = ttl,
        _active = {},
        _byLocation = {}
    }, Service)
end

function Service:_provider(location)
    local providers = self._providers
    if type(providers) ~= 'table' and type(self._resolver) == 'table' then providers = self._resolver._providers end
    if type(providers) ~= 'table' then return nil end
    local name = location.provider or providerTypes[location.locationType]
    return name and (providers[name] or providers[tostring(name):lower()] or providers[tostring(name):upper()]) or nil
end

function Service:_key(bookingId, locationRef)
    return ('location:%s:%s'):format(locationRef, tostring(bookingId))
end

function Service:_find(bookingId, locationRef, key)
    key = key or self:_key(bookingId, locationRef)
    local existing = self._active[key]
    if existing then return existing end
    if type(self._repository) == 'table' and type(self._repository.findByKey) == 'function' then
        local result = self._repository:findByKey(key)
        if type(result) == 'table' and result.ok and result.value then
            local value = result.value
            self._active[key], self._byLocation[value.locationRef] = value, key
            return value
        end
    end
    return nil
end

function Service:reserve(bookingId, request, context)
    if not text(bookingId, 160) and tonumber(bookingId) == nil then return invalid('location reservation booking ID is invalid') end
    bookingId = tostring(bookingId)
    if type(request) ~= 'table' then return invalid('location reservation request must be a table') end
    local resolveOk, resolved = pcall(self._resolver.resolve, self._resolver, context and context.source or request.source, copy(request))
    if not resolveOk then return Result.err(Codes.LOCATION_INVALID, 'location resolver failed') end
    if type(resolved) ~= 'table' then return Result.err(Codes.LOCATION_INVALID, 'location resolver returned an invalid result') end
    if not resolved.ok then return resolved end
    local location = resolved.value and (resolved.value.location or resolved.value)
    if type(location) ~= 'table' or not text(location.locationRef, 160) then return invalid('location resolver returned no typed location') end
    if location.reservable == false then return Result.err(Codes.LOCATION_UNAVAILABLE, 'location cannot be reserved') end
    local key = self:_key(bookingId, location.locationRef)
    local existing = self:_find(bookingId, location.locationRef, key)
    if existing and (existing.status == 'RESERVED' or existing.status == 'OCCUPIED') then
        local idempotent = type(existing.copy) == 'function' and existing:copy() or copy(existing)
        idempotent.idempotent = true
        return Result.ok(idempotent)
    end
    local ttl = tonumber(request.ttlSeconds or request.ttl or self._defaultTtl)
    if not ttl or ttl < 1 or ttl > 86400 or ttl ~= math.floor(ttl) then return invalid('location reservation TTL is invalid') end
    local at = now(self._clock)
    if type(self._repository) == 'table' and type(self._repository.expireExpired) == 'function' then
        local expired = self._repository:expireExpired()
        if type(expired) ~= 'table' or not expired.ok then return expired end
    end
    local conflictKey = self._byLocation[location.locationRef]
    local conflict = conflictKey and self._active[conflictKey]
    if conflict and (conflict.status == 'RESERVED' or conflict.status == 'OCCUPIED') and conflict.bookingId ~= bookingId and (not conflict.holdUntil or conflict.holdUntil > at) then
        return Result.err(Codes.RESERVATION_CONFLICT, 'location is already reserved', { locationRef = location.locationRef, bookingId = conflict.bookingId })
    end
    local locked = self._locks:reserve(bookingId, { { type = 'LOCATION', id = location.locationRef, ttlSeconds = ttl } }, { now = at, defaultTtl = ttl })
    if type(locked) ~= 'table' or not locked.ok then return locked end
    if locked.value and locked.value.idempotent and conflict then
        local value = type(conflict.copy) == 'function' and conflict:copy() or copy(conflict)
        value.idempotent = true
        return Result.ok(value)
    end
    local reservation, reservationError = Domain.new({
        reservationKey = key,
        -- The active key is location-scoped so the database unique constraint
        -- closes the race between different bookings targeting one location.
        activeKey = 'location:' .. location.locationRef,
        locationRef = location.locationRef,
        bookingId = bookingId,
        status = 'RESERVED',
        holdUntil = at + ttl
    })
    if not reservation then
        self._locks:release(bookingId, { { type = 'LOCATION', id = location.locationRef } })
        return reservationError
    end
    local provider = self:_provider(location)
    local providerOk, providerError = providerCall(provider, 'reserve', location.locationRef, bookingId, ttl)
    if not providerOk then
        self._locks:release(bookingId, { { type = 'LOCATION', id = location.locationRef } })
        return providerError
    end
    if type(self._repository) == 'table' and type(self._repository.reserveAtomic) == 'function' then
        local persisted = self._repository:reserveAtomic(reservation)
        if type(persisted) ~= 'table' or not persisted.ok then
            providerCall(provider, 'release', location.locationRef, bookingId)
            self._locks:release(bookingId, { { type = 'LOCATION', id = location.locationRef } })
            return persisted
        end
        if persisted.value and persisted.value.insertId then reservation.id, reservation.recordId = persisted.value.insertId, persisted.value.insertId end
    elseif type(self._repository) == 'table' and type(self._repository.create) == 'function' then
        local persisted = self._repository:create(reservation)
        if type(persisted) ~= 'table' or not persisted.ok then
            providerCall(provider, 'release', location.locationRef, bookingId)
            self._locks:release(bookingId, { { type = 'LOCATION', id = location.locationRef } })
            return persisted
        end
    end
    reservation.location = type(location.copy) == 'function' and location:copy() or copy(location)
    self._active[key], self._byLocation[location.locationRef] = reservation, key
    return Result.ok(reservation)
end

function Service:occupy(bookingId, reservationKey)
    if not text(bookingId, 160) or not text(reservationKey, 200) then return invalid('location occupancy identity is invalid') end
    local reservation = self._active[reservationKey]
    if not reservation then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'location reservation was not found') end
    if reservation.bookingId ~= tostring(bookingId) then return Result.err(Codes.RESERVATION_OWNER_MISMATCH, 'location reservation belongs to another booking') end
    if reservation.status == 'OCCUPIED' then local value = reservation:copy(); value.idempotent = true; return Result.ok(value) end
    if reservation.status ~= 'RESERVED' then return Result.err(Codes.RESERVATION_EXPIRED, 'location reservation is no longer active') end
    local providerOk, providerError = providerCall(self:_provider(reservation.location or {}), 'occupy', reservation.locationRef, tostring(bookingId))
    if not providerOk then return providerError end
    local nextValue = reservation:copy()
    nextValue.status = 'OCCUPIED'
    if type(self._repository) == 'table' and type(self._repository.updateExpectedVersion) == 'function' and reservation.id then
        local persisted = self._repository:updateExpectedVersion(reservation.id, reservation.version, { status = 'OCCUPIED', activeKey = reservation.activeKey })
        if type(persisted) ~= 'table' or not persisted.ok then
            providerCall(self:_provider(reservation.location or {}), 'release', reservation.locationRef, tostring(bookingId))
            return Result.err(Codes.RESERVATION_PROVIDER_FAILED, 'location occupancy persistence failed', { cause = type(persisted) == 'table' and persisted.error and persisted.error.code })
        end
        nextValue.version = reservation.version + 1
    end
    reservation.status = 'OCCUPIED'
    if nextValue.version then reservation.version = nextValue.version end
    return Result.ok(nextValue)
end

function Service:release(bookingId, reservationKey)
    if not text(bookingId, 160) or not text(reservationKey, 200) then return invalid('location release identity is invalid') end
    local reservation = self._active[reservationKey]
    if not reservation then return Result.ok({ reservationKey = reservationKey, idempotent = true, status = 'RELEASED' }) end
    if reservation.bookingId ~= tostring(bookingId) then return Result.err(Codes.RESERVATION_OWNER_MISMATCH, 'location reservation belongs to another booking') end
    if reservation.status == 'RELEASED' or reservation.status == 'EXPIRED' then
        local value = reservation:copy(); value.idempotent = true; return Result.ok(value)
    end
    local providerOk, providerError = providerCall(self:_provider(reservation.location or {}), 'release', reservation.locationRef, tostring(bookingId))
    if not providerOk then return providerError end
    local released = self._locks:release(tostring(bookingId), { { type = 'LOCATION', id = reservation.locationRef } })
    if type(released) ~= 'table' or not released.ok then return released end
    reservation.status = 'RELEASED'
    reservation.activeKey = nil
    local value = reservation:copy()
    if type(self._repository) == 'table' and type(self._repository.updateExpectedVersion) == 'function' and reservation.id then
        local persisted = self._repository:updateExpectedVersion(reservation.id, reservation.version, { status = 'RELEASED' })
        if type(persisted) ~= 'table' or not persisted.ok then
            return Result.err(Codes.RESERVATION_PROVIDER_FAILED, 'location release persistence failed', { cause = type(persisted) == 'table' and persisted.error and persisted.error.code })
        end
        value.version = reservation.version + 1
        reservation.version = value.version
    end
    self._byLocation[reservation.locationRef], self._active[reservationKey] = nil, nil
    return Result.ok(value)
end

function Service:expire()
    local at, expired = now(self._clock), 0
    if type(self._locks.purgeExpired) == 'function' then self._locks:purgeExpired(at) end
    for key, reservation in pairs(copy(self._active)) do
        if reservation.status == 'RESERVED' and type(reservation.holdUntil) == 'number' and reservation.holdUntil <= at then
            providerCall(self:_provider(reservation.location or {}), 'release', reservation.locationRef, reservation.bookingId)
            reservation.status, reservation.activeKey = 'EXPIRED', nil
            if type(self._repository) == 'table' and type(self._repository.updateExpectedVersion) == 'function' and reservation.id then
                self._repository:updateExpectedVersion(reservation.id, reservation.version, { status = 'EXPIRED', activeKey = nil })
            end
            self._byLocation[reservation.locationRef], self._active[key] = nil, nil
            expired = expired + 1
        end
    end
    return Result.ok({ expired = expired })
end

function Service:isReserved(locationRef)
    if not text(locationRef, 160) then return invalid('location reference is invalid') end
    self:expire()
    local key, reservation = self._byLocation[locationRef], self._byLocation[locationRef] and self._active[self._byLocation[locationRef]]
    if reservation and (reservation.status == 'RESERVED' or reservation.status == 'OCCUPIED') then
        return Result.ok({ reserved = true, bookingId = reservation.bookingId, reservationKey = reservation.reservationKey, status = reservation.status, expiresAt = reservation.holdUntil })
    end
    local lock = type(self._locks.isReserved) == 'function' and self._locks:isReserved('LOCATION', locationRef) or nil
    if type(lock) == 'table' and lock.ok and lock.value then return Result.ok(lock.value) end
    return Result.ok({ reserved = false })
end

function Service:active(bookingId)
    local output = {}
    for _, reservation in pairs(self._active) do
        if bookingId == nil or reservation.bookingId == tostring(bookingId) then output[#output + 1] = reservation:copy() end
    end
    return Result.ok(output)
end

NightShift.LocationReservationService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.LocationReservation = Service
