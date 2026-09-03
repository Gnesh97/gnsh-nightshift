NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result, Codes = NightShift.Result, NightShift.Errors.Codes
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

local function text(value, maximum) return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160) end
local function token(value, maximum) return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil end
local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end
local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
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
    if type(value) == 'number' then return finite(value) and value or nil end
    if type(value) ~= 'string' then return nil end
    local y, m, d, h, n, s = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$')
    if not y then return nil end
    local ok, output = pcall(os.time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(h), min = tonumber(n), sec = tonumber(s), isdst = false })
    if not ok or not output then return nil end
    local utc = os.time(os.date('!*t', output))
    return output + os.difftime(output, utc)
end
local function invalid(message, details) return Result.err(Codes.DUAL_TRAVEL_INVALID, message, details) end
local function notReady(message, details) return Result.err(Codes.DUAL_TRAVEL_NOT_READY, message, details) end
local function conflict(message, details) return Result.err(Codes.DUAL_TRAVEL_CONFLICT, message, details) end
local function unwrap(value, fallback, message)
    if type(value) ~= 'table' then return nil, Result.err(fallback, message or 'dual travel dependency returned an invalid result') end
    if value.ok == false then return nil, value end
    if value.ok == true then return value.value or value.data end
    if value.success == true then return value.value or value.data end
    return value
end
local function invoke(service, method, ...)
    if type(service) ~= 'table' or type(service[method]) ~= 'function' then
        return nil, notReady(('dual travel dependency "%s" is unavailable'):format(method))
    end
    local ok, result = pcall(service[method], service, ...)
    if not ok then return nil, notReady(('dual travel dependency "%s" failed'):format(method)) end
    return unwrap(result, Codes.DUAL_TRAVEL_NOT_READY, ('dual travel dependency "%s" returned an invalid result'):format(method))
end
local function statusOf(booking) return type(booking) == 'table' and type(booking.status) == 'string' and booking.status:upper() or nil end
local function bookingId(value) return type(value) == 'table' and value.id or value end
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
local function safeError(result) return type(result) == 'table' and (result.error or result) or {} end
local function allowedStatus(status, list)
    for _, value in ipairs(list or {}) do if status == value then return true end end
    return false
end
local function proximityAllowed(value)
    if value == true then return true end
    if type(value) ~= 'table' then return false end
    if value.ok == false then return nil, value end
    if value.ok == true then value = value.value end
    return value == true or type(value) == 'table' and (value.allowed == true or value.ok == true)
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('dual travel options must be a table') end
    local booking = options.bookingService or options.booking
    local repository = options.repository or options.bookingRepository
    local identity = options.identityService or options.identity
    local worker = options.workerService or options.npcWorker
    local location = options.locationService or options.location
    local reservation = options.locationReservationService or options.locationReservation
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' or type(booking.offer) ~= 'function' or type(booking.accept) ~= 'function' or
        type(booking.reserve) ~= 'function' or type(booking.startTravel) ~= 'function' or type(booking.markArrival) ~= 'function' then
        return nil, invalid('dual travel requires a booking service')
    end
    if type(repository) ~= 'table' or type(repository.findByQuoteId) ~= 'function' then return nil, invalid('dual travel requires quote lookup') end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, invalid('dual travel requires identity resolution') end
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' or type(worker.reserve) ~= 'function' or type(worker.release) ~= 'function' then
        return nil, invalid('dual travel requires NPC worker reservation')
    end
    if type(location) ~= 'table' or type(location.resolve) ~= 'function' then return nil, invalid('dual travel requires a server location resolver') end
    if type(reservation) ~= 'table' or type(reservation.reserve) ~= 'function' or type(reservation.release) ~= 'function' then
        return nil, invalid('dual travel requires location reservation')
    end
    local ttl = integer(options.reservationTtlSeconds or options.defaultTtl or 900, 1, 86400)
    local grace = integer(options.gracePeriodSeconds or options.arrivalGracePeriodSeconds or 120, 1, 86400)
    if not ttl or not grace then return nil, invalid('dual travel reservation or grace period is invalid') end
    local mode = type(options.travelMode) == 'string' and options.travelMode:upper() or 'WALK'
    if NightShift.Enums and NightShift.Enums.NpcTravelModes and (not NightShift.Enums.NpcTravelModes[mode] or mode == 'UNKNOWN') then mode = 'WALK' end
    return setmetatable({
        _bookingService = booking, _repository = repository, _identity = identity, _worker = worker,
        _location = location, _locationReservation = reservation, _deposit = options.depositService or options.deposit,
        _travel = options.travelService or options.npcTravel, _spawn = options.spawnService or options.npcSpawn,
        _arrival = options.arrivalService or options.npcArrival, _session = options.appointmentSessionService or options.appointmentSession,
        _settlement = options.settlementService or options.settlement, _refund = options.refundService or options.refund,
        _clock = options.clock, _reservationTtl = ttl, _grace = grace, _travelMode = mode,
        _originResolver = options.originResolver or options.travelOriginResolver,
        _clientProximityCheck = options.clientProximityCheck or options.meetingProximityCheck,
        _onNoShow = options.onNoShow, _reliabilityHook = options.reliabilityHook,
        _contexts = {}, _pendingSettlement = {}, _settlementInFlight = {}
    }, Service)
end

function Service:_actor(playerSource)
    local source = integer(playerSource, 1, 65535)
    if not source then return nil, invalid('dual travel player source is invalid') end
    local value, errorResult = invoke(self._identity, 'resolve', source)
    if not value then return nil, errorResult end
    local reference = value.identityKey or value.key or value.ref
    if not text(reference, 200) then return nil, Result.err(Codes.IDENTITY_INVALID, 'dual travel identity has no safe reference') end
    return { type = 'PLAYER', ref = reference, source = source }
end

function Service:_booking(id)
    local value, errorResult = invoke(self._bookingService, 'get', id)
    if not value then return nil, errorResult end
    if tostring(value.id or value.bookingId) ~= tostring(id) then return nil, invalid('dual travel booking lookup returned a mismatched booking') end
    return value
end

