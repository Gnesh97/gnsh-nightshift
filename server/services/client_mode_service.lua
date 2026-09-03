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
    local metatable = getmetatable(value)
    if metatable ~= nil then setmetatable(output, metatable) end
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

local function sourceValue(value)
    return integer(value, 1, 65535)
end

local function invalid(message, details)
    return Result.err(Codes.CLIENT_MODE_INVALID, message, details)
end

local function unavailable(message, details)
    return Result.err(Codes.CLIENT_MODE_NOT_READY, message, details)
end

local function conflict(message, details)
    return Result.err(Codes.CLIENT_MODE_CONFLICT, message, details)
end

local function unwrap(result, fallback, message)
    if type(result) ~= 'table' then return nil, Result.err(fallback, message or 'client mode service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value or result.data end
    if result.success == true then return result.value or result.data end
    return result
end

local function invoke(service, method, ...)
    if type(service) ~= 'table' or type(service[method]) ~= 'function' then
        return nil, unavailable(('client mode dependency "%s" is unavailable'):format(method))
    end
    local ok, result = pcall(service[method], service, ...)
    if not ok then return nil, unavailable(('client mode dependency "%s" failed'):format(method)) end
    return unwrap(result, Codes.CLIENT_MODE_NOT_READY, ('client mode dependency "%s" returned an invalid result'):format(method))
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    return os.time()
end

local function epoch(value)
    if type(value) == 'number' then return finite(value) and tonumber(value) or nil end
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

local function normalizeBookingId(value)
    if integer(value, 1) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

local function statusOf(booking)
    return type(booking) == 'table' and type(booking.status) == 'string' and booking.status:upper() or nil
end

local function typeOf(value, fallback)
    return type(value) == 'string' and value:upper() or fallback
end

local function allowedFields(payload, allowed, message)
    if type(payload) ~= 'table' then return invalid(message or 'client mode payload must be a table') end
    for key in pairs(payload) do
        if not allowed[key] then return invalid('client mode payload field is not allowlisted', { field = tostring(key) }) end
    end
    return true
end

local function quoteIdOf(booking)
    local quote = type(booking) == 'table' and (booking.quote or booking.quote_snapshot) or nil
    if type(quote) == 'table' then return quote.quoteId or quote.quote_id or quote.id end
    local agreed = type(booking) == 'table' and booking.agreedPrice or nil
    return type(agreed) == 'table' and (agreed.quoteId or agreed.quote_id or agreed.id) or nil
end

local function safeResultError(result)
    if type(result) ~= 'table' then return nil end
    return result.error or result
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('client mode options must be a table') end
    local booking = options.bookingService or options.booking
    local repository = options.repository or options.bookingRepository
    local identity = options.identityService or options.identity
    local worker = options.workerService or options.npcWorker
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' or type(booking.offer) ~= 'function' or
        type(booking.accept) ~= 'function' or type(booking.reserve) ~= 'function' then
        return nil, invalid('client mode requires a booking service')
    end
    if type(repository) ~= 'table' or type(repository.findByQuoteId) ~= 'function' then
        return nil, invalid('client mode requires quote lookup')
    end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then
        return nil, invalid('client mode requires identity resolution')
    end
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' or type(worker.reserve) ~= 'function' or type(worker.release) ~= 'function' then
        return nil, invalid('client mode requires NPC worker reservation')
    end
    local ttl = integer(options.reservationTtlSeconds or options.resourceTtlSeconds or 3600, 1, 86400)
    if not ttl then return nil, invalid('client mode reservation TTL is invalid') end
    local mode = type(options.travelMode) == 'string' and options.travelMode:upper() or 'WALK'
    if not NightShift.Enums.NpcTravelModes[mode] or mode == 'UNKNOWN' then return nil, invalid('client mode travel mode is invalid') end
    return setmetatable({
        _bookingService = booking, _repository = repository, _identity = identity, _worker = worker,
        _location = options.locationService or options.location,
        _locationReservation = options.locationReservationService or options.locationReservation,
        _deposit = options.depositService or options.deposit,
        _travel = options.travelService or options.npcTravel,
        _spawn = options.spawnService or options.npcSpawn,
        _arrival = options.arrivalService or options.npcArrival,
        _session = options.appointmentSessionService or options.appointmentSession,
        _settlement = options.settlementService or options.settlement,
        _clock = options.clock, _reservationTtl = ttl, _travelMode = mode,
        _originResolver = options.originResolver or options.travelOriginResolver,
        _pickup = options.pickupModeService or options.pickupMode,
        _dual = options.dualTravelService or options.dualTravel,
        _contexts = {}, _pendingSettlement = {}, _settled = {}, _settlementInFlight = {},
        _activeSessions = {}, _activeSessionsBySource = {}
    }, Service)
end

function Service:_actor(playerSource)
    local source = sourceValue(playerSource)
    if not source then return nil, invalid('client mode player source is invalid') end
    local identity, identityError = invoke(self._identity, 'resolve', source)
    if not identity then return nil, identityError end
    local reference = identity.identityKey or identity.key
    if not text(reference, 200) then return nil, Result.err(Codes.IDENTITY_INVALID, 'resolved client identity has no safe reference') end
    return { type = 'PLAYER', ref = reference, source = source }
end

function Service:_booking(id)
    local booking, errorResult = invoke(self._bookingService, 'get', id)
    if not booking then return nil, errorResult end
    if tostring(booking.id) ~= tostring(id) then return nil, invalid('booking lookup returned a mismatched booking') end
    return booking
end

-- Keep S13's COME_TO_ME implementation intact while routing PICKUP bookings
-- to the dedicated two-leg coordinator.
function Service:_pickupForBooking(id)
    if type(self._pickup) ~= 'table' or type(self._pickup.confirm) ~= 'function' then return nil end
    local booking = self:_booking(id)
    if type(booking) == 'table' and typeOf(booking.meetingMode) == 'PICKUP' then return self._pickup, booking end
    return nil
end

function Service:_dualForBooking(id)
    if type(self._dual) ~= 'table' or type(self._dual.confirm) ~= 'function' then return nil end
    local booking = self:_booking(id)
    if type(booking) == 'table' and typeOf(booking.meetingMode) == 'MEET_THERE' then return self._dual, booking end
    return nil
end

function Service:_owned(booking, actor)
    if typeOf(booking.clientType) ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then
        return nil, Result.err(Codes.CLIENT_MODE_OWNER_MISMATCH, 'client does not own this booking')
    end
    return true
end

function Service:_validateComeToMe(booking, actor)
    local owned, ownerError = self:_owned(booking, actor)
    if not owned then return nil, ownerError end
    if typeOf(booking.workerType) ~= 'NPC' then return nil, conflict('COME_TO_ME requires an NPC worker') end
    if typeOf(booking.meetingMode) ~= 'COME_TO_ME' then return nil, conflict('booking is not a COME_TO_ME booking') end
    if not token(booking.workerRef, 160) then return nil, invalid('booking has no valid NPC worker reference') end
    if not token(booking.locationRef, 160) or not token(booking.locationType, 32) then return nil, invalid('booking has no valid destination reference') end
    return true
end

function Service:_quoteFresh(booking)
    local quote = type(booking.quote) == 'table' and booking.quote or nil
    if not quote or quote.expiresAt == nil then return true end
    local expiry = epoch(quote.expiresAt)
    if not expiry then return nil, Result.err(Codes.QUOTE_INVALID, 'booking quote expiry is invalid') end
    if now(self._clock) >= expiry then return nil, Result.err(Codes.QUOTE_EXPIRED, 'quote has expired', { quoteId = quote.quoteId or quote.id }) end
    return true
end

function Service:_resolveWorker(workerKey, bookingId)
    local worker, workerError = invoke(self._worker, 'get', workerKey)
    if not worker then return nil, workerError end
    local resolvedKey = worker.workerKey or worker.key or worker.id
    if not text(resolvedKey, 160) or tostring(resolvedKey) ~= tostring(workerKey) then
        return nil, Result.err(Codes.NPC_WORKER_INVALID, 'worker lookup returned a mismatched NPC worker')
    end
    local state = typeOf(worker.state)
    if state and state ~= 'AVAILABLE' and not (state == 'RESERVED' and tostring(worker.bookingId) == tostring(bookingId)) then
        return nil, Result.err(Codes.NPC_WORKER_CONFLICT, 'NPC worker is no longer available', { workerKey = workerKey })
    end
    return worker
end

function Service:_profileKey(worker)
    local profile = type(worker) == 'table' and worker.profile or nil
    local value = worker and (worker.profileKey or worker.profileRef) or nil
    value = value or (type(profile) == 'table' and (profile.profileKey or profile.key))
    value = value or worker and worker.workerKey
    return token(value, 160) and tostring(value) or nil
end

function Service:_resolveLocation(actor, booking)
    local request = { locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = booking.meetingMode }
    if type(self._location) ~= 'table' or type(self._location.resolve) ~= 'function' then
        return { locationType = booking.locationType, locationRef = booking.locationRef }
    end
    local resolved, resolveError = invoke(self._location, 'resolve', actor.source, request)
    if not resolved then return nil, resolveError end
    local value = resolved.location or resolved
    if type(value) ~= 'table' or tostring(value.locationRef or value.ref or '') ~= tostring(booking.locationRef) then
        return nil, Result.err(Codes.LOCATION_INVALID, 'location resolver returned a different destination')
    end
    local output = { locationType = value.locationType or booking.locationType, locationRef = value.locationRef or booking.locationRef }
    if value.meetingMode ~= nil then output.meetingMode = value.meetingMode end
    if type(value.worldTarget) == 'table' then output.worldTarget = copy(value.worldTarget) end
    if type(value.route) == 'table' then output.route = copy(value.route) end
    if value.reservable ~= nil then output.reservable = value.reservable end
    return output
end

function Service:_locationKey(booking, locationReservation)
    local value = type(locationReservation) == 'table' and (locationReservation.reservationKey or locationReservation.key) or nil
    return token(value, 200) and value or ('location:%s:%s'):format(tostring(booking.locationRef), tostring(booking.id))
end

function Service:_remember(booking, worker, locationReservation, deposit)
    local id = tostring(booking.id)
    local context = self._contexts[id] or {}
    context.bookingId, context.workerKey, context.locationRef = id, booking.workerRef, booking.locationRef
    context.booking = copy(booking)
    context.ownerRef, context.ownerSource = booking.clientRef, context.ownerSource
    context.worker = worker and copy(worker) or context.worker
    context.profileKey = self:_profileKey(worker) or context.profileKey
    context.locationReservationKey = self:_locationKey(booking, locationReservation or context.locationReservation)
    context.locationReservation = locationReservation and copy(locationReservation) or context.locationReservation
    context.deposit = deposit and copy(deposit) or context.deposit
    self._contexts[id] = context
    return context
end

local function withDetails(result, extra)
    if type(result) ~= 'table' or type(extra) ~= 'table' then return result end
    local output = copy(result)
    local detail = type(output.details) == 'table' and output.details or {}
    for key, value in pairs(extra) do detail[key] = copy(value) end
    output.details = detail
    if type(output.error) == 'table' then output.error.details = copy(detail) end
    return output
end

local function statusAllowed(status, allowed)
    if type(allowed) ~= 'table' then return true end
    for _, value in ipairs(allowed) do if status == value then return true end end
    return false
end

function Service:_rollback(booking, actor, context, reason)
    context = context or {}
    local cleanup = {}
    if context.depositAcquired and self._deposit then
        local released, releaseError = invoke(self._deposit, 'release', actor, booking)
        cleanup.deposit = released and 'released' or (releaseError and safeResultError(releaseError) and safeResultError(releaseError).code or 'failed')
    end
    if context.locationAcquired and self._locationReservation and context.locationReservationKey then
        local released, releaseError = invoke(self._locationReservation, 'release', tostring(booking.id), context.locationReservationKey)
        cleanup.location = released and 'released' or (releaseError and safeResultError(releaseError) and safeResultError(releaseError).code or 'failed')
    end
    if context.workerAcquired and self._worker and booking.workerRef then
        local released, releaseError = invoke(self._worker, 'release', booking.workerRef, tostring(booking.id))
        cleanup.worker = released and 'released' or (releaseError and safeResultError(releaseError) and safeResultError(releaseError).code or 'failed')
    end
    return withDetails(reason, { rollback = cleanup })
end

function Service:_confirmation(booking, context, idempotent)
    local value = {
        bookingId = tostring(booking.id), status = statusOf(booking),
        booking = copy(booking),
        worker = context and copy(context.worker) or nil,
        location = context and copy(context.location) or nil,
        reservation = context and copy(context.locationReservation) or nil,
        deposit = context and copy(context.deposit) or nil
    }
    return Result.ok(value, { idempotent = idempotent == true, serverAuthoritative = true })
end

local function safeRef(value, maximum)
    return token(value, maximum or 200) and tostring(value) or nil
end

local function safeBooking(value)
    if type(value) ~= 'table' then return nil end
    local bookingId = normalizeBookingId(value.id or value.bookingId)
    if not bookingId then return nil end
    local output = { bookingId = bookingId }
    local status = statusOf(value)
    if status then output.status = status end
    return output
end

local function safeWorker(value)
    if type(value) ~= 'table' then return nil end
    local workerKey = safeRef(value.workerKey or value.key or value.id, 160)
    if not workerKey then return nil end
    local output = { workerKey = workerKey }
    local profileKey = safeRef(value.profileKey or value.profileRef, 160)
    if profileKey then output.profileKey = profileKey end
    local state = type(value.state) == 'string' and value.state:upper() or nil
    if state and #state <= 32 then output.state = state end
    local bookingId = normalizeBookingId(value.bookingId)
    if bookingId then output.bookingId = bookingId end
    return output
end

local function safeLocation(value)
    if type(value) ~= 'table' then return nil end
    local locationRef = safeRef(value.locationRef or value.ref, 160)
    local locationType = safeRef(value.locationType or value.type, 32)
    if not locationRef or not locationType then return nil end
    local output = { locationType = locationType, locationRef = locationRef }
    local meetingMode = type(value.meetingMode) == 'string' and value.meetingMode:upper() or nil
    if meetingMode and #meetingMode <= 32 then output.meetingMode = meetingMode end
    return output
end

local function safeReservation(value)
    if type(value) ~= 'table' then return nil end
    local key = safeRef(value.reservationKey or value.key or value.id, 200)
    if not key then return nil end
    local output = { reservationKey = key }
    local status = type(value.status) == 'string' and value.status:upper() or nil
    if status and #status <= 32 then output.status = status end
    return output
end

local function safeCandidate(value)
    if type(value) ~= 'table' then return nil end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil end
    local output = { kind = kind }
    if kind == 'coords' then
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
    elseif not token(value.provider, 96) then
        return nil
    else
        output.provider = value.provider
    end
    return output
end

local function safeDeposit(value)
    if type(value) ~= 'table' then return nil end
    local status = type(value.status) == 'string' and value.status:upper() or nil
    if not status or #status > 32 then return nil end
    local output = { status = status }
    local amount = integer(value.amountMinor, 0, 100000000000)
    if amount then output.amountMinor = amount end
    local currency = type(value.currency) == 'string' and value.currency:upper() or nil
    if currency and currency:match('^[A-Z][A-Z][A-Z]$') then output.currency = currency end
    return output
end

local function safeTravel(value)
    if type(value) ~= 'table' then return nil end
    local travelKey = safeRef(value.travelKey, 200)
    local bookingId = normalizeBookingId(value.bookingId)
    if not travelKey or not bookingId then return nil end
    local output = { travelKey = travelKey, bookingId = bookingId }
    local profileKey = safeRef(value.profileKey, 160)
    if profileKey then output.profileKey = profileKey end
    local mode = type(value.mode) == 'string' and value.mode:upper() or nil
    if mode and #mode <= 32 then output.mode = mode end
    local state = type(value.state) == 'string' and value.state:upper() or nil
    if state and #state <= 32 then output.state = state end
    local progress = tonumber(value.progress)
    if finite(progress) then output.progress = math.max(0, math.min(1, progress)) end
    local eta = integer(value.etaSeconds, 0, 86400)
    if eta then output.etaSeconds = eta end
    local startedAt = tonumber(value.startedAt)
    if finite(startedAt) then output.startedAt = startedAt end
    return output
end

local function safeSpawn(value)
    if type(value) ~= 'table' then return nil end
    local output = {}
    for _, field in ipairs({ 'travelKey', 'profileKey', 'generationToken', 'spawnKey' }) do
        local valueForField = safeRef(value[field], field == 'profileKey' and 160 or 240)
        if valueForField then output[field] = valueForField end
    end
    local model = safeRef(value.model, 96)
    if model then output.model = model end
    local candidate = safeCandidate(value.candidate)
    if candidate then output.candidate = candidate end
    local generation = integer(value.generation, 1, 2147483647)
    if generation then output.generation = generation end
    local bookingId = normalizeBookingId(value.bookingId)
    if bookingId then output.bookingId = bookingId end
    local entity = integer(value.entity, 0, 2147483647)
    if entity then output.entity = entity end
    local networkId = integer(value.networkId, 0, 2147483647)
    if networkId then output.networkId = networkId end
    if type(value.serverOwned) == 'boolean' then output.serverOwned = value.serverOwned end
    return next(output) and output or nil
end

local function safePickup(value)
    if type(value) ~= 'table' then return nil end
    local output = {}
    local location = safeLocation(value.location or value)
    if location then
        output.location = location
        output.locationType, output.locationRef = location.locationType, location.locationRef
    end
    local candidate = safeCandidate(value.candidate)
    if candidate then output.candidate = candidate end
    local district = safeRef(value.district, 64)
    if district then output.district = district end
    if type(value.serverGenerated) == 'boolean' then output.serverGenerated = value.serverGenerated end
    local status = type(value.status) == 'string' and value.status:upper() or nil
    if status and #status <= 32 then output.status = status end
    return next(output) and output or nil
end

local function safeVehicle(value)
    if type(value) ~= 'table' then return nil end
    local vehicleId = safeRef(value.vehicleId or value.vehicleRef or value.id, 96)
    if not vehicleId then return nil end
    local output = { vehicleId = vehicleId, vehicleRef = safeRef(value.vehicleRef, 120) or 'vehicle:' .. vehicleId }
    local bookingId = normalizeBookingId(value.bookingId)
    if bookingId then output.bookingId = bookingId end
    local seat = integer(value.seat, -1, 15)
    if seat then output.seat = seat end
    local state = type(value.state) == 'string' and value.state:upper() or nil
    if state and #state <= 32 then output.state = state end
    local networkId = integer(value.networkId, 0, 2147483647)
    if networkId then output.networkId = networkId end
    local entity = integer(value.entity, 0, 2147483647)
    if entity then output.entity = entity end
    return output
end

local function safeSession(value)
    if type(value) ~= 'table' then return nil end
    local bookingId = normalizeBookingId(value.bookingId)
    local sessionToken = safeRef(value.token, 200)
    if not bookingId or not sessionToken then return nil end
    local output = { bookingId = bookingId, token = sessionToken }
    local state = type(value.state) == 'string' and value.state:upper() or nil
    if state and #state <= 32 then output.state = state end
    local startedAt = tonumber(value.startedAt)
    if finite(startedAt) then output.startedAt = startedAt end
    local expiresAt = tonumber(value.expiresAt)
    if finite(expiresAt) then output.expiresAt = expiresAt end
    return output
end

local function safeMetadata(value)
    if type(value) ~= 'table' then return nil end
    local output = {}
    for _, field in ipairs({ 'idempotent', 'serverAuthoritative', 'started', 'completed', 'arrived', 'pendingRetry', 'oneTime' }) do
        if type(value[field]) == 'boolean' then output[field] = value[field] end
    end
    return next(output) and output or nil
end

local function safeNuiValue(value)
    if type(value) ~= 'table' then return {} end
    local output = {}
    local booking = safeBooking(value.booking) or safeBooking(value)
    if booking then output.booking, output.bookingId, output.status = booking, booking.bookingId, booking.status end
    local worker = safeWorker(value.worker)
    if worker then output.worker = worker end
    local location = safeLocation(value.location)
    if location then output.location = location end
    local reservation = safeReservation(value.reservation)
    if reservation then output.reservation = reservation end
    local deposit = safeDeposit(value.deposit)
    if deposit then output.deposit = deposit end
    local travel = safeTravel(value.travel)
    if travel then output.travel = travel; output.travelKey = travel.travelKey end
    local spawn = safeSpawn(value.spawn)
    if spawn then output.spawn = spawn end
    local pickup = safePickup(value.pickup or value.pickupReservation)
    if pickup then output.pickup = pickup end
    local destination = safeLocation(value.destination)
    if destination then output.destination = destination end
    local vehicle = safeVehicle(value.vehicle)
    if vehicle then output.vehicle = vehicle end
    local phase = type(value.phase) == 'string' and value.phase:upper() or nil
    if phase and #phase <= 40 then output.phase = phase end
    if type(value.waiting) == 'boolean' then output.waiting = value.waiting end
    if type(value.clientArrived) == 'boolean' then output.clientArrived = value.clientArrived end
    if type(value.workerArrived) == 'boolean' then output.workerArrived = value.workerArrived end
    local waitingFor = type(value.waitingFor) == 'string' and value.waitingFor:upper() or nil
    if waitingFor and #waitingFor <= 32 then output.waitingFor = waitingFor end
    local outcome = safeRef(value.outcome, 64)
    if outcome then output.outcome = outcome end
    local graceRemaining = integer(value.graceRemainingSeconds, 0, 86400)
    if graceRemaining then output.graceRemainingSeconds = graceRemaining end
    local arrival = safeTravel(value.arrival)
    if arrival then output.arrival = arrival end
    local session = safeSession(value.session)
    if session then output.session, output.token = session, session.token end
    local settlement = type(value.settlement) == 'table' and value.settlement or nil
    if settlement then
        local safeSettlement = { status = type(settlement.status) == 'string' and settlement.status:upper() or nil }
        local settlementBooking = safeBooking(settlement.booking)
        if settlementBooking then safeSettlement.booking, output.bookingId, output.status = settlementBooking, settlementBooking.bookingId, settlementBooking.status end
        if safeSettlement.status then output.settlement = safeSettlement else output.settlement = settlementBooking and safeSettlement or nil end
    end
    if safeRef(value.generationToken, 240) then output.generationToken = tostring(value.generationToken) end
    if type(value.entity) == 'number' then output.entity = integer(value.entity, 0, 2147483647) end
    if type(value.networkId) == 'number' then output.networkId = integer(value.networkId, 0, 2147483647) end
    return output
end

function Service:toNuiResult(result, _method)
    if type(result) ~= 'table' then return Result.err(Codes.CLIENT_MODE_NOT_READY, 'client mode returned an invalid response') end
    if result.ok == false then
        local sourceError = type(result.error) == 'table' and result.error or result
        local code = type(sourceError.code) == 'string' and sourceError.code or Codes.CLIENT_MODE_NOT_READY
        local message = type(sourceError.message) == 'string' and sourceError.message or 'client mode request failed'
        return { ok = false, success = false, code = code, message = message, error = { code = code, message = message }, metadata = safeMetadata(result.metadata) }
    end
    if result.ok ~= true then return Result.err(Codes.CLIENT_MODE_NOT_READY, 'client mode returned an invalid response') end
    local value = safeNuiValue(result.value or result.data)
    return { ok = true, success = true, value = value, data = copy(value), metadata = safeMetadata(result.metadata) }
end

function Service:_contextFor(source, bookingId, statuses)
    local actor, actorError = self:_actor(source)
    if not actor then return nil, nil, actorError end
    local id = normalizeBookingId(bookingId)
    if not id then return nil, nil, invalid('client mode booking ID is invalid') end
    local booking, bookingError = self:_booking(id)
    if not booking then return nil, nil, bookingError end
    local valid, validError = self:_validateComeToMe(booking, actor)
    if not valid then return nil, nil, validError end
    local status = statusOf(booking)
    if not statusAllowed(status, statuses) then
        return nil, nil, conflict('booking is not in a valid client mode state', { status = status })
    end
    local context = self._contexts[id] or {}
    context.ownerRef, context.ownerSource, context.booking = actor.ref, actor.source, copy(booking)
    if not context.travelKey and (status == 'TRAVELLING' or status == 'ARRIVAL_PENDING' or status == 'ARRIVED') then
        local worker, profileKey = self:_profileAndWorker(booking)
        if worker and profileKey then
            context.worker, context.profileKey = copy(worker), profileKey
            context.travelKey = self:_travelKey(booking, worker)
        end
    end
    self._contexts[id] = context
    return actor, booking, nil, context
end

function Service:_bookingIdForTravel(travelKey)
    if not token(travelKey, 200) then return nil end
    for id, context in pairs(self._contexts) do
        if context.travelKey == travelKey then return id end
    end
    if self._travel and type(self._travel.get) == 'function' then
        local found = invoke(self._travel, 'get', travelKey)
        if found and token(found.bookingId, 160) then return tostring(found.bookingId) end
    end
    return nil
end

function Service:_travelKey(booking, worker)
    local workerRef = booking.workerRef or worker and (worker.workerKey or worker.key)
    if not token(workerRef, 160) then return nil end
    return ('client-travel:%s:%s'):format(tostring(booking.id), tostring(workerRef))
end

function Service:_origin(actor, worker, booking)
    if type(self._originResolver) == 'function' then
        local ok, value = pcall(self._originResolver, copy(actor), copy(worker), copy(booking))
        if not ok then return nil, Result.err(Codes.TRAVEL_INVALID, 'client mode travel origin resolver failed') end
        if type(value) == 'table' and value.ok == false then return nil, value end
        if type(value) == 'table' and value.ok == true then value = value.value end
        if type(value) == 'table' then return copy(value) end
    end
    local profile = type(worker) == 'table' and worker.profile or nil
    local district = worker and (worker.activeDistrict or worker.district) or nil
    district = district or type(profile) == 'table' and (profile.homeDistrict or profile.district) or nil
    local locationRef = worker and (worker.currentLocationId or worker.locationRef or worker.homeLocationRef) or nil
    locationRef = locationRef or type(profile) == 'table' and (profile.currentLocationId or profile.homeLocationRef) or nil
    if token(locationRef, 160) then return { locationRef = locationRef } end
    if token(district, 64) then return { district = tostring(district):lower() } end
    return nil, Result.err(Codes.TRAVEL_INVALID, 'NPC worker has no server-known travel origin')
end

function Service:_profileAndWorker(booking)
    local worker, workerError = self:_resolveWorker(booking.workerRef, booking.id)
    if not worker then return nil, nil, workerError end
    local profileKey = self:_profileKey(worker)
    if not profileKey then return nil, nil, Result.err(Codes.NPC_PROFILE_INVALID, 'NPC worker has no profile key') end
    return worker, profileKey
end

function Service:confirm(source, payload)
    local validPayload = allowedFields(payload, { quoteId = true }, 'client mode confirmation payload must be a table')
    if validPayload ~= true then return validPayload end
    if not text(payload.quoteId, 160) then return invalid('client mode quote ID is required') end
    if self._pickup or self._dual then
        local indexed = invoke(self._repository, 'findByQuoteId', payload.quoteId)
        local indexedValue = type(indexed) == 'table' and indexed.ok == true and indexed.value or indexed
        local bookingId = type(indexedValue) == 'table' and (indexedValue.id or indexedValue.bookingId) or nil
        local pickup = bookingId and self:_pickupForBooking(bookingId)
        if pickup then return pickup:confirm(source, payload) end
        local dual = bookingId and self:_dualForBooking(bookingId)
        if dual then return dual:confirm(source, payload) end
    end
    local actor, actorError = self:_actor(source)
    if not actor then return actorError end
    local indexed, lookupError = invoke(self._repository, 'findByQuoteId', payload.quoteId)
    if not indexed then
        local errorValue = safeResultError(lookupError)
        if errorValue and errorValue.code == Codes.REPOSITORY_NOT_FOUND then
            return Result.err(Codes.BOOKING_NOT_FOUND, 'booking for quote was not found')
        end
        return lookupError
    end
    local indexedId = indexed.id or indexed.bookingId
    if not indexedId then return invalid('quote lookup returned no booking ID') end
    local booking, bookingError = self:_booking(indexedId)
    if not booking then return bookingError end
    local valid, validError = self:_validateComeToMe(booking, actor)
    if not valid then return validError end
    local storedQuote = quoteIdOf(booking)
    if tostring(storedQuote or '') ~= tostring(payload.quoteId) then
        return Result.err(Codes.QUOTE_INVALID, 'quote is not bound to this booking')
    end
    local status = statusOf(booking)
    if status == 'RESERVED' or status == 'TRAVELLING' or status == 'ARRIVED' or status == 'ACTIVE' or status == 'COMPLETED' or status == 'SETTLED' then
        local context = self._contexts[tostring(booking.id)] or {}
        return self:_confirmation(booking, context, true)
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
    if status ~= 'ACCEPTED' then return conflict('booking cannot be confirmed in its current state', { status = status }) end
    local fresh, freshError = self:_quoteFresh(booking)
    if not fresh then return freshError end
    local worker, profileKey, workerError = self:_profileAndWorker(booking)
    if not worker then return workerError end
    local context = self._contexts[tostring(booking.id)] or {}
    context.worker, context.profileKey = copy(worker), profileKey
    context.workerAcquired = not (typeOf(worker.state) == 'RESERVED' and tostring(worker.bookingId) == tostring(booking.id))
    local reservedWorker, reserveWorkerError = invoke(self._worker, 'reserve', booking.workerRef, tostring(booking.id), { ttlSeconds = self._reservationTtl })
    if not reservedWorker then return reserveWorkerError end
    context.worker = copy(reservedWorker)
    local location, locationError = self:_resolveLocation(actor, booking)
    if not location then return self:_rollback(booking, actor, context, locationError) end
    context.location = copy(location)
    if type(self._locationReservation) ~= 'table' or type(self._locationReservation.reserve) ~= 'function' then
        return self:_rollback(booking, actor, context, unavailable('client mode location reservation is unavailable'))
    end
    local locationReservation, reservationError = invoke(self._locationReservation, 'reserve', tostring(booking.id), {
        locationType = location.locationType, locationRef = location.locationRef,
        meetingMode = booking.meetingMode, ttlSeconds = self._reservationTtl
    }, { source = actor.source, booking = copy(booking) })
    if not locationReservation then return self:_rollback(booking, actor, context, reservationError) end
    context.locationReservation = copy(locationReservation)
    context.locationReservationKey = self:_locationKey(booking, locationReservation)
    context.locationAcquired = not (locationReservation.idempotent == true)
    if self._deposit then
        local held, holdError = invoke(self._deposit, 'hold', actor, booking, { reason = 'client-mode-reservation' })
        if not held then return self:_rollback(booking, actor, context, holdError) end
        context.deposit = copy(held)
        context.depositAcquired = held.status == 'HELD' and not held.idempotent
    end
    local reserved, reserveError = invoke(self._bookingService, 'reserve', actor, booking.id, booking.version)
    if not reserved then return self:_rollback(booking, actor, context, reserveError) end
    context = self:_remember(reserved, context.worker, context.locationReservation, context.deposit)
    context.ownerRef, context.ownerSource, context.location, context.worker = actor.ref, actor.source, copy(location), copy(context.worker)
    context.workerAcquired = false
    context.locationAcquired = false
    context.depositAcquired = false
    context.confirmedAt = now(self._clock)
    self._contexts[tostring(reserved.id)] = context
    return self:_confirmation(reserved, context, false)
end

Service.confirmComeToMe = Service.confirm
Service.reserve = Service.confirm

function Service:_travelContext(booking, context)
    if not token(context.travelKey, 200) then return nil, unavailable('client mode travel plan is not ready') end
    local travel, travelError = invoke(self._travel, 'get', context.travelKey)
    if not travel then return nil, travelError end
    if tostring(travel.bookingId) ~= tostring(booking.id) or tostring(travel.profileKey) ~= tostring(context.profileKey) then
        return nil, conflict('travel plan does not match the client booking')
    end
    return travel
end

function Service:_cancelTravel(travelKey)
    if type(self._travel) ~= 'table' then return nil, unavailable('client mode travel service is unavailable') end
    if type(self._travel.cancel) == 'function' then
        local cancelled, cancelError = invoke(self._travel, 'cancel', travelKey, now(self._clock))
        return cancelled, cancelError, 'CANCELLED'
    end
    if type(self._travel.markRecovery) == 'function' then
        local recovered, recoveryError = invoke(self._travel, 'markRecovery', travelKey, 'STUCK', now(self._clock))
        return recovered, recoveryError, 'RECOVERING'
    end
    return nil, unavailable('client mode travel rollback service is unavailable')
end

function Service:startTravel(source, bookingId)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:startTravel(source, bookingId) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:startTravel(source, bookingId) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'RESERVED', 'TRAVELLING' })
    if not actor then return contextError end
    if statusOf(booking) == 'TRAVELLING' and context.travelKey then
        local travel, travelError = self:_travelContext(booking, context)
        if not travel then return travelError end
        return Result.ok({ booking = booking, travel = travel }, { idempotent = true, serverAuthoritative = true })
    end
    if type(self._travel) ~= 'table' or type(self._travel.create) ~= 'function' then
        return unavailable('client mode travel service is unavailable')
    end
    local worker, profileKey, workerError = self:_profileAndWorker(booking)
    if not worker then return workerError end
    local location, locationError = self:_resolveLocation(actor, booking)
    if not location then return locationError end
    local origin, originError = self:_origin(actor, worker, booking)
    if not origin then return originError end
    local travelKey = self:_travelKey(booking, worker)
    if not travelKey then return invalid('client mode travel key could not be derived') end
    local workerMode = type(worker.profile) == 'table' and worker.profile.travelMode or worker.travelMode
    workerMode = type(workerMode) == 'string' and workerMode:upper() or self._travelMode
    if workerMode == 'UNKNOWN' or not NightShift.Enums.NpcTravelModes[workerMode] then workerMode = self._travelMode end
    local travel, travelError = invoke(self._travel, 'create', actor.source, {
        travelKey = travelKey, bookingId = tostring(booking.id), workerKey = booking.workerRef,
        profileKey = profileKey, origin = origin,
        destination = { locationType = location.locationType, locationRef = location.locationRef, meetingMode = booking.meetingMode },
        mode = workerMode
    })
    if not travel then return travelError end
    local moved, moveError = invoke(self._bookingService, 'startTravel', actor, booking.id, booking.version)
    if not moved then
        local cancelled, cancelError, rollbackStatus = self:_cancelTravel(travelKey)
        local rollback = cancelled and { status = rollbackStatus or 'RECOVERING' } or { status = 'FAILED', code = safeResultError(cancelError) and safeResultError(cancelError).code or 'UNKNOWN' }
        return withDetails(moveError or Result.err(Codes.TRAVEL_CONFLICT, 'booking could not enter travel'), { travelRollback = rollback })
    end
    context = self:_remember(moved, worker, context.locationReservation, context.deposit)
    context.travelKey, context.profileKey, context.worker = travel.travelKey, profileKey, copy(worker)
    context.location, context.ownerRef, context.ownerSource = copy(location), actor.ref, actor.source
    self._contexts[tostring(moved.id)] = context
    return Result.ok({ booking = moved, travel = travel }, { started = true, serverAuthoritative = true })
