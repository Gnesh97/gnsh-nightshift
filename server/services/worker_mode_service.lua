NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

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

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and text(value, 64) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function invalid(message, details)
    return Result.err(Codes.WORKER_MODE_INVALID, message, details)
end

local function unwrap(result, fallback)
    if type(result) ~= 'table' then return nil, Result.err(fallback, 'worker mode dependency returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function sourceValue(value)
    return integer(value, 1, 65535)
end

local function sameNegotiatedQuote(existing, expected)
    if type(existing) ~= 'table' or type(expected) ~= 'table' then return false end
    local existingCurrency = type(existing.currency) == 'string' and existing.currency:upper() or existing.currency
    local expectedCurrency = type(expected.currency) == 'string' and expected.currency:upper() or expected.currency
    return tonumber(existing.amountMinor) == tonumber(expected.amountMinor)
        and existingCurrency == expectedCurrency
        and tostring(existing.quoteId or '') == tostring(expected.quoteId or '')
end

local function materializationKey(negotiation)
    local prefix = 'worker-mode:'
    local id = tostring(negotiation.id or '')
    local instance = negotiation.createdAt or negotiation.updatedAt or negotiation.expiresAt or negotiation.version
    local suffix = instance ~= nil and ':' .. tostring(instance) or ''
    local available = math.max(1, 128 - #prefix - #suffix)
    return prefix .. id:sub(1, available) .. suffix
end

local function actorInput(value)
    if type(value) == 'table' then
        local source = sourceValue(value.source)
        if not source or not text(value.ref, 200) then return nil, invalid('worker mode actor is invalid') end
        local kind = type(value.type) == 'string' and value.type:upper() or 'PLAYER'
        if kind ~= 'PLAYER' and kind ~= 'SYSTEM' and kind ~= 'ADMIN' then return nil, invalid('worker mode actor type is invalid') end
        return { type = kind, ref = value.ref, source = source }
    end
    local source = sourceValue(value)
    if not source then return nil, invalid('worker mode source must be a positive player source') end
    return { type = 'PLAYER', source = source }
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('worker mode options must be a table') end
    local customer = options.customerService or options.npcCustomerService
    local negotiation = options.negotiationService or options.negotiation
    local availability = options.workerAvailabilityService or options.workerAvailability
    local booking = options.bookingService or options.booking
    if type(customer) ~= 'table' or type(customer.get) ~= 'function' or type(customer.claim) ~= 'function' then return nil, invalid('worker mode requires an NPC customer service') end
    if type(negotiation) ~= 'table' or type(negotiation.createOffer) ~= 'function' or type(negotiation.counter) ~= 'function' or type(negotiation.accept) ~= 'function' then return nil, invalid('worker mode requires a negotiation service') end
    if type(availability) ~= 'table' or type(availability.get) ~= 'function' or type(availability.lockForBooking) ~= 'function' or type(availability.releaseBooking) ~= 'function' then return nil, invalid('worker mode requires a worker availability service') end
    if type(booking) ~= 'table' or type(booking.createDraft) ~= 'function' or type(booking.offer) ~= 'function' or type(booking.accept) ~= 'function' or type(booking.reserve) ~= 'function' or type(booking.get) ~= 'function' then return nil, invalid('worker mode requires a booking service') end
    return setmetatable({
        _customer = customer, _negotiation = negotiation, _availability = availability,
        _booking = booking, _catalog = options.serviceCatalog or options.catalog,
        _locationService = options.locationService or options.location,
        _locationReservation = options.locationReservationService or options.locationReservation,
        _session = options.appointmentSessionService or options.appointmentSession,
        _settlement = options.settlementService or options.settlement,
        _workerProfile = options.workerProfileService or options.workerProfile,
        _clock = options.clock, _contexts = {}, _profileSettled = {}
    }, Service)
end

function Service:_actor(value)
    local actor, actorError = actorInput(value)
    if not actor then return nil, actorError end
    local availability = self._availability:get(actor.source)
    local record, availabilityError = unwrap(availability, Codes.WORKER_MODE_UNAVAILABLE)
    if not record then return nil, availabilityError end
    if record.identityKey ~= nil then
        if actor.ref == nil then actor.ref = record.identityKey end
        if actor.ref ~= record.identityKey then return nil, Result.err(Codes.WORKER_MODE_UNAVAILABLE, 'worker source identity does not match availability record') end
    end
    actor.ref = actor.ref or ('source:' .. tostring(actor.source))
    return actor, record
end

function Service:_package(input)
    local packageId = input.servicePackageId or input.packageId or 'standard'
    local package
    if type(input.servicePackage) == 'table' then package = copy(input.servicePackage) end
    if not package and self._catalog and type(self._catalog.get) == 'function' then
        local result = self._catalog:get(packageId)
        package = unwrap(result, Codes.WORKER_MODE_INVALID)
        if not package then return nil, result end
    end
    if not package then return nil, Result.err(Codes.SERVICE_PACKAGE_NOT_FOUND, 'worker mode service package was not found', { id = packageId }) end
    package.id = package.id or packageId
    package.priceMinor = package.priceMinor or package.basePriceMinor or package.price
    package.durationMinutes = package.durationMinutes or package.duration
    package.currency = type(package.currency) == 'string' and package.currency:upper() or 'USD'
    if not token(tostring(package.id), 96) or not integer(package.priceMinor, 1, 100000000000) or not integer(package.durationMinutes, 1, 10080) or package.currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('worker mode service package snapshot is invalid') end
    return package
end

function Service:_resolveLocation(actor, input, package)
    local location = {
        locationType = input.locationType or input.type or 'CONFIG_LOCATION',
        locationRef = input.locationRef or input.locationId or 'configured_default',
        meetingMode = input.meetingMode or 'MEET_THERE'
    }
    location.locationType, location.meetingMode = tostring(location.locationType):upper(), tostring(location.meetingMode):upper()
    if not token(location.locationType, 32) or not token(tostring(location.locationRef), 160) or not token(location.meetingMode, 32) then return nil, invalid('worker mode location selection is invalid') end
    if self._locationService and type(self._locationService.resolve) == 'function' then
        local ok, result = pcall(self._locationService.resolve, self._locationService, actor.source, {
            locationType = location.locationType, locationRef = location.locationRef, meetingMode = location.meetingMode,
            servicePackage = copy(package), servicePackageId = package.id
        })
        if not ok or type(result) ~= 'table' then return nil, Result.err(Codes.LOCATION_INVALID, 'worker mode location resolution failed') end
        if not result.ok then return nil, result end
        local resolved = result.value and (result.value.location or result.value) or nil
        if type(resolved) == 'table' then
            location.locationType = tostring(resolved.locationType or resolved.type or location.locationType):upper()
            location.locationRef = resolved.locationRef or resolved.id or location.locationRef
            location.meetingMode = tostring(result.value.meetingMode or resolved.meetingMode or location.meetingMode):upper()
        end
    end
    return location
end

function Service:_opportunity(actor, key)
    if not token(tostring(key or ''), 200) then return nil, invalid('worker mode opportunity key is invalid') end
    local result = self._customer:get(key)
    local opportunity, errorResult = unwrap(result, Codes.WORKER_MODE_NOT_FOUND)
    if not opportunity then return nil, errorResult end
    if opportunity.source ~= nil and tonumber(opportunity.source) ~= actor.source then return nil, Result.err(Codes.WORKER_MODE_CONFLICT, 'customer opportunity belongs to another source') end
    if opportunity.identityKey ~= nil and opportunity.identityKey ~= actor.ref then return nil, Result.err(Codes.WORKER_MODE_CONFLICT, 'customer opportunity belongs to another worker') end
    return opportunity
end

function Service:start(actorInputValue, opportunityKey, input)
    input = input or {}
    if type(input) ~= 'table' then return invalid('worker mode start input must be a table') end
    local actor, availability = self:_actor(actorInputValue)
    if not actor then return availability end
    if availability.state ~= 'AVAILABLE' or availability.available ~= true then return Result.err(Codes.WORKER_MODE_UNAVAILABLE, 'worker must be available before starting worker mode') end
    local opportunity, opportunityError = self:_opportunity(actor, opportunityKey)
    if not opportunity then return opportunityError end
    if opportunity.state == 'AVAILABLE' then
        local claimed = self._customer:claim(actor.source, opportunity.opportunityKey or opportunity.key)
        local value, claimError = unwrap(claimed, Codes.WORKER_MODE_CONFLICT)
        if not value then return claimError end
        opportunity = value
    elseif opportunity.state ~= 'CLAIMED' then
        return Result.err(Codes.WORKER_MODE_CONFLICT, 'customer opportunity is not claimable', { state = opportunity.state })
    end
    local package, packageError = self:_package(input)
    if not package then return packageError end
    local location, locationError = self:_resolveLocation(actor, input, package)
    if not location then return locationError end
    local profile = opportunity.customer or opportunity.profile or {}
    local customerProfileKey = profile.profileKey or profile.key or opportunity.customerProfileKey
    if not token(tostring(customerProfileKey or ''), 160) then return invalid('customer opportunity has no profile key') end
    local negotiationResult = self._negotiation:createOffer(actor, {
        id = input.negotiationId or ('worker-negotiation:' .. tostring(opportunity.opportunityKey or opportunity.key)),
        idempotencyKey = input.idempotencyKey or ('worker-mode:' .. tostring(opportunity.opportunityKey or opportunity.key)),
        opportunityKey = opportunity.opportunityKey or opportunity.key,
        customerProfileKey = customerProfileKey,
        servicePackageId = package.id, servicePackage = package,
        basePriceMinor = package.priceMinor, currency = package.currency,
        profile = profile, budgetClass = profile.budgetClass, priceClass = profile.priceClass,
        patience = profile.traits and profile.traits.patience,
        demand = opportunity.demand, demandScore = opportunity.demandScore, demandBand = opportunity.demandBand,
        district = opportunity.district, zone = opportunity.zone,
        meetingMode = location.meetingMode, locationType = location.locationType, locationRef = location.locationRef
    })
    local negotiation, negotiationError = unwrap(negotiationResult, Codes.WORKER_MODE_INVALID)
    if not negotiation then return negotiationError end
    local context = self._contexts[negotiation.id] or {
        actor = copy(actor), opportunity = copy(opportunity), package = copy(package), location = copy(location), bookingId = nil
    }
    context.actor = copy(actor); context.opportunity = copy(opportunity); context.package = copy(package); context.location = copy(location)
    self._contexts[negotiation.id] = context
    local existingBooking
    if context.bookingId then
        local existingResult = self._booking:get(context.bookingId)
        existingBooking = unwrap(existingResult, Codes.WORKER_MODE_NOT_FOUND)
    end
    return Result.ok({ negotiation = negotiation, opportunity = opportunity, booking = existingBooking }, { started = true, serverAuthoritative = true })
end

function Service:_cleanupBooking(actor, booking, reason)
    if type(self._booking.cancel) == 'function' and booking and booking.status ~= 'CANCELLED' then
        pcall(self._booking.cancel, self._booking, actor, booking.id, booking.version, reason or 'worker-mode-rollback')
    end
end

function Service:_materialize(context, negotiation)
    if context.bookingId then
        local existing = self._booking:get(context.bookingId)
        local booking = unwrap(existing, Codes.WORKER_MODE_NOT_FOUND)
        if booking then return Result.ok({ negotiation = negotiation, booking = booking, opportunity = context.opportunity }, { idempotent = true }) end
    end
    local actor = context.actor
    local acceptedPrice = negotiation.acceptedPrice
    if type(acceptedPrice) ~= 'table' then return Result.err(Codes.WORKER_MODE_INVALID, 'accepted negotiation has no frozen price') end
    local input = {
        idempotencyKey = materializationKey(negotiation), initiatorType = 'PLAYER',
        clientType = 'NPC', clientRef = negotiation.customerProfileKey,
        workerType = 'PLAYER', workerRef = actor.ref,
        servicePackageId = context.package.id, meetingMode = context.location.meetingMode,
        locationType = context.location.locationType, locationRef = context.location.locationRef,
        correlationId = 'negotiation:' .. tostring(negotiation.id)
    }
    local draftResult = self._booking:createDraft(actor, input)
    local booking, bookingError = unwrap(draftResult, Codes.WORKER_MODE_INVALID)
    if not booking then return bookingError end
    local quote = {
        quoteId = 'negotiation:' .. tostring(negotiation.id), bookingId = booking.id,
        amountMinor = acceptedPrice.amountMinor, currency = acceptedPrice.currency,
        quotedAt = acceptedPrice.acceptedAt, expiresAt = negotiation.expiresAt
    }
    local resumable = { DRAFT = true, QUOTED = true, OFFERED = true, ACCEPTED = true }
    local alreadyMaterialized = { RESERVED = true, TRAVELLING = true, ARRIVED = true, ACTIVE = true, COMPLETED = true, SETTLED = true }
    if alreadyMaterialized[booking.status] then
        context.bookingId = booking.id
        self._contexts[negotiation.id] = context
        return Result.ok({ negotiation = negotiation, booking = booking, opportunity = context.opportunity }, { idempotent = true })
    end
    if not resumable[booking.status] then
        return Result.err(Codes.WORKER_MODE_CONFLICT, 'worker mode booking cannot resume from its current state', { status = booking.status })
    end
    if booking.status ~= 'DRAFT' and not sameNegotiatedQuote(booking.quote, quote) then
        return Result.err(Codes.WORKER_MODE_CONFLICT, 'worker mode booking quote does not match the accepted negotiation')
    end
    local shouldOffer = booking.status == 'DRAFT' or booking.status == 'QUOTED'
    local shouldAccept = shouldOffer or booking.status == 'OFFERED'
    if booking.status == 'DRAFT' then
        local authoritative = self._booking.applyAuthoritativeQuote or self._booking.applyServerQuote
        if type(authoritative) ~= 'function' then
            self:_cleanupBooking(actor, booking, 'worker-mode-authoritative-quote-unavailable')
            return Result.err(Codes.WORKER_MODE_INVALID, 'booking service does not support authoritative negotiation quotes')
        end
        local quotedResult = authoritative(self._booking, actor, booking.id, quote, booking.version)
        booking, bookingError = unwrap(quotedResult, Codes.WORKER_MODE_INVALID)
        if not booking then return bookingError end
    end
    if shouldOffer then
        local offeredResult = self._booking:offer(actor, booking.id, booking.version)
        booking, bookingError = unwrap(offeredResult, Codes.WORKER_MODE_INVALID)
        if not booking then return bookingError end
    end
    if shouldAccept then
        local acceptedResult = self._booking:accept(actor, booking.id, booking.version)
        booking, bookingError = unwrap(acceptedResult, Codes.WORKER_MODE_INVALID)
        if not booking then return bookingError end
    end
    local lockedResult = self._availability:lockForBooking(actor.source, booking.id)
    local locked, lockError = unwrap(lockedResult, Codes.WORKER_MODE_UNAVAILABLE)
    if not locked then
        self:_cleanupBooking(actor, booking, 'worker-mode-availability-lock-failed')
        return lockError
    end
    local reservation
    if self._locationReservation and type(self._locationReservation.reserve) == 'function' then
        local reservedResult = self._locationReservation:reserve(booking.id, {
            locationType = context.location.locationType, locationRef = context.location.locationRef,
            meetingMode = context.location.meetingMode, source = actor.source
        }, { source = actor.source, booking = copy(booking) })
        reservation, bookingError = unwrap(reservedResult, Codes.WORKER_MODE_INVALID)
        if not reservation then
            self._availability:releaseBooking(actor.source, booking.id, { returnAvailable = true })
            self:_cleanupBooking(actor, booking, 'worker-mode-location-reservation-failed')
            return bookingError
        end
    end
    local reservedBookingResult = self._booking:reserve(actor, booking.id, booking.version, {})
    local reservedBooking, reserveError = unwrap(reservedBookingResult, Codes.WORKER_MODE_INVALID)
    if not reservedBooking then
        if reservation and self._locationReservation and type(self._locationReservation.release) == 'function' then pcall(self._locationReservation.release, self._locationReservation, booking.id, reservation.reservationKey) end
        self._availability:releaseBooking(actor.source, booking.id, { returnAvailable = true })
        self:_cleanupBooking(actor, booking, 'worker-mode-booking-reservation-failed')
        return reserveError
    end
    context.bookingId, context.reservation = reservedBooking.id, copy(reservation)
    self._contexts[negotiation.id] = context
    return Result.ok({ negotiation = negotiation, booking = reservedBooking, opportunity = context.opportunity, reservation = reservation }, { bridged = true, serverAuthoritative = true })
end

function Service:counter(actorInputValue, negotiationId, amount, expected)
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    if not token(tostring(negotiationId or ''), 160) then return invalid('worker mode negotiation ID is invalid') end
    local context = self._contexts[tostring(negotiationId)]
    if not context then return Result.err(Codes.WORKER_MODE_NOT_FOUND, 'worker mode negotiation context was not found') end
    if context.actor.ref ~= actor.ref or context.actor.source ~= actor.source then return Result.err(Codes.WORKER_MODE_CONFLICT, 'worker mode negotiation belongs to another worker') end
    local result = self._negotiation:counter(actor, negotiationId, amount, expected)
    local negotiation, errorResult = unwrap(result, Codes.WORKER_MODE_INVALID)
    if not negotiation then return errorResult end
    if negotiation.status ~= 'ACCEPTED' then return Result.ok({ negotiation = negotiation, opportunity = context.opportunity }, { countered = true }) end
    return self:_materialize(context, negotiation)
end

function Service:accept(actorInputValue, negotiationId, expected)
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    local context = self._contexts[tostring(negotiationId)]
    if not context then return Result.err(Codes.WORKER_MODE_NOT_FOUND, 'worker mode negotiation context was not found') end
    if context.actor.ref ~= actor.ref or context.actor.source ~= actor.source then return Result.err(Codes.WORKER_MODE_CONFLICT, 'worker mode negotiation belongs to another worker') end
    if type(self._negotiation.get) == 'function' then
        local currentResult = self._negotiation:get(negotiationId)
        local current = type(currentResult) == 'table' and currentResult.ok and currentResult.value or nil
        if type(current) == 'table' and current.status == 'ACCEPTED' then
            return self:_materialize(context, current)
        end
    end
    local result = self._negotiation:accept(actor, negotiationId, expected)
    local negotiation, errorResult = unwrap(result, Codes.WORKER_MODE_INVALID)
    if not negotiation then return errorResult end
    return self:_materialize(context, negotiation)
end

function Service:_contextForBooking(actor, bookingId)
    for _, context in pairs(self._contexts) do
        if tostring(context.bookingId or '') == tostring(bookingId) then
            if context.actor.ref ~= actor.ref or context.actor.source ~= actor.source then return nil, Result.err(Codes.WORKER_MODE_CONFLICT, 'booking belongs to another worker') end
            return context
        end
    end
    return nil, Result.err(Codes.WORKER_MODE_NOT_FOUND, 'worker mode booking context was not found')
end

function Service:startTravel(actorInputValue, bookingId)
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    local context, contextError = self:_contextForBooking(actor, bookingId)
    if not context then return contextError end
    local currentResult = self._booking:get(bookingId)
    local current, currentError = unwrap(currentResult, Codes.WORKER_MODE_NOT_FOUND)
    if not current then return currentError end
    local result = self._booking:startTravel(actor, bookingId, current.version)
    return result
end

function Service:markArrival(actorInputValue, bookingId)
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    local context, contextError = self:_contextForBooking(actor, bookingId)
    if not context then return contextError end
    local currentResult = self._booking:get(bookingId)
    local current, currentError = unwrap(currentResult, Codes.WORKER_MODE_NOT_FOUND)
    if not current then return currentError end
    return self._booking:markArrival(actor, bookingId, current.version)
end

function Service:startSession(actorInputValue, bookingId, request)
    if type(self._session) ~= 'table' or type(self._session.start) ~= 'function' then return Result.err(Codes.WORKER_MODE_INVALID, 'appointment session service is unavailable') end
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    local context, contextError = self:_contextForBooking(actor, bookingId)
    if not context then return contextError end
    return self._session:start(actor, bookingId, request)
end

function Service:_updateWorkerProfile(actor, booking)
    if self._profileSettled[tostring(booking.id)] then return Result.ok(nil, { idempotent = true }) end
    if type(self._workerProfile) ~= 'table' or type(self._workerProfile.get) ~= 'function' or type(self._workerProfile.update) ~= 'function' then
        return Result.ok(nil, { deferred = true })
    end
    local currentResult = self._workerProfile:get(actor.source)
    local current, currentError = unwrap(currentResult, Codes.WORKER_MODE_INVALID)
    if not current then return currentError end
    local completed = integer(current.completedBookings or current.completed_bookings or 0, 0, 2147483646)
    if not completed then return invalid('worker profile completed counter is invalid') end
    local updated = self._workerProfile:update(actor.source, { completedBookings = completed + 1, lastActiveAt = timestamp(self._clock) })
    local profile, profileError = unwrap(updated, Codes.WORKER_MODE_INVALID)
    if not profile then return profileError end
    self._profileSettled[tostring(booking.id)] = true
    return Result.ok(profile)
end

function Service:completeSession(actorInputValue, sessionToken, request)
    if type(self._session) ~= 'table' or type(self._session.complete) ~= 'function' then return Result.err(Codes.WORKER_MODE_INVALID, 'appointment session service is unavailable') end
    local actor, actorError = self:_actor(actorInputValue)
    if not actor then return actorError end
    local completedResult = self._session:complete(actor, sessionToken, request)
    local completed, completeError = unwrap(completedResult, Codes.WORKER_MODE_INVALID)
    if not completed then return completeError end
    local booking = completed.booking
    if type(booking) ~= 'table' then return invalid('appointment session returned no completed booking') end
    if type(self._settlement) ~= 'table' or type(self._settlement.settle) ~= 'function' then return Result.err(Codes.SETTLEMENT_NOT_READY, 'worker mode settlement service is unavailable', { bookingId = booking.id }) end
    local settlementResult = self._settlement:settle(actor, booking.id, request or {})
    local settlement, settlementError = unwrap(settlementResult, Codes.SETTLEMENT_NOT_READY)
    if not settlement then return settlementError end
    local profileResult = self:_updateWorkerProfile(actor, booking)
    local profile, profileError = unwrap(profileResult, Codes.WORKER_MODE_INVALID)
    if profileError then return profileError end
    local context = self:_contextForBooking(actor, booking.id)
    if context and context.reservation and self._locationReservation and type(self._locationReservation.release) == 'function' then pcall(self._locationReservation.release, self._locationReservation, booking.id, context.reservation.reservationKey) end
    self._availability:releaseBooking(actor.source, booking.id, { returnAvailable = true })
    return Result.ok({ session = completed.session, booking = settlement.booking or booking, settlement = settlement, workerProfile = profile }, { completed = true, settled = true, profileUpdated = profile ~= nil })
end

function Service:getNegotiation(id)
    return self._negotiation:get(id)
end

NightShift.WorkerModeService = Service
NightShift.Services.WorkerMode = Service
