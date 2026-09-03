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

local function epoch(value)
    if type(value) == 'number' then
        return finite(value) and tonumber(value) or nil
    end
    if type(value) ~= 'string' then return nil end
    local year, month, day, hour, minute, second = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$')
    if not year then return nil end
    local ok, output = pcall(os.time, {
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false
    })
    if not ok or not output then return nil end
    local utcView = os.time(os.date('!*t', output))
    return output + os.difftime(output, utcView)
end

local function invalid(message, details)
    return Result.err(Codes.PICKUP_INVALID, message, details)
end

local function notReady(message, details)
    return Result.err(Codes.PICKUP_NOT_READY, message, details)
end

local function conflict(message, details)
    return Result.err(Codes.PICKUP_RECOVERY_REQUIRED, message, details)
end

local function unwrap(value, fallback, message)
    if type(value) ~= 'table' then return nil, Result.err(fallback, message or 'pickup dependency returned an invalid result') end
    if value.ok == false then return nil, value end
    if value.ok == true then return value.value or value.data end
    if value.success == true then return value.value or value.data end
    return value
end

local function invoke(service, method, ...)
    if type(service) ~= 'table' or type(service[method]) ~= 'function' then return nil, notReady(('pickup dependency "%s" is unavailable'):format(method)) end
    local ok, result = pcall(service[method], service, ...)
    if not ok then return nil, notReady(('pickup dependency "%s" failed'):format(method)) end
    return unwrap(result, Codes.PICKUP_NOT_READY, ('pickup dependency "%s" returned an invalid result'):format(method))
end

local function statusOf(booking)
    return type(booking) == 'table' and type(booking.status) == 'string' and booking.status:upper() or nil
end

local function normalizeBookingId(value)
    if integer(value, 1, 2147483647) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

local function quoteIdOf(booking)
    local quote = type(booking) == 'table' and (booking.quote or booking.quote_snapshot) or nil
    if type(quote) == 'table' then return quote.quoteId or quote.quote_id or quote.id end
    local agreed = type(booking) == 'table' and booking.agreedPrice or nil
    return type(agreed) == 'table' and (agreed.quoteId or agreed.quote_id or agreed.id) or nil
end

local function safeError(result)
    return type(result) == 'table' and (result.error or result) or {}
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('pickup mode options must be a table') end
    local booking = options.bookingService or options.booking
    local repository = options.repository or options.bookingRepository
    local identity = options.identityService or options.identity
    local worker = options.workerService or options.npcWorker
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' or type(booking.reserve) ~= 'function' or type(booking.startTravel) ~= 'function' or type(booking.markArrival) ~= 'function' then
        return nil, invalid('pickup mode requires a booking service')
    end
    if type(repository) ~= 'table' or type(repository.findByQuoteId) ~= 'function' then return nil, invalid('pickup mode requires quote lookup') end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, invalid('pickup mode requires identity resolution') end
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' or type(worker.reserve) ~= 'function' or type(worker.release) ~= 'function' then return nil, invalid('pickup mode requires NPC worker reservation') end
    local pickupLocation = options.pickupLocationService or options.pickupLocation
    local pickupVehicle = options.pickupVehicleService or options.pickupVehicle
    if type(pickupLocation) ~= 'table' or type(pickupLocation.reserve) ~= 'function' or type(pickupLocation.get) ~= 'function' then return nil, invalid('pickup mode requires a pickup location service') end
    if type(pickupVehicle) ~= 'table' or type(pickupVehicle.bind) ~= 'function' then return nil, invalid('pickup mode requires a pickup vehicle service') end
    local ttl = integer(options.reservationTtlSeconds or options.defaultTtl or 900, 1, 86400)
    if not ttl then return nil, invalid('pickup mode reservation TTL is invalid') end
    return setmetatable({
        _bookingService = booking, _repository = repository, _identity = identity, _worker = worker,
        _location = options.locationService or options.location, _locationReservation = options.locationReservationService or options.locationReservation,
        _pickupLocation = pickupLocation, _pickupVehicle = pickupVehicle, _deposit = options.depositService or options.deposit,
        _travel = options.travelService or options.npcTravel, _spawn = options.spawnService or options.npcSpawn,
        _arrival = options.arrivalService or options.npcArrival, _session = options.appointmentSessionService or options.appointmentSession,
        _settlement = options.settlementService or options.settlement, _clock = options.clock,
        _entityRegistry = options.entityRegistry or options.npcEntityRegistry,
        _reservationTtl = ttl, _travelMode = tostring(options.travelMode or 'WALK'):upper(),
        _originResolver = options.originResolver or options.travelOriginResolver,
        _contexts = {}, _pendingSettlement = {}, _sequence = 0
    }, Service)