end

function Service:travel(source, payload)
    if type(payload) == 'table' then
        local valid = allowedFields(payload, { bookingId = true }, 'client mode travel payload must be a table')
        if valid ~= true then return valid end
        return self:startTravel(source, payload.bookingId)
    end
    return self:startTravel(source, payload)
end

Service.start = Service.startTravel

function Service:updateTravelProgress(source, bookingId)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:updateTravelProgress(source, bookingId) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:updateTravelProgress(source, bookingId) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local eta = tonumber(travel.etaSeconds)
    local started = tonumber(travel.startedAt)
    local progress = tonumber(travel.progress) or 0
    if eta and eta > 0 and started then
        progress = math.max(progress, math.min(1, (now(self._clock) - started) / eta))
    end
    local updated, updateError = invoke(self._travel, 'updateProgress', context.travelKey, progress)
    if not updated then return updateError end
    context.travel = copy(updated)
    return Result.ok({ booking = booking, travel = updated }, { serverAuthoritative = true })
end

function Service:recoverTravel(source, bookingId, recoveryState)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:recoverTravel(source, bookingId, recoveryState) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:recoverTravel(source, bookingId, recoveryState) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    if type(recoveryState) ~= 'string' or not NightShift.Enums.NpcTravelRecoveryStates[recoveryState:upper()] then
        return invalid('client mode travel recovery state is invalid')
    end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local updated, updateError = invoke(self._travel, 'markRecovery', context.travelKey, recoveryState:upper())
    if not updated then return updateError end
    context.travel = copy(updated)
    return Result.ok({ booking = booking, travel = updated }, { serverAuthoritative = true })