function Service:_validate(booking, actor)
    if tostring(booking.clientType or ''):upper() ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then
        return nil, Result.err(Codes.DUAL_TRAVEL_CONFLICT, 'player does not own this MEET_THERE booking')
    end
    if tostring(booking.workerType or ''):upper() ~= 'NPC' or not token(booking.workerRef, 160) then return nil, invalid('dual travel booking has no NPC worker') end
    if tostring(booking.meetingMode or booking.mode or ''):upper() ~= 'MEET_THERE' then return nil, conflict('booking is not a MEET_THERE booking') end
    if not token(booking.locationType, 32) or not token(booking.locationRef, 160) then
        return nil, Result.err(Codes.DUAL_TRAVEL_CONFLICT, 'dual travel booking has no valid destination')
    end
    return true
end

function Service:_quoteFresh(booking)
    local quote = booking.quote or booking.quote_snapshot
    if type(quote) ~= 'table' or quote.expiresAt == nil then return true end
    local expiry = epoch(quote.expiresAt)
    if not expiry then return nil, Result.err(Codes.QUOTE_INVALID, 'dual travel quote expiry is invalid') end
    if now(self._clock) >= expiry then return nil, Result.err(Codes.QUOTE_EXPIRED, 'quote has expired', { quoteId = quote.quoteId or quote.id }) end
    return true
end

function Service:_destination(actor, booking)
    local value, errorResult = invoke(self._location, 'resolve', actor.source, { locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = 'MEET_THERE' })
    if not value then return nil, errorResult end
    local location = value.location or value
    if type(location) ~= 'table' or tostring(location.locationRef or location.ref or '') ~= tostring(booking.locationRef) then
        return nil, Result.err(Codes.DUAL_TRAVEL_CONFLICT, 'dual travel resolver returned a mismatched destination')
    end
    return { locationType = location.locationType or location.type or booking.locationType, locationRef = location.locationRef or location.ref,
        worldTarget = copy(location.worldTarget), route = copy(location.route), meetingMode = 'MEET_THERE', reservable = location.reservable }
end

function Service:_workerProfile(booking)
    local worker, errorResult = invoke(self._worker, 'get', booking.workerRef)
    if not worker then return nil, nil, errorResult end
    local state = type(worker.state) == 'string' and worker.state:upper() or nil
    if state and state ~= 'AVAILABLE' and not (state == 'RESERVED' and tostring(worker.bookingId) == tostring(booking.id)) then
        return nil, nil, Result.err(Codes.NPC_WORKER_CONFLICT, 'NPC worker is no longer available')
    end
    local profile = worker.profile or {}
    local profileKey = worker.profileKey or worker.profileRef or profile.profileKey or profile.key or worker.workerKey
    if not token(profileKey, 160) then return nil, nil, Result.err(Codes.NPC_PROFILE_INVALID, 'dual travel worker has no profile key') end
    return worker, tostring(profileKey)
end

function Service:_origin(actor, worker, booking)
    if type(self._originResolver) == 'function' then
        local ok, value = pcall(self._originResolver, actor.source, copy(worker), copy(booking))
        if ok and type(value) == 'table' then return copy(value) end
        return nil, Result.err(Codes.TRAVEL_INVALID, 'dual travel origin resolver failed')
    end
    local profile, locationRef = worker and worker.profile or {}, worker and (worker.currentLocationId or worker.locationRef or worker.homeLocationRef)
    locationRef = locationRef or profile.currentLocationId or profile.homeLocationRef
    if token(locationRef, 160) then return { locationRef = locationRef } end
    local district = worker and (worker.activeDistrict or worker.currentDistrict or worker.district) or profile.homeDistrict or profile.district
    if token(district, 64) then return { district = tostring(district):lower() } end
    return nil, Result.err(Codes.TRAVEL_INVALID, 'dual travel worker has no server-known travel origin')
end

function Service:_travelKey(booking) return ('dual-travel:%s:worker'):format(tostring(booking.id)) end
function Service:_locationKey(booking, reservation)
    local key = type(reservation) == 'table' and (reservation.reservationKey or reservation.key) or nil
    return token(key, 200) and key or ('location:%s:%s'):format(tostring(booking.locationRef), tostring(booking.id))
end

function Service:_remember(booking, actor, worker, destination, reservation, deposit)
    local id, context = tostring(booking.id), self._contexts[tostring(booking.id)] or {}
    context.bookingId, context.booking, context.ownerRef, context.ownerSource, context.ownerActor = id, copy(booking), actor.ref, actor.source, copy(actor)
    context.workerKey, context.worker, context.destination = booking.workerRef, copy(worker), destination and copy(destination) or context.destination
    context.locationReservation, context.locationReservationKey = reservation and copy(reservation) or context.locationReservation, self:_locationKey(booking, reservation or context.locationReservation)
    context.deposit = deposit and copy(deposit) or context.deposit
    local profile = worker and worker.profile or {}
    context.profileKey = context.profileKey or worker and (worker.profileKey or worker.profileRef) or profile.profileKey or profile.key or worker and worker.workerKey
    self._contexts[id] = context
    return context
end