end

function Service:_actor(playerSource)
    local source = integer(playerSource, 1, 65535)
    if not source then return nil, invalid('pickup player source is invalid') end
    local value, errorResult = invoke(self._identity, 'resolve', source)
    if not value then return nil, errorResult end
    local reference = value.identityKey or value.key or value.ref
    if not text(reference, 200) then return nil, Result.err(Codes.IDENTITY_INVALID, 'pickup identity has no safe reference') end
    return { type = 'PLAYER', ref = reference, source = source }
end

function Service:_booking(id)
    local value, errorResult = invoke(self._bookingService, 'get', id)
    if not value then return nil, errorResult end
    if tostring(value.id or value.bookingId) ~= tostring(id) then return nil, invalid('pickup booking lookup returned a mismatched booking') end
    return value
end

function Service:_validate(booking, actor)
    if tostring(booking.clientType or ''):upper() ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'player does not own this pickup booking') end
    if tostring(booking.workerType or ''):upper() ~= 'NPC' or not token(booking.workerRef, 160) then return nil, invalid('pickup booking has no NPC worker') end
    if tostring(booking.meetingMode or booking.mode or ''):upper() ~= 'PICKUP' then return nil, conflict('booking is not a PICKUP booking') end
    if not token(booking.locationType, 32) or not token(booking.locationRef, 160) then return nil, Result.err(Codes.PICKUP_DESTINATION_INVALID, 'pickup booking has no valid destination') end
    return true
end

function Service:_destination(actor, booking)
    if type(self._location) ~= 'table' or type(self._location.resolve) ~= 'function' then return nil, notReady('pickup destination resolver is unavailable') end
    local value, errorResult = invoke(self._location, 'resolve', actor.source, { locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = 'PICKUP' })
    if not value then return nil, errorResult end
    local location = value.location or value
    if type(location) ~= 'table' or tostring(location.locationRef or '') ~= tostring(booking.locationRef) then return nil, Result.err(Codes.PICKUP_DESTINATION_INVALID, 'pickup destination resolver returned a mismatched location') end
    return { locationType = location.locationType or booking.locationType, locationRef = location.locationRef, worldTarget = copy(location.worldTarget), route = copy(location.route), meetingMode = 'PICKUP' }
end

function Service:_workerProfile(booking)
    local worker, errorResult = invoke(self._worker, 'get', booking.workerRef)
    if not worker then return nil, nil, errorResult end
    local state = type(worker.state) == 'string' and worker.state:upper() or nil
    if state and state ~= 'AVAILABLE' and not (state == 'RESERVED' and tostring(worker.bookingId) == tostring(booking.id)) then return nil, nil, Result.err(Codes.NPC_WORKER_CONFLICT, 'NPC worker is no longer available') end
    local profile = worker.profile or {}
    local profileKey = worker.profileKey or worker.profileRef or profile.profileKey or profile.key or worker.workerKey
    if not token(profileKey, 160) then return nil, nil, Result.err(Codes.NPC_PROFILE_INVALID, 'pickup worker has no profile key') end
    return worker, tostring(profileKey)
end

function Service:_origin(actor, worker, context)
    if type(self._originResolver) == 'function' then
        local ok, value = pcall(self._originResolver, actor.source, copy(worker), copy(context.booking))
        if ok and type(value) == 'table' then return copy(value) end
        return nil, Result.err(Codes.TRAVEL_INVALID, 'pickup travel origin resolver failed')
    end
    local pickup = context.pickup
    if type(pickup) == 'table' and token(pickup.locationRef, 160) then return { locationType = pickup.locationType, locationRef = pickup.locationRef } end
    local district = worker.activeDistrict or worker.currentDistrict or worker.profile and worker.profile.homeDistrict
    if token(district, 64) then return { district = tostring(district):lower() } end
    return nil, Result.err(Codes.TRAVEL_INVALID, 'pickup worker has no server-known travel origin')
end