end

function Service:requestSpawn(source, bookingId)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:requestSpawn(source, bookingId) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:requestSpawn(source, bookingId) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    if type(self._spawn) ~= 'table' or type(self._spawn.request) ~= 'function' then
        return unavailable('client mode NPC spawn service is unavailable')
    end
    local spawn, spawnError = invoke(self._spawn, 'request', actor.source, {
        travelKey = context.travelKey, bookingId = tostring(booking.id), profileKey = context.profileKey
    })
    if not spawn then return spawnError end
    context.spawn = copy(spawn)
    context.generationToken = spawn.generationToken
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, travel = travel, spawn = spawn,
        travelKey = context.travelKey, bookingId = tostring(booking.id), profileKey = context.profileKey,
        generationToken = spawn.generationToken, entity = spawn.entity, networkId = spawn.networkId
    }, { serverAuthoritative = true })
end

function Service:spawn(source, payload)
    if type(payload) == 'table' then
        local valid = allowedFields(payload, { bookingId = true }, 'client mode spawn payload must be a table')
        if valid ~= true then return valid end
        return self:requestSpawn(source, payload.bookingId)
    end
    return self:requestSpawn(source, payload)
end

local spawnFields = {
    spawn = true, profileKey = true, travelKey = true, bookingId = true, generationToken = true,
    entity = true, networkId = true, serverOwned = true, spawnKey = true, generation = true,
    model = true, appearanceProfileRef = true, candidate = true, booking = true, travel = true
}

