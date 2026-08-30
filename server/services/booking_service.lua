NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Booking
local StateMachine = NightShift.BookingStateMachine
local PriceQuote = NightShift.Domain and NightShift.Domain.PriceQuote

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

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function integer(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value or (minimum and value < minimum) then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.BOOKING_SERVICE_INVALID, message, details)
end

local function unwrap(result, fallbackCode)
    if type(result) ~= 'table' then return nil, Result.err(fallbackCode or Codes.INTERNAL, 'booking provider returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true and result.value ~= nil then return result.value end
    if result.success == true and result.value ~= nil then return result.value end
    return result
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and
        (result.error.code == Codes.REPOSITORY_NOT_FOUND or result.error.code == Codes.BOOKING_NOT_FOUND)
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and text(value, 64) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function actorValue(actor)
    if type(actor) ~= 'table' then return nil, invalid('booking actor is required') end
    local kind = type(actor.type) == 'string' and actor.type:upper() or nil
    if not kind or not Domain.participantTypes[kind] and kind ~= 'ADMIN' then return nil, invalid('booking actor type is invalid') end
    if not text(actor.ref, 160) then return nil, invalid('booking actor ref is required') end
    return { type = kind, ref = actor.ref, source = actor.source }
end

local function expectedVersion(value)
    if value == nil then return nil end
    value = integer(value, 1)
    if not value then return nil, invalid('expected booking version is invalid') end
    return value
end

local function packageSnapshot(value)
    if type(value) ~= 'table' then return nil, invalid('service package resolver returned no package') end
    local id = value.id or value.key or value.name
    local price = value.priceMinor
    if price == nil then price = value.basePriceMinor end
    if price == nil then price = value.price end
    local duration = value.durationMinutes
    if duration == nil then duration = value.duration end
    local currency = type(value.currency) == 'string' and value.currency:upper() or 'USD'
    if not text(id, 96) or not integer(price, 1) or not integer(duration, 1) or currency:match('^[A-Z][A-Z][A-Z]$') == nil then
        return nil, Result.err(Codes.BOOKING_INVALID, 'service package snapshot is invalid')
    end
    return { id = id, priceMinor = price, durationMinutes = duration, currency = currency }
end

local function quoteSnapshot(value, bookingId)
    if type(value) ~= 'table' then return nil, Result.err(Codes.BOOKING_INVALID, 'quote resolver returned no quote') end
    local amount = integer(value.amountMinor or value.amount, 1)
    local currency = type(value.currency) == 'string' and value.currency:upper() or nil
    if not amount or not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then
        return nil, Result.err(Codes.QUOTE_INVALID, 'quote snapshot is invalid')
    end
    local output = { amountMinor = amount, currency = currency, quotedAt = value.quotedAt or value.issuedAt, expiresAt = value.expiresAt }
    local quoteId = value.quoteId or value.id
    if quoteId ~= nil then output.quoteId = quoteId end
    if bookingId ~= nil then output.bookingId = bookingId end
    if output.quotedAt == nil then output.quotedAt = timestamp(nil) end
    return output
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.bookingRepository
    if type(repository) ~= 'table' or type(repository.create) ~= 'function' or type(repository.findById) ~= 'function' or
        type(repository.findByIdempotencyKey) ~= 'function' or type(repository.updateExpectedVersion) ~= 'function' then
        return nil, invalid('booking service requires a booking repository')
    end
    local stateMachine = options.stateMachine
    if stateMachine == nil then stateMachine = assert(StateMachine.new()) end
    if type(stateMachine) ~= 'table' or type(stateMachine.transition) ~= 'function' then return nil, invalid('booking state machine is invalid') end
    local timeline = options.timelineService or options.timeline
    if type(timeline) ~= 'table' or type(timeline.record) ~= 'function' then return nil, invalid('booking service requires a timeline service') end
    return setmetatable({
        _repository = repository,
        _state = stateMachine,
        _timeline = timeline,
        _reservation = options.reservationService,
        _locationResolver = options.locationResolver or options.locationService,
        _catalogResolver = options.catalogResolver or options.resolveServicePackage,
        _quote = options.quoteResolver or options.resolveQuote or options.pricingService,
        _authorize = options.authorize,
        _permissionService = options.permissionService,
        _clock = options.clock
    }, Service)
end

function Service:_get(id)
    local result = self._repository:findById(id)
    if type(result) ~= 'table' then return nil, Result.err(Codes.BOOKING_NOT_FOUND, 'booking lookup returned an invalid result') end
    if not result.ok then
        if notFound(result) then return nil, Result.err(Codes.BOOKING_NOT_FOUND, 'booking was not found', { id = id }) end
        return nil, result
    end
    if type(result.value) ~= 'table' then return nil, Result.err(Codes.BOOKING_NOT_FOUND, 'booking lookup returned no booking') end
    return copy(result.value)
end

function Service:_checkPermission(actor, booking, action)
    if actor.type == 'SYSTEM' or actor.type == 'ADMIN' then return true end
    if type(self._authorize) == 'function' then
        local ok, allowed = pcall(self._authorize, actor, booking, action)
        if ok and (allowed == true or type(allowed) == 'table' and allowed.ok == true and allowed.value and allowed.value.allowed == true) then return true end
    end
    if type(self._permissionService) == 'table' and type(self._permissionService.authorize) == 'function' and actor.source ~= nil then
        local ok, result = pcall(self._permissionService.authorize, self._permissionService, actor.source, 'booking.manage')
        if ok and type(result) == 'table' and result.ok and result.value and result.value.allowed == true then return true end
    end
    local clientOwns = booking.clientType == 'PLAYER' and booking.clientRef == actor.ref
    local workerOwns = booking.workerType == 'PLAYER' and booking.workerRef == actor.ref
    return clientOwns or workerOwns
end

function Service:_requireOwner(actor, booking, action)
    local normalized, actorError = actorValue(actor)
    if not normalized then return nil, actorError end
    if not self:_checkPermission(normalized, booking, action) then
        return nil, Result.err(Codes.BOOKING_OWNERSHIP_DENIED, 'actor is not a booking participant', { action = action })
    end
    return normalized
end

function Service:_catalog(id, input)
    if not text(id, 96) then return nil, Result.err(Codes.BOOKING_INVALID, 'service package ID is required') end
    local resolver = self._catalogResolver
    if type(resolver) == 'table' and type(resolver.resolve) == 'function' then
        resolver = function(packageId, request) return self._catalogResolver:resolve(packageId, request) end
    end
    if type(resolver) == 'function' then
        local ok, result = pcall(resolver, id, copy(input))
        if not ok then return nil, Result.err(Codes.BOOKING_INVALID, 'service package resolver failed') end
        local value, errorResult = unwrap(result, Codes.BOOKING_INVALID)
        if not value then return nil, errorResult end
        return value
    end
    return nil, Result.err(Codes.BOOKING_INVALID, 'service package resolver is required')
end

function Service:createDraft(actor, input)
    if type(input) ~= 'table' then return invalid('booking draft input must be a table') end
    local normalizedActor, actorError = actorValue(actor)
    if not normalizedActor then return actorError end
    local packageInput = input.servicePackage
    if packageInput == nil then packageInput = input.servicePackageId or input.packageId end
    local packageId = type(packageInput) == 'table' and packageInput.id or packageInput
    local package, packageError = self:_catalog(packageId, input)
    if not package then return packageError end
    package, packageError = packageSnapshot(package)
    if not package then return packageError end
    local idempotencyKey = input.idempotencyKey
    if idempotencyKey == nil then idempotencyKey = ('draft:%s:%s'):format(normalizedActor.ref, timestamp(self._clock)) end
    if not text(idempotencyKey, 128) then return invalid('booking idempotency key is invalid') end
    local existing = self._repository:findByIdempotencyKey(idempotencyKey)
    if type(existing) ~= 'table' then return Result.err(Codes.BOOKING_NOT_FOUND, 'idempotency lookup returned an invalid result') end
    if existing.ok then return Result.ok(copy(existing.value), { idempotent = true }) end
    if not notFound(existing) then return existing end

    local resolvedLocation
    local resolvedMeetingMode
    if self._locationResolver and (input.locationType ~= nil or input.locationRef ~= nil or input.locationId ~= nil) then
        if type(self._locationResolver) ~= 'table' or type(self._locationResolver.resolve) ~= 'function' then
            return Result.err(Codes.LOCATION_INVALID, 'booking location resolver is unavailable')
        end
        local locationRequest = copy(input)
        locationRequest.locationType = input.locationType or input.type
        locationRequest.locationRef = input.locationRef or input.locationId
        local ok, locationResult = pcall(self._locationResolver.resolve, self._locationResolver, normalizedActor.source, locationRequest)
        if not ok or type(locationResult) ~= 'table' then return Result.err(Codes.LOCATION_INVALID, 'booking location resolver failed') end
        if not locationResult.ok then return locationResult end
        resolvedLocation = locationResult.value and (locationResult.value.location or locationResult.value)
        resolvedMeetingMode = locationResult.value and locationResult.value.meetingMode or resolvedLocation and resolvedLocation.meetingMode
        if type(resolvedLocation) ~= 'table' or not text(resolvedLocation.locationType or resolvedLocation.type, 32) or not text(resolvedLocation.locationRef or resolvedLocation.id, 160) then
            return Result.err(Codes.LOCATION_INVALID, 'booking location resolver returned an invalid location')
        end
    end

    local values = {
        idempotencyKey = idempotencyKey,
        initiatorType = input.initiatorType or normalizedActor.type,
        clientType = input.clientType,
        clientRef = input.clientRef,
        workerType = input.workerType,
        workerRef = input.workerRef,
        servicePackage = package,
        meetingMode = input.meetingMode or resolvedMeetingMode,
        locationType = resolvedLocation and (resolvedLocation.locationType or resolvedLocation.type) or input.locationType,
        locationRef = resolvedLocation and (resolvedLocation.locationRef or resolvedLocation.id) or input.locationRef,
        scheduledAt = input.scheduledAt,
        correlationId = input.correlationId,
        externalReference = input.externalReference,
        status = 'DRAFT'
    }
    local booking, bookingError = Domain.new(values)
    if not booking then return bookingError end
    if not self:_checkPermission(normalizedActor, booking, 'create') then
        return Result.err(Codes.BOOKING_OWNERSHIP_DENIED, 'actor is not a booking participant', { action = 'create' })
    end
    local created = self._repository:create(booking)
    if type(created) ~= 'table' then return Result.err(Codes.BOOKING_SERVICE_INVALID, 'booking create returned an invalid result') end
    if not created.ok then
        local raced = self._repository:findByIdempotencyKey(idempotencyKey)
        if type(raced) == 'table' and raced.ok then return Result.ok(copy(raced.value), { idempotent = true }) end
        return created
    end
    local id = created.value and (created.value.insertId or created.value.id)
    if id ~= nil then
        local persisted, persistedError = self:_get(id)
        if persisted then return Result.ok(persisted, { created = true }) end
        if persistedError and notFound(persistedError) then
            booking.id = id
            return Result.ok(booking, { created = true, persisted = false })
        end
        return persistedError
    end
    return Result.ok(booking, { created = true, persisted = false })
end

function Service:_transition(actor, id, target, expected, metadata, changes, trustedGuard)
    local booking, bookingError = self:_get(id)
    if not booking then return bookingError end
    local owner, ownerError = self:_requireOwner(actor, booking, target:lower())
    if not owner then return ownerError end
    local expectedValue, expectedError = expectedVersion(expected)
    if expectedError then return expectedError end
    if expectedValue ~= nil and expectedValue ~= booking.version then
        return Result.err(Codes.VERSION_CONFLICT, 'booking version does not match', { id = id, expectedVersion = expectedValue, actualVersion = booking.version })
    end
    if type(trustedGuard) == 'function' then
        local ok, allowed = pcall(trustedGuard, booking, owner)
        local guardAllowed = allowed == true or (type(allowed) == 'table' and (
            allowed.allowed == true or
            (allowed.ok == true and (allowed.value == true or type(allowed.value) == 'table' and allowed.value.allowed == true))
        ))
        if not ok or not guardAllowed then
            return Result.err(Codes.BOOKING_GUARD_FAILED, 'trusted booking verifier rejected the transition', { target = target })
        end
    end
    metadata = copy(metadata or {})
    metadata.actorType, metadata.actorRef = owner.type, owner.ref
    metadata.correlationId = metadata.correlationId or booking.correlationId
    local transition = self._state:transition(booking, target, metadata)
    if not transition.ok then return transition end
    local nextBooking = transition.value.booking
    local merged, mergeError = Domain.apply(nextBooking, changes or {})
    if not merged then return mergeError end
    local updateChanges = copy(changes or {})
    updateChanges.status = nextBooking.status
    local persisted = self._repository:updateExpectedVersion(booking.id, booking.version, updateChanges)
    if type(persisted) ~= 'table' or not persisted.ok then return persisted end
    local timeline = self._timeline:record(booking, booking.status, nextBooking.status, metadata)
    if type(timeline) ~= 'table' or not timeline.ok then
        return Result.err(Codes.BOOKING_TIMELINE_FAILED, 'booking state changed but timeline persistence failed', {
            bookingId = booking.id,
            statePersisted = true,
            cause = type(timeline) == 'table' and timeline.error and timeline.error.code
        })
    end
    merged.version = persisted.value and persisted.value.version or nextBooking.version
    merged.id = booking.id
    merged.createdAt = booking.createdAt
    merged.updatedAt = booking.updatedAt
    return Result.ok(merged, { transition = { from = booking.status, to = nextBooking.status }, timeline = timeline.value })
end

function Service:applyQuote(actor, id, request, expected)
    local booking, bookingError = self:_get(id)
    if not booking then return bookingError end
    local owner, ownerError = self:_requireOwner(actor, booking, 'quote')
    if not owner then return ownerError end
    local quote
    local resolver = self._quote
    if type(resolver) == 'table' and type(resolver.quote) == 'function' then
        resolver = function(current, input, currentOwner)
            local request = copy(input or {})
            request.booking = current
            request.servicePackageId = current.servicePackage and current.servicePackage.id
            request.meetingMode = current.meetingMode
            request.locationRef = current.locationRef
            request.clientReputation = request.clientReputation or request.reputation
            request.context = copy(input or {})
            request.actor = currentOwner
            return self._quote:quote(request)
        end
    end
    if type(resolver) == 'function' then
        local ok, result = pcall(resolver, copy(booking), copy(request), owner)
        if not ok then return Result.err(Codes.BOOKING_INVALID, 'quote resolver failed') end
        quote, ownerError = unwrap(result, Codes.BOOKING_INVALID)
        if not quote then return ownerError end
    else
        local package = booking.servicePackage
        quote = { amountMinor = package.priceMinor, currency = package.currency or 'USD' }
    end
    quote, ownerError = quoteSnapshot(quote, booking.id)
    if not quote then return ownerError end
    return self:_transition(owner, id, 'QUOTED', expected or booking.version, { reason = 'quote-created' }, { quote = quote })
end

-- Applies a quote that was produced by another server-authoritative domain
-- (for example worker-mode negotiation). It deliberately skips client input
-- and still re-checks booking ownership, version, and quote shape.
function Service:applyAuthoritativeQuote(actor, id, quote, expected)
    local booking, bookingError = self:_get(id)
    if not booking then return bookingError end
    local owner, ownerError = self:_requireOwner(actor, booking, 'quote')
    if not owner then return ownerError end
    local snapshot, snapshotError = quoteSnapshot(quote, booking.id)
    if not snapshot then return snapshotError end
    return self:_transition(owner, id, 'QUOTED', expected or booking.version, { reason = 'authoritative-quote-created' }, { quote = snapshot })
end

function Service:offer(actor, id, expected)
    return self:_transition(actor, id, 'OFFERED', expected, { reason = 'offer-created' })
end

function Service:accept(actor, id, expected)
    local booking, bookingError = self:_get(id)
    if not booking then return bookingError end
    if type(booking.quote) ~= 'table' then return Result.err(Codes.BOOKING_INVALID, 'booking must have a quote before acceptance') end
    local agreed = booking.quote and copy(booking.quote) or nil
    if agreed then
        if PriceQuote and type(PriceQuote.new) == 'function' then
            local quote = PriceQuote.new({
                id = agreed.quoteId or ('booking:%s:quote'):format(tostring(booking.id)),
                bookingId = booking.id,
                amountMinor = agreed.amountMinor,
                currency = agreed.currency,
                issuedAt = agreed.quotedAt or timestamp(self._clock),
                expiresAt = agreed.expiresAt
            })
            if type(quote) == 'table' and type(quote.accept) == 'function' then
                local frozen, freezeError = quote:accept(timestamp(self._clock), booking.id)
                if not frozen then return freezeError end
                local snapshot = frozen.value and frozen.value.acceptedSnapshot or frozen.value
                agreed = {
                    amountMinor = snapshot.amountMinor,
                    currency = snapshot.currency,
                    agreedAt = snapshot.acceptedAt or timestamp(self._clock),
                    quoteId = snapshot.quoteId,
                    bookingId = booking.id
                }
            else
                return Result.err(Codes.QUOTE_INVALID, 'booking quote could not be normalized')
            end
        else
            agreed.agreedAt = agreed.agreedAt or timestamp(self._clock)
        end
    end
    return self:_transition(actor, id, 'ACCEPTED', expected or booking.version, { reason = 'offer-accepted' }, agreed and { agreedPrice = agreed } or nil)
end

function Service:decline(actor, id, expected, reason)
    if not text(reason, 160) then return invalid('decline reason is required') end
    return self:_transition(actor, id, 'DECLINED', expected, { reason = reason })
end

function Service:reserve(actor, id, expected, resources)
    local booking, bookingError = self:_get(id)
    if not booking then return bookingError end
    local owner, ownerError = self:_requireOwner(actor, booking, 'reserve')
    if not owner then return ownerError end
    local reservation
    if self._reservation and type(self._reservation.reserve) == 'function' and type(resources) == 'table' and #resources > 0 then
        reservation = self._reservation:reserve(tostring(booking.id), resources or {}, { booking = copy(booking) })
        if type(reservation) ~= 'table' or not reservation.ok then return reservation end
    end
    local transitioned = self:_transition(owner, id, 'RESERVED', expected or booking.version, { reason = 'resources-reserved' })
    if not transitioned.ok and reservation and self._reservation and type(self._reservation.release) == 'function' then
        local acquired = reservation.value and reservation.value.acquired or {}
        self._reservation:release(tostring(booking.id), acquired)
    end
    return transitioned
end

function Service:startTravel(actor, id, expected)
    return self:_transition(actor, id, 'TRAVELLING', expected, { reason = 'travel-started' })
end

function Service:markArrival(actor, id, expected, verifier)
    return self:_transition(actor, id, 'ARRIVED', expected, { reason = 'arrival-verified' }, nil, verifier)
end

function Service:startActive(actor, id, expected, verifier)
    return self:_transition(actor, id, 'ACTIVE', expected, { reason = 'session-started' }, { startAt = timestamp(self._clock) }, verifier)
end

function Service:complete(actor, id, expected, verifier)
    local completedAt = timestamp(self._clock)
    return self:_transition(actor, id, 'COMPLETED', expected, { reason = 'session-completed' }, { endAt = completedAt, completedAt = completedAt }, verifier)
end

function Service:settle(actor, id, expected)
    return self:_transition(actor, id, 'SETTLED', expected, { reason = 'settled' })
end

function Service:cancel(actor, id, expected, reason)
    if not text(reason, 160) then return invalid('cancellation reason is required') end
    local transitioned = self:_transition(actor, id, 'CANCELLED', expected, { reason = reason })
    if transitioned.ok and self._reservation and type(self._reservation.release) == 'function' then self._reservation:release(tostring(id)) end
    return transitioned
end

function Service:expire(actor, id, expected, reason)
    if not text(reason, 160) then return invalid('expiration reason is required') end
    local transitioned = self:_transition(actor, id, 'EXPIRED', expected, { reason = reason })
    if transitioned.ok and self._reservation and type(self._reservation.release) == 'function' then self._reservation:release(tostring(id)) end
    return transitioned
end

function Service:interrupt(actor, id, expected, reason)
    if not text(reason, 160) then return invalid('interruption reason is required') end
    local transitioned = self:_transition(actor, id, 'INTERRUPTED', expected, { reason = reason })
    if transitioned.ok and self._reservation and type(self._reservation.release) == 'function' then self._reservation:release(tostring(id)) end
    return transitioned
end

function Service:get(id)
    local booking, errorResult = self:_get(id)
    if not booking then return errorResult end
    return Result.ok(booking)
end

Service.find = Service.get

Service.create = Service.createDraft
Service.quote = Service.applyQuote
Service.applyServerQuote = Service.applyAuthoritativeQuote
Service.acceptOffer = Service.accept
NightShift.BookingService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.Booking = Service