function Service:_travelKey(booking, suffix)
    local key = ('pickup-travel:%s:%s'):format(tostring(booking.id), suffix)
    return token(key, 200) and key or nil
end

function Service:_rebindEntity(context, travelKey)
    if type(self._entityRegistry) ~= 'table' or type(self._entityRegistry.updateTravel) ~= 'function' then return true end
    if not token(context.profileKey, 160) or not token(context.generationToken, 240) then
        return nil, notReady('pickup NPC generation context is unavailable')
    end
    local updated, errorResult = invoke(self._entityRegistry, 'updateTravel', context.profileKey,
        context.generationToken, travelKey, tostring(context.bookingId))
    if not updated then return nil, errorResult end
    return updated
end

function Service:_contextFor(source, bookingId, statuses)
    local actor, actorError = self:_actor(source)
    if not actor then return nil, nil, actorError end
    local id = normalizeBookingId(bookingId)
    if not id then return nil, nil, invalid('pickup booking ID is invalid') end
    local booking, bookingError = self:_booking(id)
    if not booking then return nil, nil, bookingError end
    local valid, validError = self:_validate(booking, actor)
    if not valid then return nil, nil, validError end
    local status, allowed = statusOf(booking), false
    for _, expected in ipairs(statuses or {}) do if status == expected then allowed = true; break end end
    if not allowed then return nil, nil, conflict('pickup booking is not in a valid state', { status = status }) end
    local context = self._contexts[id] or {}
    context.bookingId, context.booking, context.ownerRef, context.ownerSource = id, copy(booking), actor.ref, actor.source
    self._contexts[id] = context
    return actor, booking, nil, context
end

function Service:_rollback(actor, booking, context, reason)
    local cleanup = {}
    if context.depositAcquired and self._deposit then
        local released, errorResult = invoke(self._deposit, 'release', actor, booking)
        cleanup.deposit = released and 'released' or safeError(errorResult).code
    end
    if context.destinationAcquired and self._locationReservation and context.destinationReservationKey then
        local released, errorResult = invoke(self._locationReservation, 'release', tostring(booking.id), context.destinationReservationKey)
        cleanup.destination = released and 'released' or safeError(errorResult).code
    end
    if context.pickupAcquired and self._pickupLocation then
        local released, errorResult = invoke(self._pickupLocation, 'release', tostring(booking.id))
        cleanup.pickup = released and 'released' or safeError(errorResult).code
    end
    if context.workerAcquired then
        local released, errorResult = invoke(self._worker, 'release', booking.workerRef, tostring(booking.id))
        cleanup.worker = released and 'released' or safeError(errorResult).code
    end
    local output = copy(reason)
    output.details = output.details or {}
    output.details.rollback = cleanup
    return output
end

function Service:_confirmation(booking, context, idempotent)
    return Result.ok({
        bookingId = tostring(booking.id), booking = copy(booking), status = statusOf(booking),
        worker = copy(context.worker), location = copy(context.destination), destination = copy(context.destination),
        pickup = copy(context.pickup), pickupReservation = copy(context.pickupReservation),
        reservation = copy(context.destinationReservation), deposit = copy(context.deposit),
        phase = context.phase or 'PICKUP_PENDING'
    }, { idempotent = idempotent == true, serverAuthoritative = true })
end

function Service:_quoteFresh(booking)
    local quote = booking.quote
    if type(quote) ~= 'table' or quote.expiresAt == nil then return true end
    local expiry = epoch(quote.expiresAt)
    if not expiry then return nil, Result.err(Codes.QUOTE_INVALID, 'pickup quote expiry is invalid') end
    if now(self._clock) >= expiry then return nil, Result.err(Codes.QUOTE_EXPIRED, 'quote has expired', { quoteId = quote.quoteId or quote.id }) end
    return true
end