function Service:confirmSpawn(source, payload)
    local pickup = payload and payload.bookingId and self:_pickupForBooking(payload.bookingId)
    if pickup then return pickup:confirmSpawn(source, payload) end
    local dual = payload and payload.bookingId and self:_dualForBooking(payload.bookingId)
    if dual then return dual:confirmSpawn(source, payload) end
    if type(payload) ~= 'table' then return invalid('client mode spawn confirmation payload must be a table') end
    for key in pairs(payload) do if not spawnFields[key] then return invalid('client mode spawn confirmation field is not allowlisted', { field = tostring(key) }) end end
    local raw = type(payload.spawn) == 'table' and payload.spawn or payload
    local travelKey, bookingId = raw.travelKey or payload.travelKey, raw.bookingId or payload.bookingId
    bookingId = bookingId or self:_bookingIdForTravel(travelKey)
    if not bookingId then return invalid('client mode spawn confirmation has no booking context') end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING' })
    if not actor then return contextError end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local profileKey = raw.profileKey or context.profileKey
    local generationToken = raw.generationToken or context.generationToken or context.spawn and context.spawn.generationToken
    if not token(profileKey, 160) or not token(generationToken, 240) or travelKey ~= context.travelKey then
        return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'client mode spawn confirmation is missing server generation context')
    end
    if type(self._spawn) ~= 'table' or type(self._spawn.confirmSpawn) ~= 'function' then
        return unavailable('client mode NPC spawn service is unavailable')
    end
    local bound, boundError = invoke(self._spawn, 'confirmSpawn', actor.source, {
        profileKey = profileKey, travelKey = context.travelKey, bookingId = tostring(booking.id),
        generationToken = generationToken, entity = raw.entity, networkId = raw.networkId
    })
    if not bound then return boundError end
    context.spawn = copy(bound)
    context.generationToken = bound.generationToken or generationToken
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = booking, travel = travel, spawn = bound,
        travelKey = context.travelKey, bookingId = tostring(booking.id), profileKey = profileKey,
        generationToken = bound.generationToken or generationToken, entity = bound.entity, networkId = bound.networkId
    }, { serverAuthoritative = true })