function Service:_hydrateContext(actor, booking)
    local id, status = tostring(booking.id), statusOf(booking)
    local context = self._contexts[id] or {}
    context.bookingId, context.booking, context.ownerRef, context.ownerSource, context.ownerActor = id, copy(booking), actor.ref, actor.source, copy(actor)
    local terminal = allowedStatus(status, { 'ARRIVED', 'ACTIVE', 'COMPLETED', 'SETTLED', 'CANCELLED', 'INTERRUPTED' })
    local needsResources = allowedStatus(status, { 'RESERVED', 'TRAVELLING', 'ARRIVAL_PENDING' })

    if not context.worker then
        local worker, profileKey, workerError = self:_workerProfile(booking)
        if worker then
            context.worker, context.workerKey, context.profileKey = copy(worker), booking.workerRef, profileKey
        elseif not terminal then
            return nil, workerError
        else
            context.worker, context.workerKey, context.profileKey = {
                workerKey = booking.workerRef, profileKey = booking.workerRef, state = 'UNKNOWN'
            }, booking.workerRef, booking.workerRef
        end
    end
    if not context.destination then
        local destination, destinationError = self:_destination(actor, booking)
        if destination then
            context.destination = copy(destination)
        elseif not terminal then
            return nil, destinationError
        else
            context.destination = {
                locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = 'MEET_THERE'
            }
        end
    end

    if needsResources and context.worker and tostring(context.worker.state or ''):upper() ~= 'RESERVED' then
        local reservedWorker, reserveError = invoke(self._worker, 'reserve', booking.workerRef, id, { ttlSeconds = self._reservationTtl })
        if not reservedWorker then
            return nil, Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'NPC worker reservation could not be rehydrated', {
                bookingId = id, cause = safeError(reserveError).code
            })
        end
        context.worker = copy(reservedWorker)
    end

    if needsResources and not context.locationReservation then
        local active
        if type(self._locationReservation.active) == 'function' then
            active = select(1, invoke(self._locationReservation, 'active', id))
            if type(active) == 'table' then
                for _, candidate in ipairs(active) do
                    if type(candidate) == 'table' and tostring(candidate.locationRef or '') == tostring(booking.locationRef) and
                        candidate.status ~= 'RELEASED' and candidate.status ~= 'EXPIRED' then
                        context.locationReservation = copy(candidate)
                        break
                    end
                end
            end
        end
        if not context.locationReservation then
            local reservation, reservationError = invoke(self._locationReservation, 'reserve', id, {
                locationType = booking.locationType, locationRef = booking.locationRef,
                meetingMode = 'MEET_THERE', ttlSeconds = self._reservationTtl
            }, { source = actor.source, booking = copy(booking) })
            if not reservation then
                return nil, Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'meeting location reservation could not be rehydrated', {
                    bookingId = id, cause = safeError(reservationError).code
                })
            end
            context.locationReservation = copy(reservation)
        end
        context.locationReservationKey = self:_locationKey(booking, context.locationReservation)
    end

    if status == 'RESERVED' and not context.phase then context.phase = 'RESERVED' end
    if status == 'TRAVELLING' then
        if context.phase ~= 'CLIENT_ARRIVED' and context.phase ~= 'WORKER_ARRIVED' then context.phase = 'TRAVELLING' end
        context.travelKey = context.travelKey or self:_travelKey(booking)
        if not context.travel and type(self._travel) == 'table' and type(self._travel.get) == 'function' then
            local travel = select(1, invoke(self._travel, 'get', context.travelKey))
            if travel then context.travel = copy(travel) else context.travelMissing = true end
        end
    elseif status == 'ARRIVED' then
        context.phase, context.clientArrived, context.workerArrived = 'ARRIVED', true, true
    elseif status == 'ACTIVE' then
        context.phase = 'ACTIVE'
    elseif status == 'COMPLETED' then
        context.phase = 'COMPLETED'
    elseif status == 'SETTLED' then
        context.phase = 'SETTLED'
    elseif status == 'CANCELLED' or status == 'INTERRUPTED' then
        context.phase = status
    end
    self._contexts[id] = context
    return context
end

function Service:_contextFor(playerSource, id, statuses)
    local actor, actorError = self:_actor(playerSource)
    if not actor then return nil, nil, actorError end
    id = normalizeBookingId(id)
    if not id then return nil, nil, invalid('dual travel booking ID is invalid') end
    local booking, bookingError = self:_booking(id)
    if not booking then return nil, nil, bookingError end
    local valid, validError = self:_validate(booking, actor)
    if not valid then return nil, nil, validError end
    local status = statusOf(booking)
    if not allowedStatus(status, statuses) then return nil, nil, conflict('dual travel booking is not in a valid state', { status = status }) end
    local context, hydrateError = self:_hydrateContext(actor, booking)
    if not context then return nil, nil, hydrateError end
    return actor, booking, nil, context
end

function Service:_confirmation(booking, context, idempotent)
    return Result.ok({
        bookingId = tostring(booking.id), booking = copy(booking), status = statusOf(booking), phase = context.phase or 'RESERVED',
        clientArrived = context.clientArrived == true, workerArrived = context.workerArrived == true, outcome = context.outcome,
        worker = copy(context.worker), destination = copy(context.destination), location = copy(context.destination),
        reservation = copy(context.locationReservation), deposit = copy(context.deposit), travel = copy(context.travel),
        spawn = copy(context.spawn), session = copy(context.session), token = context.sessionToken,
        travelKey = context.travelKey, profileKey = context.profileKey, generationToken = context.generationToken
    }, { idempotent = idempotent == true, serverAuthoritative = true })
end

function Service:_rollback(actor, booking, context, reason)
    local cleanup = {}
    if context.depositAcquired and self._deposit then
        local released, errorResult = invoke(self._deposit, 'release', actor, booking)
        cleanup.deposit = released and 'released' or safeError(errorResult).code or 'failed'
    end
    if context.locationAcquired and context.locationReservationKey then
        local released, errorResult = invoke(self._locationReservation, 'release', tostring(booking.id), context.locationReservationKey)
        cleanup.location = released and 'released' or safeError(errorResult).code or 'failed'
    end
    if context.workerAcquired then
        local released, errorResult = invoke(self._worker, 'release', booking.workerRef, tostring(booking.id))
        cleanup.worker = released and 'released' or safeError(errorResult).code or 'failed'
    end
    local output = copy(reason)
    output.details = output.details or {}
    output.details.rollback = cleanup
    return output
end