function Service:confirm(source, payload)
    if type(payload) ~= 'table' then return invalid('pickup confirmation payload must be a table') end
    for key in pairs(payload) do if key ~= 'quoteId' then return invalid('pickup confirmation field is not allowlisted', { field = tostring(key) }) end end
    if not text(payload.quoteId, 160) then return invalid('pickup quote ID is required') end
    local actor, actorError = self:_actor(source)
    if not actor then return actorError end
    local indexed, lookupError = invoke(self._repository, 'findByQuoteId', payload.quoteId)
    if not indexed then return lookupError end
    local id = indexed.id or indexed.bookingId
    if not id then return invalid('pickup quote lookup returned no booking ID') end
    local booking, bookingError = self:_booking(id)
    if not booking then return bookingError end
    local valid, validError = self:_validate(booking, actor)
    if not valid then return validError end
    if tostring(quoteIdOf(booking) or '') ~= tostring(payload.quoteId) then return Result.err(Codes.QUOTE_INVALID, 'quote is not bound to this pickup booking') end
    local status = statusOf(booking)
    if status == 'RESERVED' or status == 'TRAVELLING' or status == 'ARRIVED' or status == 'ACTIVE' or status == 'COMPLETED' or status == 'SETTLED' then
        return self:_confirmation(booking, self._contexts[tostring(booking.id)] or {}, true)
    end
    if status == 'QUOTED' then
        local fresh, freshError = self:_quoteFresh(booking)
        if not fresh then return freshError end
        booking, bookingError = invoke(self._bookingService, 'offer', actor, booking.id, booking.version)
        if not booking then return bookingError end
        status = statusOf(booking)
    end
    if status == 'OFFERED' then
        local fresh, freshError = self:_quoteFresh(booking)
        if not fresh then return freshError end
        booking, bookingError = invoke(self._bookingService, 'accept', actor, booking.id, booking.version)
        if not booking then return bookingError end
        status = statusOf(booking)
    end
    if status ~= 'ACCEPTED' then return conflict('pickup booking cannot be confirmed in its current state', { status = status }) end
    local fresh, freshError = self:_quoteFresh(booking)
    if not fresh then return freshError end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local idString = tostring(booking.id)
    local context = self._contexts[idString] or { bookingId = idString }
    context.worker, context.profileKey = copy(worker), profileKey
    context.workerAcquired = not (tostring(worker.state or ''):upper() == 'RESERVED' and tostring(worker.bookingId) == idString)
    local reservedWorker, reserveError = invoke(self._worker, 'reserve', booking.workerRef, idString, { ttlSeconds = self._reservationTtl })
    if not reservedWorker then return reserveError end
    context.worker = copy(reservedWorker)
    local destination, destinationError = self:_destination(actor, booking)
    if not destination then return self:_rollback(actor, booking, context, destinationError) end
    context.destination = copy(destination)
    if type(self._locationReservation) ~= 'table' or type(self._locationReservation.reserve) ~= 'function' then return self:_rollback(actor, booking, context, notReady('pickup destination reservation is unavailable')) end
    local destinationReservation, destinationReservationError = invoke(self._locationReservation, 'reserve', idString, {
        locationType = destination.locationType, locationRef = destination.locationRef, meetingMode = 'PICKUP', ttlSeconds = self._reservationTtl
    }, { source = actor.source, booking = copy(booking) })
    if not destinationReservation then return self:_rollback(actor, booking, context, destinationReservationError) end
    context.destinationReservation = copy(destinationReservation)
    context.destinationReservationKey = destinationReservation.reservationKey or destinationReservation.key or destinationReservation.id
    context.destinationAcquired = destinationReservation.idempotent ~= true
    local pickupReservation, pickupError = invoke(self._pickupLocation, 'reserve', idString, {
        district = worker.activeDistrict or worker.profile and worker.profile.homeDistrict,
        destination = copy(destination), ttlSeconds = self._reservationTtl
    }, { source = actor.source, booking = copy(booking) })
    if not pickupReservation then return self:_rollback(actor, booking, context, pickupError) end
    context.pickupReservation = copy(pickupReservation)
    context.pickup = copy(pickupReservation.pickup or pickupReservation.location or pickupReservation)
    context.pickupAcquired = pickupReservation.idempotent ~= true
    if self._deposit then
        local held, holdError = invoke(self._deposit, 'hold', actor, booking, { reason = 'pickup-reservation' })
        if not held then return self:_rollback(actor, booking, context, holdError) end
        context.deposit = copy(held)
        context.depositAcquired = held.status == 'HELD' and held.idempotent ~= true
    end
    local reserved, reserveError = invoke(self._bookingService, 'reserve', actor, booking.id, booking.version)
    if not reserved then return self:_rollback(actor, booking, context, reserveError) end
    context.booking, context.ownerRef, context.ownerSource, context.phase = copy(reserved), actor.ref, actor.source, 'PICKUP_PENDING'
    context.workerAcquired, context.destinationAcquired, context.pickupAcquired, context.depositAcquired = false, false, false, false
    context.confirmedAt = now(self._clock)
    self._contexts[idString] = context
    return self:_confirmation(reserved, context, false)