end

local arrivalFields = {
    arrival = true, travelKey = true, bookingId = true, profileKey = true, generationToken = true,
    entity = true, networkId = true, position = true
}

function Service:confirmArrival(source, payload)
    if type(payload) ~= 'table' then return invalid('client mode arrival payload must be a table') end
    local pickup = payload.bookingId and self:_pickupForBooking(payload.bookingId)
    if pickup then return pickup:confirmArrival(source, payload) end
    local dual = payload.bookingId and self:_dualForBooking(payload.bookingId)
    if dual then return dual:confirmClientArrival(source, payload) end
    for key in pairs(payload) do if not arrivalFields[key] then return invalid('client mode arrival field is not allowlisted', { field = tostring(key) }) end end
    local raw = type(payload.arrival) == 'table' and payload.arrival or payload
    local travelKey = raw.travelKey or payload.travelKey
    local bookingId = raw.bookingId or payload.bookingId or self:_bookingIdForTravel(travelKey)
    if not bookingId then return invalid('client mode arrival has no booking context') end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'TRAVELLING', 'ARRIVAL_PENDING', 'ARRIVED' })
    if not actor then return contextError end
    if statusOf(booking) == 'ARRIVED' then
        local travel = context.travel or (context.travelKey and self:_travelContext(booking, context))
        return Result.ok({ booking = booking, travel = travel }, { idempotent = true, serverAuthoritative = true })
    end
    local travel, travelError = self:_travelContext(booking, context)
    if not travel then return travelError end
    local profileKey = raw.profileKey or context.profileKey
    local generationToken = raw.generationToken or context.generationToken or context.spawn and context.spawn.generationToken
    if not token(travelKey, 200) or travelKey ~= context.travelKey or not token(profileKey, 160) or not token(generationToken, 240) then
        return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'client mode arrival is missing server generation context')
    end
    if type(self._arrival) ~= 'table' or type(self._arrival.accept) ~= 'function' then
        return unavailable('client mode NPC arrival service is unavailable')
    end
    local arrived, arrivalError = invoke(self._arrival, 'accept', actor.source, {
        travelKey = context.travelKey, bookingId = tostring(booking.id), profileKey = profileKey,
        generationToken = generationToken, entity = raw.entity, networkId = raw.networkId,
        expectedVersion = booking.version, position = raw.position
    })
    if not arrived then return arrivalError end
    local arrivedBooking = arrived.booking or booking
    context = self:_remember(arrivedBooking, context.worker, context.locationReservation, context.deposit)
    context.travelKey, context.travel, context.spawn, context.generationToken = context.travelKey, copy(arrived.travel or travel), context.spawn, generationToken
    context.arrival = copy(arrived)
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = arrivedBooking, travel = arrived.travel or travel, arrival = arrived }, { arrived = true, serverAuthoritative = true })
end