function Service:confirm(playerSource, payload)
    if type(payload) ~= 'table' then return invalid('dual travel confirmation payload must be a table') end
    for key in pairs(payload) do if key ~= 'quoteId' then return invalid('dual travel confirmation field is not allowlisted', { field = tostring(key) }) end end
    if not text(payload.quoteId, 160) then return invalid('dual travel quote ID is required') end
    local actor, actorError = self:_actor(playerSource)
    if not actor then return actorError end
    local indexed, lookupError = invoke(self._repository, 'findByQuoteId', payload.quoteId)
    if not indexed then
        if safeError(lookupError).code == Codes.REPOSITORY_NOT_FOUND then return Result.err(Codes.BOOKING_NOT_FOUND, 'booking for quote was not found') end
        return lookupError
    end
    local id = indexed.id or indexed.bookingId
    if not id then return invalid('dual travel quote lookup returned no booking ID') end
    local booking, bookingError = self:_booking(id)
    if not booking then return bookingError end
    local valid, validError = self:_validate(booking, actor)
    if not valid then return validError end
    if tostring(quoteIdOf(booking) or '') ~= tostring(payload.quoteId) then return Result.err(Codes.QUOTE_INVALID, 'quote is not bound to this MEET_THERE booking') end
    local status = statusOf(booking)
    if status == 'RESERVED' or status == 'TRAVELLING' or status == 'ARRIVED' or status == 'ACTIVE' or status == 'COMPLETED' or status == 'SETTLED' or status == 'CANCELLED' then
        local context = self._contexts[tostring(booking.id)]
        if not context then
            local _, _, hydrateError, hydrated = self:_contextFor(actor.source, booking.id, { status })
            context = hydrated
            if not context and status ~= 'CANCELLED' then
                return Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'dual travel booking context could not be restored after restart', {
                    bookingId = tostring(booking.id), cause = safeError(hydrateError).code
                })
            end
        end
        if context then return self:_confirmation(booking, context, true) end
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
    if status ~= 'ACCEPTED' then return conflict('dual travel booking cannot be confirmed in its current state', { status = status }) end
    local fresh, freshError = self:_quoteFresh(booking)
    if not fresh then return freshError end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local context = self._contexts[tostring(booking.id)] or {}
    context.worker, context.workerKey, context.profileKey = copy(worker), booking.workerRef, profileKey
    context.workerAcquired = not (tostring(worker.state or ''):upper() == 'RESERVED' and tostring(worker.bookingId) == tostring(booking.id))
    local reservedWorker, reserveWorkerError = invoke(self._worker, 'reserve', booking.workerRef, tostring(booking.id), { ttlSeconds = self._reservationTtl })
    if not reservedWorker then return reserveWorkerError end
    context.worker = copy(reservedWorker)
    local destination, destinationError = self:_destination(actor, booking)
    if not destination then return self:_rollback(actor, booking, context, destinationError) end
    context.destination = copy(destination)
    local reservation, reservationError = invoke(self._locationReservation, 'reserve', tostring(booking.id), {
        locationType = destination.locationType, locationRef = destination.locationRef, meetingMode = 'MEET_THERE', ttlSeconds = self._reservationTtl
    }, { source = actor.source, booking = copy(booking) })
    if not reservation then return self:_rollback(actor, booking, context, reservationError) end
    context.locationReservation, context.locationReservationKey = copy(reservation), self:_locationKey(booking, reservation)
    context.locationAcquired = not (reservation.idempotent == true)
    if self._deposit then
        local held, holdError = invoke(self._deposit, 'hold', actor, booking, { reason = 'dual-travel-reservation' })
        if not held then return self:_rollback(actor, booking, context, holdError) end
        context.deposit, context.depositAcquired = copy(held), held.status == 'HELD' and not held.idempotent
    end
    local reserved, reserveError = invoke(self._bookingService, 'reserve', actor, booking.id, booking.version)
    if not reserved then return self:_rollback(actor, booking, context, reserveError) end
    context = self:_remember(reserved, actor, context.worker, destination, context.locationReservation, context.deposit)
    context.phase, context.clientArrived, context.workerArrived = 'RESERVED', false, false
    context.workerAcquired, context.locationAcquired, context.depositAcquired = false, false, false
    context.confirmedAt = now(self._clock)
    self._contexts[tostring(reserved.id)] = context
    return self:_confirmation(reserved, context, false)
end

Service.reserve = Service.confirm
Service.confirmMeetThere = Service.confirm

function Service:_travelContext(booking, context)
    if not token(context.travelKey, 200) then return nil, notReady('dual travel plan is not ready') end
    local travel, travelError = invoke(self._travel, 'get', context.travelKey)
    if not travel then
        if safeError(travelError).code == Codes.TRAVEL_NOT_FOUND or context.travelMissing then
            return nil, Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'dual travel plan was lost across restart', {
                bookingId = tostring(booking.id), travelKey = context.travelKey
            })
        end
        return nil, travelError
    end
    if tostring(travel.bookingId) ~= tostring(booking.id) or tostring(travel.profileKey) ~= tostring(context.profileKey) then return nil, conflict('dual travel plan does not match the booking') end
    return travel
end

function Service:startTravel(playerSource, bookingId)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'RESERVED', 'TRAVELLING' })
    if not actor then return contextError end
    if statusOf(booking) == 'TRAVELLING' and context.travelKey then
        local travel, travelError = self:_travelContext(booking, context)
        if not travel then return travelError end
        return Result.ok({ booking = booking, travel = travel, destination = copy(context.destination) }, { idempotent = true, serverAuthoritative = true })
    end
    if type(self._travel) ~= 'table' or type(self._travel.create) ~= 'function' then return notReady('dual travel service is unavailable') end
    local worker, profileKey, workerError = self:_workerProfile(booking)
    if not worker then return workerError end
    local origin, originError = self:_origin(actor, worker, booking)
    if not origin then return originError end
    local key, mode = self:_travelKey(booking), tostring(worker.travelMode or worker.profile and worker.profile.travelMode or self._travelMode):upper()
    if NightShift.Enums and NightShift.Enums.NpcTravelModes and (not NightShift.Enums.NpcTravelModes[mode] or mode == 'UNKNOWN') then mode = self._travelMode end
    local travel, travelError = invoke(self._travel, 'create', actor.source, {
        travelKey = key, bookingId = tostring(booking.id), workerKey = booking.workerRef, profileKey = profileKey, origin = origin,
        destination = { locationType = context.destination.locationType, locationRef = context.destination.locationRef, meetingMode = 'MEET_THERE' }, mode = mode
    })
    if not travel then return travelError end
    local moved, moveError = invoke(self._bookingService, 'startTravel', actor, booking.id, booking.version)
    if not moved then
        if self._travel and type(self._travel.cancel) == 'function' then pcall(self._travel.cancel, self._travel, key, now(self._clock)) end
        return moveError
    end
    context = self:_remember(moved, actor, worker, context.destination, context.locationReservation, context.deposit)
    context.travelKey, context.travel, context.profileKey, context.phase = key, copy(travel), profileKey, 'TRAVELLING'
    context.clientArrived, context.workerArrived = false, false
    self._contexts[tostring(moved.id)] = context
    return Result.ok({ booking = moved, travel = travel, destination = copy(context.destination) }, { started = true, serverAuthoritative = true })