end

Service.confirmPickup = Service.confirm
Service.reserve = Service.confirm

function Service:startTravel(source, bookingId)
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'RESERVED', 'TRAVELLING' })
    if not actor then return contextError end
    local id = tostring(booking.id)
    if context.phase == 'PICKUP_TRAVELLING' and context.pickupTravelKey then
        local travel, errorResult = invoke(self._travel, 'get', context.pickupTravelKey)
        if not travel then return errorResult end
        return Result.ok({ booking = booking, travel = travel, pickup = copy(context.pickup) }, { idempotent = true, serverAuthoritative = true })
    end
    if type(self._travel) ~= 'table' or type(self._travel.create) ~= 'function' then return notReady('pickup travel service is unavailable') end
    if not context.pickup or not context.pickup.locationRef then
        local reservation = invoke(self._pickupLocation, 'get', id)
        if reservation then context.pickup = copy(reservation.pickup or reservation.location) end
    end
    if not context.pickup or not context.pickup.locationRef then return notReady('pickup location is not reserved') end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local origin, originError = self:_origin(actor, worker, context)
    if not origin then return originError end
    local key = self:_travelKey(booking, 'pickup')
    local mode = tostring(worker.travelMode or worker.profile and worker.profile.travelMode or self._travelMode):upper()
    if not (NightShift.Enums and NightShift.Enums.NpcTravelModes and NightShift.Enums.NpcTravelModes[mode]) or mode == 'UNKNOWN' then mode = self._travelMode end
    local travel, travelError = invoke(self._travel, 'create', actor.source, {
        travelKey = key, bookingId = id, workerKey = booking.workerRef, profileKey = profileKey, origin = origin,
        destination = { locationType = context.pickup.locationType, locationRef = context.pickup.locationRef, meetingMode = 'PICKUP' }, mode = mode
    })
    if not travel then return travelError end
    local moved, moveError = invoke(self._bookingService, 'startTravel', actor, booking.id, booking.version)
    if not moved then
        if type(self._travel.cancel) == 'function' then pcall(self._travel.cancel, self._travel, key, now(self._clock)) end
        return moveError
    end
    context.booking, context.pickupTravelKey, context.travelKey, context.phase = copy(moved), key, key, 'PICKUP_TRAVELLING'
    context.profileKey, context.worker = profileKey, copy(worker)
    self._contexts[id] = context
    return Result.ok({ booking = moved, travel = travel, pickup = copy(context.pickup) }, { started = true, serverAuthoritative = true })
end

Service.travel = Service.startTravel
Service.start = Service.startTravel

function Service:updateTravelProgress(source, bookingId, progress)
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local key = context.travelKey or context.pickupTravelKey or context.destinationTravelKey
    if not key then return notReady('pickup travel plan is unavailable') end
    local value, errorResult = invoke(self._travel, 'updateProgress', key, progress == nil and 1 or progress)
    if not value then return errorResult end
    return Result.ok({ booking = booking, travel = value, phase = context.phase }, { serverAuthoritative = true })
end

function Service:recoverTravel(source, bookingId, recoveryState)
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local key = context.travelKey or context.pickupTravelKey or context.destinationTravelKey
    if not key then return notReady('pickup travel plan is unavailable') end
    local value, errorResult = invoke(self._travel, 'markRecovery', key, recoveryState or 'STUCK')
    if not value then return errorResult end
    context.phase = 'RECOVERING'
    return Result.ok({ booking = booking, travel = value, phase = context.phase }, { recovered = true, serverAuthoritative = true })
end

function Service:requestSpawn(source, bookingId)
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local key = context.travelKey or context.pickupTravelKey or context.destinationTravelKey
    if not key or type(self._spawn) ~= 'table' then return notReady('pickup NPC spawn service is unavailable') end
    if context.generationToken and context.spawn then return Result.ok({ booking = booking, spawn = copy(context.spawn) }, { idempotent = true, serverAuthoritative = true }) end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local spawn, spawnError = invoke(self._spawn, 'request', actor.source, { travelKey = key, bookingId = tostring(booking.id), profileKey = profileKey })
    if not spawn then return spawnError end
    context.spawn, context.profileKey, context.generationToken = copy(spawn), profileKey, spawn.generationToken
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, spawn = spawn }, { serverAuthoritative = true })
end