function Service:bindVehicle(source, payload)
    local bookingId = type(payload) == 'table' and payload.bookingId or nil
    local pickup = bookingId and self:_pickupForBooking(bookingId)
    if pickup and type(pickup.bindVehicle) == 'function' then return pickup:bindVehicle(source, payload) end
    return unavailable('pickup vehicle binding is unavailable')
end

function Service:confirmClientArrival(source, payload)
    local dual = payload and payload.bookingId and self:_dualForBooking(payload.bookingId)
    if dual then return dual:confirmClientArrival(source, payload) end
    return unavailable('dual travel client arrival is unavailable')
end

function Service:confirmNpcArrival(source, payload)
    local dual = payload and payload.bookingId and self:_dualForBooking(payload.bookingId)
    if dual then return dual:confirmNpcArrival(source, payload) end
    return unavailable('dual travel NPC arrival is unavailable')
end

function Service:tick(source, bookingId, at)
    local dual = self:_dualForBooking(bookingId)
    if dual and type(dual.tick) == 'function' then return dual:tick(source, bookingId, at) end
    return unavailable('dual travel grace timer is unavailable')
end

function Service:enterVehicle(source, bookingId)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup and type(pickup.enterVehicle) == 'function' then return pickup:enterVehicle(source, bookingId) end
    return unavailable('pickup vehicle entry is unavailable')