end

Service.travel = Service.startTravel
Service.start = Service.startTravel

function Service:updateTravelProgress(playerSource, bookingId, progress)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'TRAVELLING', 'ARRIVAL_PENDING' })
    if not actor then return contextError end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    if progress == nil then
        local eta, started = tonumber(travel.etaSeconds), tonumber(travel.startedAt)
        if eta and eta > 0 and started then progress = math.max(0, math.min(1, (now(self._clock) - started) / eta)) end
    end
    local updated, updateError = invoke(self._travel, 'updateProgress', context.travelKey, progress == nil and travel.progress or progress)
    if not updated then return updateError end
    context.travel = copy(updated)
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, travel = updated, phase = context.phase }, { serverAuthoritative = true })
end

function Service:recoverTravel(playerSource, bookingId, recoveryState)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'TRAVELLING', 'ARRIVAL_PENDING' })
    if not actor then return contextError end
    recoveryState = type(recoveryState) == 'string' and recoveryState:upper() or 'STUCK'
    if not NightShift.Enums.NpcTravelRecoveryStates[recoveryState] then return invalid('dual travel recovery state is invalid') end
    local updated, updateError = invoke(self._travel, 'markRecovery', context.travelKey, recoveryState)
    if not updated then return updateError end
    context.travel, context.phase = copy(updated), 'RECOVERING'
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, travel = updated, phase = context.phase }, { recovered = true, serverAuthoritative = true })
end

function Service:requestSpawn(playerSource, bookingId)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'TRAVELLING', 'ARRIVAL_PENDING' })
    if not actor then return contextError end
    if type(self._spawn) ~= 'table' or type(self._spawn.request) ~= 'function' then return self:_noShow(actor, booking, context, Codes.WORKER_NO_SHOW, 'npc-spawn-service-unavailable') end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    if context.spawn and context.generationToken then return Result.ok({ booking = booking, travel = travel, spawn = copy(context.spawn) }, { idempotent = true, serverAuthoritative = true }) end
    local spawn, spawnError = invoke(self._spawn, 'request', actor.source, { travelKey = context.travelKey, bookingId = tostring(booking.id), profileKey = context.profileKey })
    if not spawn then
        local code = safeError(spawnError).code
        if code ~= Codes.NPC_SPAWN_CONTEXT_REQUIRED and code ~= Codes.TRAVEL_NOT_FOUND then return self:_noShow(actor, booking, context, Codes.WORKER_NO_SHOW, 'npc-spawn-failed', spawnError) end
        return spawnError
    end
    context.spawn, context.generationToken = copy(spawn), spawn.generationToken
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, travel = travel, spawn = spawn, travelKey = context.travelKey, bookingId = tostring(booking.id),
        profileKey = context.profileKey, generationToken = spawn.generationToken, entity = spawn.entity, networkId = spawn.networkId }, { serverAuthoritative = true })
end

Service.spawn = Service.requestSpawn

local spawnFields = { bookingId = true, travelKey = true, profileKey = true, generationToken = true, entity = true, networkId = true, spawn = true }
function Service:confirmSpawn(playerSource, payload)
    if type(payload) ~= 'table' then return invalid('dual travel spawn confirmation payload is invalid') end
    for key in pairs(payload) do if not spawnFields[key] then return invalid('dual travel spawn field is not allowlisted', { field = tostring(key) }) end end
    local raw = type(payload.spawn) == 'table' and payload.spawn or payload
    local id = normalizeBookingId(raw.bookingId or payload.bookingId)
    if not id then return invalid('dual travel spawn confirmation booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(playerSource, id, { 'TRAVELLING', 'ARRIVAL_PENDING' })
    if not actor then return contextError end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local profileKey, generationToken = raw.profileKey or context.profileKey, raw.generationToken or context.generationToken
    if not token(profileKey, 160) or not token(generationToken, 240) then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'dual travel spawn confirmation is missing generation context') end
    if type(self._spawn) ~= 'table' or type(self._spawn.confirmSpawn) ~= 'function' then return notReady('dual travel NPC spawn service is unavailable') end
    local bound, boundError = invoke(self._spawn, 'confirmSpawn', actor.source, {
        profileKey = profileKey, travelKey = context.travelKey, bookingId = id, generationToken = generationToken,
        entity = raw.entity, networkId = raw.networkId
    })
    if not bound then return boundError end
    context.spawn, context.generationToken, context.profileKey = copy(bound), bound.generationToken or generationToken, profileKey
    self._contexts[id] = context
    return Result.ok({ booking = booking, travel = travel, spawn = bound, travelKey = context.travelKey, bookingId = id,
        profileKey = profileKey, generationToken = context.generationToken, entity = bound.entity, networkId = bound.networkId }, { serverAuthoritative = true })
end

local npcArrivalFields = { bookingId = true, travelKey = true, profileKey = true, generationToken = true, entity = true, networkId = true, position = true }
function Service:confirmClientArrival(playerSource, payload)
    if type(payload) ~= 'table' then return invalid('dual travel client arrival payload is invalid') end
    for key in pairs(payload) do if key ~= 'bookingId' and key ~= 'position' then return invalid('dual travel client arrival field is not allowlisted', { field = tostring(key) }) end end
    local id = normalizeBookingId(payload.bookingId)
    if not id then return invalid('dual travel client arrival booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(playerSource, id, { 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED' })
    if not actor then return contextError end
    if statusOf(booking) == 'ARRIVED' then return self:_confirmation(booking, context, true) end
    if context.clientArrived then return self:_barrier(actor, booking, context) end
    if type(self._clientProximityCheck) ~= 'function' then return Result.err(Codes.DUAL_TRAVEL_PROXIMITY_UNAVAILABLE, 'server client proximity verifier is unavailable') end
    local ok, value = pcall(self._clientProximityCheck, actor.source, copy(booking), copy(context.destination), copy(payload), copy(context))
    if not ok then return Result.err(Codes.DUAL_TRAVEL_PROXIMITY_INVALID, 'server client proximity verifier failed') end
    local allowed, allowedError
    if value == true then allowed = true
    elseif type(value) == 'table' and value.ok == false then allowed, allowedError = nil, value
    elseif type(value) == 'table' and value.ok == true then allowed = value.value == true or type(value.value) == 'table' and value.value.allowed == true
    elseif type(value) == 'table' then allowed = value.allowed == true end
    if allowedError then return allowedError end
    if not allowed then return Result.err(Codes.DUAL_TRAVEL_PROXIMITY_INVALID, 'client is not at the server destination') end
    context.clientArrived, context.clientArrivedAt, context.phase = true, now(self._clock), 'CLIENT_ARRIVED'
    self._contexts[id] = context
    return self:_barrier(actor, booking, context)