Service.spawn = Service.requestSpawn

function Service:confirmSpawn(source, payload)
    if type(payload) ~= 'table' then return invalid('pickup spawn confirmation payload is invalid') end
    local id = normalizeBookingId(payload.bookingId)
    if not id then return invalid('pickup spawn confirmation booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    local allowed = { bookingId = true, travelKey = true, profileKey = true, generationToken = true, entity = true, networkId = true }
    for key in pairs(payload) do if not allowed[key] then return invalid('pickup spawn confirmation field is not allowlisted', { field = tostring(key) }) end end
    local confirmed, errorResult = invoke(self._spawn, 'confirmSpawn', actor.source, copy(payload))
    if not confirmed then return errorResult end
    context.spawn, context.generationToken, context.profileKey = copy(confirmed), confirmed.generationToken, confirmed.profileKey or context.profileKey
    self._contexts[id] = context
    return Result.ok({ booking = booking, spawn = confirmed }, { serverAuthoritative = true })
end

function Service:confirmPickupArrival(source, payload)
    local id = normalizeBookingId(payload and payload.bookingId)
    if not id then return invalid('pickup arrival booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    if context.phase ~= 'PICKUP_TRAVELLING' then return conflict('booking is not travelling to its pickup point') end
    local key = context.pickupTravelKey or context.travelKey
    local arrivalPayload = copy(payload)
    arrivalPayload.bookingId, arrivalPayload.travelKey, arrivalPayload.profileKey, arrivalPayload.generationToken = id, key, context.profileKey, context.generationToken
    if type(self._arrival) ~= 'table' or type(self._arrival.validateOnly) ~= 'function' then return notReady('pickup arrival verifier is unavailable') end
    local validated, validationError = invoke(self._arrival, 'validateOnly', actor.source, arrivalPayload)
    if not validated then return validationError end
    local marked, markError = invoke(self._travel, 'markArrival', key)
    if not marked then return markError end
    context.phase, context.pickupTravel, context.travelKey = 'PICKUP_WAITING', marked, key
    self._contexts[id] = context
    return Result.ok({ booking = booking, travel = marked, pickup = copy(context.pickup), waiting = true }, { arrived = true, serverAuthoritative = true })
end

function Service:confirmArrival(source, payload)
    local id = normalizeBookingId(payload and payload.bookingId)
    local context = id and self._contexts[id] or nil
    if context and context.phase == 'PICKUP_TRAVELLING' then return self:confirmPickupArrival(source, payload) end
    return self:confirmDestinationArrival(source, payload)
end

function Service:bindVehicle(source, payload)
    if type(payload) ~= 'table' then return invalid('pickup vehicle payload is invalid') end
    local id = normalizeBookingId(payload.bookingId)
    if not id then return invalid('pickup vehicle booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    if context.phase ~= 'PICKUP_WAITING' and context.phase ~= 'VEHICLE_BOUND' then return conflict('NPC is not waiting for pickup') end
    local binding, bindingError = invoke(self._pickupVehicle, 'bind', actor.source, payload)
    if not binding then return bindingError end
    context.vehicle, context.phase = copy(binding), 'VEHICLE_BOUND'
    self._contexts[id] = context
    return Result.ok({ booking = booking, pickup = copy(context.pickup), vehicle = binding, phase = context.phase }, { bound = true, serverAuthoritative = true })
end

Service.requestVehicle = Service.bindVehicle
Service.vehicleBind = Service.bindVehicle

function Service:enterVehicle(source, bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('pickup vehicle booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    if not context.vehicle then return Result.err(Codes.PICKUP_VEHICLE_INVALID, 'pickup vehicle is not bound') end
    local entered, enterError = invoke(self._pickupVehicle, 'confirmEntry', actor.source, { bookingId = id })
    if not entered then return enterError end
    context.vehicle, context.phase = copy(entered), 'VEHICLE_OCCUPIED'
    self._contexts[id] = context
    return Result.ok({ booking = booking, vehicle = entered, phase = context.phase }, { entered = true, serverAuthoritative = true })
end

function Service:startDestinationTravel(source, bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('pickup destination travel booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    if context.phase == 'DESTINATION_TRAVELLING' and context.destinationTravelKey then
        local travel, errorResult = invoke(self._travel, 'get', context.destinationTravelKey)
        if not travel then return errorResult end
        return Result.ok({ booking = booking, travel = travel, destination = copy(context.destination) }, { idempotent = true, serverAuthoritative = true })
    end
    if context.phase ~= 'VEHICLE_BOUND' and context.phase ~= 'VEHICLE_OCCUPIED' then return conflict('pickup vehicle must be bound before destination travel') end
    if type(self._travel) ~= 'table' or type(self._travel.create) ~= 'function' then return notReady('pickup travel service is unavailable') end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local key = self:_travelKey(booking, 'destination')
    local mode = tostring(worker.travelMode or worker.profile and worker.profile.travelMode or self._travelMode):upper()
    if not (NightShift.Enums and NightShift.Enums.NpcTravelModes and NightShift.Enums.NpcTravelModes[mode]) or mode == 'UNKNOWN' then mode = self._travelMode end
    local travel, travelError = invoke(self._travel, 'create', actor.source, {
        travelKey = key, bookingId = id, workerKey = booking.workerRef, profileKey = profileKey,
        origin = { locationType = context.pickup.locationType, locationRef = context.pickup.locationRef },
        destination = { locationType = context.destination.locationType, locationRef = context.destination.locationRef, meetingMode = 'PICKUP' },
        mode = mode
    })
    if not travel then return travelError end
    local previousTravelKey = context.pickupTravelKey or context.travelKey
    local rebound, rebindError = self:_rebindEntity(context, key)
    if not rebound then
        if type(self._travel.cancel) == 'function' then pcall(self._travel.cancel, self._travel, key, now(self._clock)) end
        return rebindError
    end
    -- The booking remains TRAVELLING; the guarded self-transition advances
    -- its version for the second physical travel leg.
    local moved, moveError = invoke(self._bookingService, 'startTravel', actor, booking.id, booking.version)
    if not moved then
        if type(self._travel.cancel) == 'function' then pcall(self._travel.cancel, self._travel, key, now(self._clock)) end
        if previousTravelKey and type(self._entityRegistry) == 'table' and type(self._entityRegistry.updateTravel) == 'function' then
            pcall(self._entityRegistry.updateTravel, self._entityRegistry, context.profileKey, context.generationToken, previousTravelKey, id)
        end
        return moveError
    end
    context.booking, context.destinationTravelKey, context.travelKey, context.phase = copy(moved), key, key, 'DESTINATION_TRAVELLING'
    self._contexts[id] = context
    return Result.ok({ booking = moved, travel = travel, destination = copy(context.destination) }, { started = true, serverAuthoritative = true })
end

Service.destinationTravel = Service.startDestinationTravel

function Service:confirmDestinationArrival(source, payload)
    local id = normalizeBookingId(payload and payload.bookingId)
    if not id then return invalid('pickup destination arrival booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'TRAVELLING' })
    if not actor then return contextError end
    if context.phase ~= 'DESTINATION_TRAVELLING' then return conflict('pickup booking is not travelling to its destination') end
    local arrivalPayload = copy(payload)
    arrivalPayload.bookingId, arrivalPayload.travelKey, arrivalPayload.profileKey, arrivalPayload.generationToken = id, context.destinationTravelKey, context.profileKey, context.generationToken
    local arrived, arrivalError = invoke(self._arrival, 'accept', actor.source, arrivalPayload)
    if not arrived then return arrivalError end
    context.booking, context.destinationTravel, context.travelKey, context.phase = copy(arrived.booking or booking), copy(arrived.travel), context.destinationTravelKey, 'DESTINATION_ARRIVED'
    self._contexts[id] = context
    return Result.ok({ booking = context.booking, travel = context.destinationTravel, destination = copy(context.destination) }, { arrived = true, serverAuthoritative = true })
end

function Service:startSession(source, bookingId, payload)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('pickup session booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'ARRIVED' })
    if not actor then return contextError end
    if type(self._session) ~= 'table' or type(self._session.start) ~= 'function' then return notReady('pickup appointment session service is unavailable') end
    local session, sessionError = invoke(self._session, 'start', actor, id, payload or {})
    if not session then return sessionError end
    context.booking, context.session, context.phase = copy(session.booking or booking), copy(session), 'ACTIVE'
    self._contexts[id] = context
    return Result.ok({ booking = context.booking, session = session, token = session.token }, { started = true, serverAuthoritative = true })
end

function Service:completeSession(source, sessionToken, payload)
    if not token(tostring(sessionToken or ''), 200) then return invalid('pickup session token is invalid') end
    local id = normalizeBookingId(payload and payload.bookingId)
    if not id then
        for key, context in pairs(self._contexts) do if context.session and context.session.token == sessionToken then id = key; break end end
    end
    if not id then return invalid('pickup session booking ID is required') end
    local actor, booking, contextError, context = self:_contextFor(source, id, { 'ACTIVE' })
    if not actor then return contextError end
    if type(self._session) ~= 'table' or type(self._session.complete) ~= 'function' then return notReady('pickup appointment session service is unavailable') end
    local completed, completeError = invoke(self._session, 'complete', actor, sessionToken, payload or { bookingId = id })
    if not completed then return completeError end
    local completedBooking = completed.booking or booking
    if type(self._settlement) ~= 'table' or type(self._settlement.settle) ~= 'function' then
        self._pendingSettlement[sessionToken] = { actor = copy(actor), booking = copy(completedBooking), context = copy(context) }
        return Result.err(Codes.SETTLEMENT_NOT_READY, 'pickup settlement service is unavailable', { pendingRetry = true, bookingId = id })
    end
    local settled, settleError = invoke(self._settlement, 'settle', actor, id)
    if not settled then
        self._pendingSettlement[sessionToken] = { actor = copy(actor), booking = copy(completedBooking), context = copy(context) }
        return settleError
    end
    context.booking, context.phase = copy(settled.booking or completedBooking), 'SETTLED'
    self._contexts[id] = context
    return Result.ok({ booking = context.booking, settlement = settled }, { completed = true, serverAuthoritative = true })
end

function Service:interrupt(source, bookingId, reason)
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'RESERVED', 'TRAVELLING', 'ARRIVED', 'ACTIVE' })
    if not actor then return contextError end
    local transitioned, transitionError = invoke(self._bookingService, 'interrupt', actor, booking.id, booking.version, reason or 'pickup-interrupted')
    if not transitioned then return transitionError end
    local cleanup = {}
    if type(self._pickupVehicle.release) == 'function' then
        local released = self._pickupVehicle:release(actor.source, { bookingId = tostring(booking.id) })
        cleanup.vehicle = type(released) == 'table' and released.ok == true and 'released' or 'failed'
    end
    if type(self._pickupLocation.release) == 'function' then
        local released = self._pickupLocation:release(tostring(booking.id))
        cleanup.pickup = type(released) == 'table' and released.ok == true and 'released' or 'failed'
    end
    if context.destinationReservationKey and self._locationReservation then
        local released = self._locationReservation:release(tostring(booking.id), context.destinationReservationKey)
        cleanup.destination = type(released) == 'table' and released.ok == true and 'released' or 'failed'
    end
    local cancelled = {}
    for _, key in ipairs({ context.pickupTravelKey, context.destinationTravelKey }) do
        if key and not cancelled[key] and self._travel and type(self._travel.cancel) == 'function' then
            cancelled[key] = true
            pcall(self._travel.cancel, self._travel, key, now(self._clock))
        end
    end
    if self._worker and type(self._worker.release) == 'function' and booking.workerRef then
        local released = self._worker:release(booking.workerRef, tostring(booking.id))
        cleanup.worker = type(released) == 'table' and released.ok == true and 'released' or 'failed'
    end
    context.booking, context.phase, context.cleanup = copy(transitioned), 'INTERRUPTED', cleanup
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = transitioned, phase = context.phase, cleanup = cleanup }, { interrupted = true, serverAuthoritative = true })
end

function Service:disconnect(source)
    local results = {}
    for id, context in pairs(self._contexts) do
        if context.ownerSource == source and context.bookingId then results[#results + 1] = self:interrupt(source, id, 'client-disconnected') end
    end
    return Result.ok(results)
end

function Service:get(bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('pickup booking ID is invalid') end
    local context = self._contexts[id]
    if not context then return Result.err(Codes.PICKUP_NOT_READY, 'pickup booking context was not found') end
    return Result.ok(copy(context))
end

NightShift.PickupModeService = Service
NightShift.Services.PickupMode = Service