end

function Service:startDestinationTravel(source, bookingId)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup and type(pickup.startDestinationTravel) == 'function' then return pickup:startDestinationTravel(source, bookingId) end
    return unavailable('pickup destination travel is unavailable')
end

function Service:confirmDestinationArrival(source, payload)
    local bookingId = type(payload) == 'table' and payload.bookingId or nil
    local pickup = bookingId and self:_pickupForBooking(bookingId)
    if pickup and type(pickup.confirmDestinationArrival) == 'function' then return pickup:confirmDestinationArrival(source, payload) end
    return unavailable('pickup destination arrival is unavailable')
end

Service.arrival = Service.confirmArrival
Service.validateArrival = Service.confirmArrival

local sessionFields = { bookingId = true, locationType = true, locationRef = true, meetingMode = true, token = true }

function Service:startSession(source, bookingId, payload)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:startSession(source, bookingId, payload) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:startSession(source, bookingId, payload) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'ARRIVED', 'ACTIVE' })
    if not actor then return contextError end
    if statusOf(booking) == 'ACTIVE' and context.session then
        return Result.ok({ booking = booking, session = copy(context.session), token = context.sessionToken }, { idempotent = true, serverAuthoritative = true })
    end
    if type(payload) ~= 'table' then payload = {} end
    for key in pairs(payload) do if not sessionFields[key] then return invalid('client mode session field is not allowlisted', { field = tostring(key) }) end end
    if type(self._session) ~= 'table' or type(self._session.start) ~= 'function' then
        return unavailable('client mode appointment session service is unavailable')
    end
    local request = {
        bookingId = tostring(booking.id), locationType = booking.locationType,
        locationRef = booking.locationRef, meetingMode = booking.meetingMode
    }
    local started, startError = invoke(self._session, 'start', actor, tostring(booking.id), request)
    if not started then return startError end
    context.session, context.sessionToken = copy(started), started.token
    context.activeAt, context.ownerRef, context.ownerSource = now(self._clock), actor.ref, actor.source
    self._activeSessions[tostring(booking.id)] = started.token
    self._activeSessionsBySource[actor.source] = tostring(booking.id)
    context = self:_remember(started.booking or booking, context.worker, context.locationReservation, context.deposit)
    context.session, context.sessionToken = copy(started), started.token
    self._contexts[tostring(booking.id)] = context
    return Result.ok({ booking = started.booking or booking, session = started, token = started.token }, { started = true, serverAuthoritative = true })
end

Service.sessionStart = Service.startSession

function Service:_releaseResources(booking, context)
    local cleanup = {}
    if context and self._locationReservation and context.locationReservationKey then
        local released, releaseError = invoke(self._locationReservation, 'release', tostring(booking.id), context.locationReservationKey)
        cleanup.location = released and 'released' or (safeResultError(releaseError) and safeResultError(releaseError).code or 'failed')
    end
    if context and self._worker and booking.workerRef then
        local released, releaseError = invoke(self._worker, 'release', booking.workerRef, tostring(booking.id))
        cleanup.worker = released and 'released' or (safeResultError(releaseError) and safeResultError(releaseError).code or 'failed')
    end
    return cleanup
end

function Service:_settle(booking, actor, context)
    local settlementId = tostring(booking.id)
    if statusOf(booking) == 'SETTLED' or self._settled[settlementId] then
        local cleanupBooking = copy(booking)
        if context and context.workerKey and not cleanupBooking.workerRef then cleanupBooking.workerRef = context.workerKey end
        if context and context.locationRef and not cleanupBooking.locationRef then cleanupBooking.locationRef = context.locationRef end
        local cleanup = self:_releaseResources(cleanupBooking, context or {})
        return { booking = booking, status = 'SETTLED', cleanup = cleanup }, nil
    end
    if type(self._settlement) ~= 'table' or type(self._settlement.settle) ~= 'function' then
        local errorResult = Result.err(Codes.SETTLEMENT_NOT_READY, 'client mode settlement service is unavailable')
        self._pendingSettlement[settlementId] = { actor = copy(actor), context = copy(context or {}), booking = copy(booking) }
        return nil, errorResult
    end
    if self._settlementInFlight[settlementId] then
        return nil, Result.err(Codes.SETTLEMENT_IN_PROGRESS, 'settlement is already in progress', { bookingId = settlementId })
    end
    self._settlementInFlight[settlementId] = true
    local settled, settlementError = invoke(self._settlement, 'settle', actor, tostring(booking.id), {
        bookingId = tostring(booking.id), locationType = booking.locationType, locationRef = booking.locationRef
    })
    self._settlementInFlight[settlementId] = nil
    if not settled then
        self._pendingSettlement[settlementId] = { actor = copy(actor), context = copy(context or {}), booking = copy(booking) }
        return nil, settlementError or Result.err(Codes.SETTLEMENT_NOT_READY, 'settlement returned no result')
    end
    self._settled[tostring(booking.id)] = true
    self._pendingSettlement[settlementId] = nil
    local finalBooking = settled.booking or booking
    local cleanupBooking = copy(finalBooking)
    if not cleanupBooking.workerRef then cleanupBooking.workerRef = booking.workerRef end
    if not cleanupBooking.locationRef then cleanupBooking.locationRef = booking.locationRef end
    local cleanup = self:_releaseResources(cleanupBooking, context or {})
    local target = self._contexts[tostring(booking.id)] or context or {}
    target.booking, target.settlement, target.cleanup = copy(finalBooking), copy(settled), cleanup
    target.settledAt = now(self._clock)
    self._contexts[tostring(booking.id)] = target
    return settled, nil
end