end

function Service:confirmNpcArrival(playerSource, payload)
    if type(payload) ~= 'table' then return invalid('dual travel NPC arrival payload is invalid') end
    for key in pairs(payload) do if not npcArrivalFields[key] then return invalid('dual travel NPC arrival field is not allowlisted', { field = tostring(key) }) end end
    local id = normalizeBookingId(payload.bookingId)
    if not id then return invalid('dual travel NPC arrival booking ID is invalid') end
    local actor, booking, contextError, context = self:_contextFor(playerSource, id, { 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED' })
    if not actor then return contextError end
    if statusOf(booking) == 'ARRIVED' then return self:_confirmation(booking, context, true) end
    if context.workerArrived then return self:_barrier(actor, booking, context) end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local profileKey, generationToken = payload.profileKey or context.profileKey, payload.generationToken or context.generationToken
    if not token(profileKey, 160) or not token(generationToken, 240) then return Result.err(Codes.DUAL_TRAVEL_ARRIVAL_INVALID, 'dual travel NPC arrival is missing generation context') end
    if type(self._arrival) ~= 'table' or type(self._arrival.validateOnly) ~= 'function' then return Result.err(Codes.DUAL_TRAVEL_ARRIVAL_INVALID, 'server NPC arrival verifier is unavailable') end
    local validated, validationError = invoke(self._arrival, 'validateOnly', actor.source, {
        travelKey = context.travelKey, bookingId = id, profileKey = profileKey, generationToken = generationToken,
        entity = payload.entity, networkId = payload.networkId, position = payload.position
    })
    if not validated then return validationError end
    local marked, markError = invoke(self._travel, 'markArrival', context.travelKey)
    if not marked then return markError end
    context.workerArrived, context.workerArrivedAt, context.travel, context.phase = true, now(self._clock), copy(marked), 'WORKER_ARRIVED'
    context.generationToken = generationToken
    self._contexts[id] = context
    return self:_barrier(actor, booking, context)
end

function Service:_barrier(actor, booking, context)
    if not context.clientArrived or not context.workerArrived then
        local waitingFor = context.clientArrived and 'WORKER' or context.workerArrived and 'CLIENT' or 'BOTH'
        return Result.ok({ booking = copy(booking), travel = copy(context.travel), phase = context.phase,
            clientArrived = context.clientArrived == true, workerArrived = context.workerArrived == true,
            waiting = true, waitingFor = waitingFor, destination = copy(context.destination) }, { waiting = true, serverAuthoritative = true })
    end
    if statusOf(booking) == 'ARRIVED' then context.phase = 'ARRIVED'; return self:_confirmation(booking, context, true) end
    local marked, markError = invoke(self._bookingService, 'markArrival', actor, booking.id, booking.version, function() return true end)
    if not marked then return markError end
    context.booking, context.phase = copy(marked), 'ARRIVED'
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = marked, travel = copy(context.travel), phase = context.phase,
        clientArrived = true, workerArrived = true, destination = copy(context.destination) }, { arrived = true, serverAuthoritative = true })
end

Service.confirmArrival = Service.confirmClientArrival
Service.arrival = Service.confirmClientArrival
Service.clientArrival = Service.confirmClientArrival
Service.npcArrival = Service.confirmNpcArrival

function Service:_cancelTravel(context)
    if context and context.travelKey and self._travel and type(self._travel.cancel) == 'function' then pcall(self._travel.cancel, self._travel, context.travelKey, now(self._clock)) end
end

function Service:_releaseResources(booking, context, releaseDeposit)
    local cleanup = {}
    if context and context.locationReservationKey then
        local released, errorResult = invoke(self._locationReservation, 'release', tostring(booking.id), context.locationReservationKey)
        cleanup.location = released and 'released' or safeError(errorResult).code or 'failed'
    end
    if context and booking.workerRef then
        local released, errorResult = invoke(self._worker, 'release', booking.workerRef, tostring(booking.id))
        cleanup.worker = released and 'released' or safeError(errorResult).code or 'failed'
    end
    if releaseDeposit and self._deposit then
        local released, errorResult = invoke(self._deposit, 'release', context and context.ownerActor, booking)
        cleanup.deposit = released and 'released' or safeError(errorResult).code or 'failed'
    end
    return cleanup
end

local function cleanupNeedsRecovery(cleanup, refundError)
    if refundError then return true end
    for _, status in pairs(cleanup or {}) do
        if status ~= 'released' then return true end
    end
    return false
end

function Service:_refundNoShow(actor, booking, context)
    if self._refund and type(self._refund.refund) == 'function' then
        local refunded, refundError = invoke(self._refund, 'refund', actor, booking, { reason = context.outcome })
        if refunded and refunded.status ~= 'DISABLED' then return refunded, nil, false end
        if refundError then
            local released = self._deposit and invoke(self._deposit, 'release', actor, booking) or nil
            return refunded, refundError, released ~= nil
        end
    end
    if self._deposit then
        local released, releaseError = invoke(self._deposit, 'release', actor, booking)
        return nil, releaseError, released ~= nil
    end
    return nil, nil, false
end

function Service:_noShow(actor, booking, context, outcomeCode, reason, cause)
    if context.outcome and not context.recoveryRequired then
        return Result.err(context.outcome, 'dual travel no-show has already been finalized', { bookingId = tostring(booking.id), idempotent = true, outcome = context.outcome })
    end
    if context.outcome and context.recoveryRequired then
        local cleanup = self:_releaseResources(context.booking or booking, context, false)
        local refund, refundError, depositReleased = self:_refundNoShow(actor, context.previousBooking or booking, context)
        if depositReleased and not cleanup.deposit then cleanup.deposit = 'released' end
        context.cleanup, context.refund = cleanup, refund
        self._contexts[tostring(booking.id)] = context
        if not cleanupNeedsRecovery(cleanup, refundError) then
            context.recoveryRequired = false
            return Result.err(context.outcome, 'dual travel no-show recovered after retry', {
                bookingId = tostring(booking.id), idempotent = true, recovered = true, outcome = context.outcome
            })
        end
        return Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'dual travel no-show cleanup still requires recovery', {
            bookingId = tostring(booking.id), outcome = context.outcome, cleanup = copy(cleanup),
            refundError = refundError and copy(safeError(refundError))
        })
    end
    local before = copy(booking)
    local cancelled, cancelError = invoke(self._bookingService, 'cancel', actor, booking.id, booking.version, ('dual-travel-%s'):format(tostring(reason or 'no-show')))
    if not cancelled then return cancelError end
    context.booking, context.previousBooking, context.outcome, context.outcomeReason, context.phase, context.noShowAt =
        copy(cancelled), before, outcomeCode, reason, 'NO_SHOW', now(self._clock)
    self:_cancelTravel(context)
    local cleanup = self:_releaseResources(cancelled, context, false)
    local refund, refundError, depositReleased = self:_refundNoShow(actor, before, context)
    if depositReleased and not cleanup.deposit then cleanup.deposit = 'released' end
    context.cleanup, context.refund = cleanup, refund
    self._contexts[tostring(cancelled.id)] = context
    local hookPayload = { booking = copy(cancelled), previousBooking = before, outcome = outcomeCode, reason = reason,
        cleanup = copy(cleanup), refund = copy(refund), refundError = refundError and copy(safeError(refundError)), cause = cause and safeError(cause).code }
    if type(self._onNoShow) == 'function' then pcall(self._onNoShow, copy(hookPayload)) end
    if type(self._reliabilityHook) == 'function' then pcall(self._reliabilityHook, copy(hookPayload)) end
    if cleanupNeedsRecovery(cleanup, refundError) then
        context.recoveryRequired = true
        hookPayload.recoveryRequired = true
        return Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'no-show recorded but cleanup or refund requires recovery', hookPayload)
    end
    return Result.err(outcomeCode, outcomeCode == Codes.CLIENT_NO_SHOW and 'client did not arrive before the grace period' or 'NPC worker did not arrive before the grace period', hookPayload)
end

function Service:tick(playerSource, bookingId, at)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'RESERVED', 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED' })
    if not actor then return contextError end
    at = at == nil and now(self._clock) or tonumber(at)
    if not finite(at) then return invalid('dual travel tick timestamp is invalid') end
    if statusOf(booking) == 'ARRIVED' then return self:_confirmation(booking, context, true) end
    if context.clientArrived and context.workerArrived then return self:_barrier(actor, booking, context) end
    if context.clientArrived and not context.workerArrived and context.clientArrivedAt and at >= context.clientArrivedAt + self._grace then
        return self:_noShow(actor, booking, context, Codes.WORKER_NO_SHOW, 'worker-grace-expired')
    end
    if context.workerArrived and not context.clientArrived and context.workerArrivedAt and at >= context.workerArrivedAt + self._grace then
        return self:_noShow(actor, booking, context, Codes.CLIENT_NO_SHOW, 'client-grace-expired')
    end
    local expected = context.travel and tonumber(context.travel.expectedArrivalAt)
    if not context.clientArrived and not context.workerArrived and expected and at >= expected + self._grace then
        return self:_noShow(actor, booking, context, Codes.WORKER_NO_SHOW, 'worker-arrival-timeout')
    end
    local deadline
    if context.clientArrivedAt and not context.workerArrived then deadline = context.clientArrivedAt + self._grace end
    if context.workerArrivedAt and not context.clientArrived then deadline = context.workerArrivedAt + self._grace end
    return Result.ok({ booking = booking, phase = context.phase, waiting = true, clientArrived = context.clientArrived == true,
        workerArrived = context.workerArrived == true, graceRemainingSeconds = deadline and math.max(0, deadline - at) or nil },
        { waiting = true, serverAuthoritative = true })
end

local sessionFields = { bookingId = true, locationType = true, locationRef = true, meetingMode = true, token = true }
function Service:startSession(playerSource, bookingId, payload)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'ARRIVED', 'ACTIVE' })
    if not actor then return contextError end
    if statusOf(booking) == 'ACTIVE' and context.session then
        return Result.ok({ booking = booking, session = copy(context.session), token = context.sessionToken }, { idempotent = true, serverAuthoritative = true })
    end
    if type(payload) ~= 'table' then payload = {} end
    for key in pairs(payload) do if not sessionFields[key] then return invalid('dual travel session field is not allowlisted', { field = tostring(key) }) end end
    if type(self._session) ~= 'table' or type(self._session.start) ~= 'function' then return notReady('dual travel appointment session service is unavailable') end
    local started, startError = invoke(self._session, 'start', actor, tostring(booking.id), {
        bookingId = tostring(booking.id), locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = 'MEET_THERE'
    })
    if not started then return startError end
    context.booking, context.session, context.sessionToken, context.phase, context.activeAt = copy(started.booking or booking), copy(started), started.token, 'ACTIVE', now(self._clock)
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = context.booking, session = started, token = started.token }, { started = true, serverAuthoritative = true })
end

Service.sessionStart = Service.startSession

function Service:_settle(actor, booking, context)
    local id = tostring(booking.id)
    if statusOf(booking) == 'SETTLED' then
        local cleanup = self:_releaseResources(booking, context, false)
        context.phase, context.cleanup = 'SETTLED', cleanup
        return { booking = booking, status = 'SETTLED', cleanup = cleanup }
    end
    if type(self._settlement) ~= 'table' or type(self._settlement.settle) ~= 'function' then
        self._pendingSettlement[id] = { actor = copy(actor), context = copy(context), booking = copy(booking), sessionToken = context.sessionToken }
        return nil, Result.err(Codes.SETTLEMENT_NOT_READY, 'dual travel settlement service is unavailable', { pendingRetry = true, bookingId = id })
    end
    if self._settlementInFlight[id] then return nil, Result.err(Codes.SETTLEMENT_IN_PROGRESS, 'dual travel settlement is already in progress', { bookingId = id }) end
    self._settlementInFlight[id] = true
    local settled, settlementError = invoke(self._settlement, 'settle', actor, id, { bookingId = id, locationType = booking.locationType, locationRef = booking.locationRef })
    self._settlementInFlight[id] = nil
    if not settled then
        self._pendingSettlement[id] = { actor = copy(actor), context = copy(context), booking = copy(booking), sessionToken = context.sessionToken }
        return nil, settlementError
    end
    self._pendingSettlement[id] = nil
    local finalBooking, cleanup = settled.booking or booking, self:_releaseResources(settled.booking or booking, context, false)
    context.booking, context.phase, context.settlement, context.cleanup = copy(finalBooking), 'SETTLED', copy(settled), cleanup
    self._contexts[id] = context
    return { booking = finalBooking, settlement = settled, cleanup = cleanup }