function Service:completeSession(source, sessionToken, payload)
    payload = type(payload) == 'table' and payload or {}
    local pickup = payload.bookingId and self:_pickupForBooking(payload.bookingId)
    if pickup then return pickup:completeSession(source, sessionToken, payload) end
    local dual = payload.bookingId and self:_dualForBooking(payload.bookingId)
    if not dual and type(self._dual) == 'table' and type(self._dual.bookingIdForSession) == 'function' then
        local dualBookingId = self._dual:bookingIdForSession(source, sessionToken)
        if dualBookingId then
            dual = self._dual
            local routedPayload = copy(payload)
            routedPayload.bookingId = dualBookingId
            return dual:completeSession(source, sessionToken, routedPayload)
        end
    end
    if dual then return dual:completeSession(source, sessionToken, payload) end
    local actor, actorError = self:_actor(source)
    if not actor then return actorError end
    if not token(tostring(sessionToken or ''), 200) then return invalid('client mode session token is invalid') end
    payload = type(payload) == 'table' and payload or {}
    for key in pairs(payload) do if not sessionFields[key] then return invalid('client mode completion field is not allowlisted', { field = tostring(key) }) end end
    local pendingForPayload = payload.bookingId and self._pendingSettlement[tostring(payload.bookingId)] or nil
    local pendingTokenMatches = pendingForPayload and pendingForPayload.sessionToken ~= nil and
        tostring(pendingForPayload.sessionToken) == tostring(sessionToken)
    if pendingForPayload and not pendingTokenMatches then
        return Result.err(Codes.APPOINTMENT_SESSION_OWNER_MISMATCH, 'pending settlement token does not match the active session')
    end
    if (not self._settlement or type(self._settlement.settle) ~= 'function') and not pendingTokenMatches then
        return Result.err(Codes.SETTLEMENT_NOT_READY, 'client mode settlement service is unavailable', {
            bookingId = payload.bookingId
        })
    end
    local pendingId
    for id, pending in pairs(self._pendingSettlement) do
        local tokenMatches = pending.sessionToken ~= nil and tostring(pending.sessionToken) == tostring(sessionToken)
        if pending.actor and pending.actor.ref == actor.ref and tokenMatches and (payload.bookingId == nil or tostring(payload.bookingId) == tostring(id)) then pendingId = id; break end
    end
    if pendingId then
        local pending = self._pendingSettlement[pendingId]
        local booking, bookingError = self:_booking(pendingId)
        if not booking then return bookingError end
        local settled, settlementError = self:_settle(booking, actor, pending.context)
        if not settled then return settlementError end
        self._activeSessions[pendingId] = nil
        if self._activeSessionsBySource[actor.source] == tostring(pendingId) then self._activeSessionsBySource[actor.source] = nil end
        return Result.ok({ booking = settled.booking or booking, settlement = settled, pendingRetry = true }, { idempotent = true, serverAuthoritative = true })
    end
    if type(self._session) ~= 'table' or type(self._session.complete) ~= 'function' then
        return unavailable('client mode appointment session service is unavailable')
    end
    local completed, completeError = invoke(self._session, 'complete', actor, sessionToken, payload)
    if not completed then return completeError end
    local booking = completed.booking
    if type(booking) ~= 'table' or booking.id == nil then
        return Result.err(Codes.CLIENT_MODE_INVALID, 'appointment completion returned no booking')
    end
    local context = self._contexts[tostring(booking.id)] or {}
    context.session = completed.session or context.session
    context.sessionToken = sessionToken
    local settled, settlementError = self:_settle(booking, actor, context)
    if not settled then
        local pending = self._pendingSettlement[tostring(booking.id)]
        if pending then pending.sessionToken = tostring(sessionToken) end
        return settlementError
    end
    self._activeSessions[tostring(booking.id)] = nil
    if self._activeSessionsBySource[actor.source] == tostring(booking.id) then self._activeSessionsBySource[actor.source] = nil end
    return Result.ok({ session = completed.session, booking = settled.booking or booking, settlement = settled }, { completed = true, serverAuthoritative = true })
end

Service.sessionComplete = Service.completeSession

function Service:interrupt(source, bookingId, reason)
    local pickup = self:_pickupForBooking(bookingId)
    if pickup then return pickup:interrupt(source, bookingId, reason) end
    local dual = self:_dualForBooking(bookingId)
    if dual then return dual:interrupt(source, bookingId, reason) end
    local actor, booking, contextError, context = self:_contextFor(source, bookingId, { 'ARRIVED', 'ACTIVE', 'TRAVELLING', 'ARRIVAL_PENDING' })
    if not actor then return contextError end
    reason = type(reason) == 'string' and reason or 'client-disconnected'
    local interrupted, interruptError
    if context.sessionToken and self._session and type(self._session.interrupt) == 'function' then
        interrupted, interruptError = invoke(self._session, 'interrupt', actor, context.sessionToken, reason)
    elseif self._bookingService and type(self._bookingService.interrupt) == 'function' then
        interrupted, interruptError = invoke(self._bookingService, 'interrupt', actor, booking.id, booking.version, reason)
    else
        return unavailable('client mode interruption service is unavailable')
    end
    if not interrupted then return interruptError end
    local nextBooking = interrupted.booking or interrupted
    local cleanup = self:_releaseResources(nextBooking, context)
    context.booking, context.cleanup, context.interruptedAt = copy(nextBooking), cleanup, now(self._clock)
    self._contexts[tostring(booking.id)] = context
    self._activeSessions[tostring(booking.id)] = nil
    if self._activeSessionsBySource[actor.source] == tostring(booking.id) then self._activeSessionsBySource[actor.source] = nil end
    return Result.ok({ booking = nextBooking, cleanup = cleanup }, { interrupted = true, serverAuthoritative = true })
end

function Service:disconnect(source)
    local playerSource = sourceValue(source)
    if not playerSource then return invalid('client mode disconnect source is invalid') end
    if type(self._pickup) == 'table' and type(self._pickup.disconnect) == 'function' and type(self._pickup._contexts) == 'table' then
        for _, context in pairs(self._pickup._contexts) do
            if context.ownerSource == playerSource then return self._pickup:disconnect(playerSource) end
        end
    end
    if type(self._dual) == 'table' and type(self._dual.disconnect) == 'function' and type(self._dual._contexts) == 'table' then
        for _, context in pairs(self._dual._contexts) do
            if context.ownerSource == playerSource then return self._dual:disconnect(playerSource) end
        end
    end
    local bookingId = self._activeSessionsBySource[playerSource]
    if not bookingId then
        for id, context in pairs(self._contexts) do
            if context.ownerSource == playerSource and context.booking and
                (statusOf(context.booking) == 'TRAVELLING' or statusOf(context.booking) == 'ARRIVAL_PENDING' or statusOf(context.booking) == 'ARRIVED') then
                bookingId = id
                break
            end
        end
    end
    if not bookingId then return Result.ok({ disconnected = true }, { idempotent = true }) end
    return self:interrupt(playerSource, bookingId, 'client-disconnected')
end

function Service:get(bookingId)
    local id = normalizeBookingId(bookingId)
    if not id then return invalid('client mode booking ID is invalid') end
    local pickup = self:_pickupForBooking(id)
    if pickup then return pickup:get(id) end
    local dual = self:_dualForBooking(id)
    if dual then return dual:get(id) end
    local context = self._contexts[id]
    if not context then return Result.err(Codes.BOOKING_NOT_FOUND, 'client mode booking context was not found') end
    return Result.ok(copy(context))
end

NightShift.ClientModeService = Service
NightShift.ClientMode = Service
NightShift.Services.ClientMode = Service

return Service