end

function Service:completeSession(playerSource, sessionToken, payload)
    if not token(tostring(sessionToken or ''), 200) then return invalid('dual travel session token is invalid') end
    payload = type(payload) == 'table' and payload or {}
    for key in pairs(payload) do if not sessionFields[key] then return invalid('dual travel completion field is not allowlisted', { field = tostring(key) }) end end
    local actor, actorError = self:_actor(playerSource)
    if not actor then return actorError end
    local id = normalizeBookingId(payload.bookingId)
    if not id then for candidate, context in pairs(self._contexts) do if context.sessionToken == sessionToken and context.ownerRef == actor.ref then id = candidate; break end end end
    if not id then return invalid('dual travel completion booking ID is required') end
    local booking, bookingError = self:_booking(id)
    if not booking then return bookingError end
    local valid, validError = self:_validate(booking, actor)
    if not valid then return validError end
    local context = self._contexts[id]
    if not context then
        local _, _, hydrateError, hydrated = self:_contextFor(actor.source, id, { 'ACTIVE', 'COMPLETED', 'SETTLED' })
        context = hydrated
        if not context then
            return Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'dual travel session context could not be restored after restart', {
                bookingId = id, cause = safeError(hydrateError).code
            })
        end
    end
    if context.sessionToken and tostring(context.sessionToken) ~= tostring(sessionToken) then return Result.err(Codes.APPOINTMENT_SESSION_OWNER_MISMATCH, 'dual travel session token does not match booking') end
    if statusOf(booking) == 'SETTLED' then
        return Result.ok({ booking = booking, settlement = copy(context.settlement) or { status = 'SETTLED', booking = copy(booking) }, cleanup = copy(context.cleanup) },
            { idempotent = true, serverAuthoritative = true })
    end
    if (statusOf(booking) == 'ACTIVE' or statusOf(booking) == 'COMPLETED') and not context.sessionToken then
        return Result.err(Codes.DUAL_TRAVEL_RECOVERY_REQUIRED, 'dual travel session token was not persisted across restart', { bookingId = id })
    end
    local pending = self._pendingSettlement[id]
    if pending and tostring(pending.sessionToken or '') == tostring(sessionToken) then
        local settled, settlementError = self:_settle(actor, booking, context)
        if not settled then return settlementError end
        return Result.ok({ booking = settled.booking, settlement = settled.settlement, pendingRetry = true }, { idempotent = true, serverAuthoritative = true })
    end
    if type(self._session) ~= 'table' or type(self._session.complete) ~= 'function' then return notReady('dual travel appointment session service is unavailable') end
    local completed, completeError = invoke(self._session, 'complete', actor, sessionToken, payload)
    if not completed then return completeError end
    local completedBooking = completed.booking or booking
    context.booking, context.session, context.sessionToken = copy(completedBooking), copy(completed.session or context.session), sessionToken
    local settled, settlementError = self:_settle(actor, completedBooking, context)
    if not settled then return settlementError end
    return Result.ok({ session = completed.session, booking = settled.booking, settlement = settled.settlement, cleanup = settled.cleanup }, { completed = true, serverAuthoritative = true })
end

Service.sessionComplete = Service.completeSession

function Service:interrupt(playerSource, bookingId, reason)
    local actor, booking, contextError, context = self:_contextFor(playerSource, bookingId, { 'RESERVED', 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED', 'ACTIVE' })
    if not actor then return contextError end
    local interrupted, interruptError = invoke(self._bookingService, 'interrupt', actor, booking.id, booking.version, type(reason) == 'string' and reason or 'dual-travel-interrupted')
    if not interrupted then return interruptError end
    self:_cancelTravel(context)
    local cleanup = self:_releaseResources(interrupted, context, true)
    context.booking, context.phase, context.cleanup = copy(interrupted), 'INTERRUPTED', cleanup
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = interrupted, phase = context.phase, cleanup = cleanup }, { interrupted = true, serverAuthoritative = true })
end

function Service:disconnect(playerSource)
    local source = integer(playerSource, 1, 65535)
    if not source then return invalid('dual travel disconnect source is invalid') end
    local results = {}
    for id, context in pairs(self._contexts) do
        if context.ownerSource == source and allowedStatus(statusOf(context.booking), { 'RESERVED', 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED', 'ACTIVE' }) then
            results[#results + 1] = self:interrupt(source, id, 'client-disconnected')
        end
    end
    return Result.ok(results)
end

-- Used by the client-mode facade to route token-only completion retries without
-- exposing the in-memory coordinator context to the NUI.
function Service:bookingIdForSession(playerSource, sessionToken)
    local actor = self:_actor(playerSource)
    if not actor or not token(tostring(sessionToken or ''), 200) then return nil end
    for id, context in pairs(self._contexts) do
        if context.ownerRef == actor.ref and tostring(context.sessionToken or '') == tostring(sessionToken) then
            return id
        end
    end
    return nil
end

function Service:get(first, second)
    local source, id = nil, first
    if second ~= nil then source, id = first, second end
    id = normalizeBookingId(id)
    if not id then return invalid('dual travel booking ID is invalid') end
    local context = self._contexts[id]
    if not context then return Result.err(Codes.BOOKING_NOT_FOUND, 'dual travel booking context was not found') end
    if source ~= nil and tostring(context.ownerSource) ~= tostring(source) then return conflict('dual travel context belongs to another player') end
    return Result.ok(copy(context))
end

NightShift.DualTravelService = Service
NightShift.Services.DualTravel = Service
