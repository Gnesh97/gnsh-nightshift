local function s13Check(value, message)
    assert(value, message)
end

local function s13Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[s13Copy(key, seen)] = s13Copy(item, seen) end
    return output
end

local Codes = NightShift.Errors.Codes

local function makeBooking()
    local booking = {
        id = 'booking:client:1', version = 1, status = 'ACCEPTED',
        idempotencyKey = 'client-mode:booking:1', clientType = 'PLAYER', clientRef = 'player:one',
        workerType = 'NPC', workerRef = 'npc-worker:one', meetingMode = 'COME_TO_ME',
        locationType = 'CONFIG_LOCATION', locationRef = 'configured_default',
        servicePackage = { id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD' },
        quote = { quoteId = 'quote:client:1', bookingId = 'booking:client:1', amountMinor = 500, currency = 'USD' },
        agreedPrice = { quoteId = 'quote:client:1', bookingId = 'booking:client:1', amountMinor = 500, currency = 'USD' }
    }
    local calls = { reserve = 0, workerReserve = 0, workerRelease = 0, locationReserve = 0, locationRelease = 0, depositHold = 0, depositRelease = 0 }
    local bookingService = {
        get = function(_, id)
            return tostring(id) == booking.id and NightShift.Result.ok(s13Copy(booking)) or NightShift.Result.err(Codes.BOOKING_NOT_FOUND, 'missing')
        end,
        offer = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'OFFERED', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        accept = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'ACCEPTED', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        reserve = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            calls.reserve = calls.reserve + 1
            booking.status, booking.version = 'RESERVED', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        startTravel = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'TRAVELLING', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        startActive = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'ACTIVE', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        complete = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'COMPLETED', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end,
        interrupt = function(_, _, id, expected)
            if tostring(id) ~= booking.id or expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            booking.status, booking.version = 'INTERRUPTED', booking.version + 1
            return NightShift.Result.ok(s13Copy(booking))
        end
    }
    local repository = {
        findByQuoteId = function(_, quoteId)
            return quoteId == 'quote:client:1' and NightShift.Result.ok(s13Copy(booking)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing')
        end
    }
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = source == 42 and 'player:one' or 'player:other', source = source }) end }
    local worker = {
        get = function(_, key)
            return key == 'npc-worker:one' and NightShift.Result.ok({ workerKey = key, profileKey = 'npc-profile:one', state = 'AVAILABLE', activeDistrict = 'vinewood', profile = { profileKey = 'npc-profile:one' } }) or NightShift.Result.err(Codes.NPC_WORKER_NOT_FOUND, 'missing')
        end,
        reserve = function(_, key, id)
            calls.workerReserve = calls.workerReserve + 1
            return NightShift.Result.ok({ workerKey = key, profileKey = 'npc-profile:one', state = 'RESERVED', bookingId = id })
        end,
        release = function(_, key, id)
            calls.workerRelease = calls.workerRelease + 1
            return NightShift.Result.ok({ workerKey = key, state = 'AVAILABLE', bookingId = nil })
        end
    }
    local location = {
        resolve = function(_, source, request)
            return NightShift.Result.ok({ locationType = request.locationType, locationRef = request.locationRef, reservable = true, meetingMode = request.meetingMode, worldTarget = { kind = 'coords', x = 100, y = 200, z = 30 } })
        end
    }
    local locationReservation = {
        reserve = function(_, id, request)
            calls.locationReserve = calls.locationReserve + 1
            if request.fail then return NightShift.Result.err(Codes.RESERVATION_CONFLICT, 'room race') end
            return NightShift.Result.ok({ reservationKey = 'location:configured_default:' .. tostring(id), locationRef = 'configured_default', status = 'RESERVED' })
        end,
        release = function(_, id)
            calls.locationRelease = calls.locationRelease + 1
            return NightShift.Result.ok({ status = 'RELEASED' })
        end
    }
    local deposit = {
        hold = function(_, actor, value)
            calls.depositHold = calls.depositHold + 1
            if value.insufficient then return NightShift.Result.err(Codes.DEPOSIT_INSUFFICIENT_FUNDS, 'insufficient') end
            return NightShift.Result.ok({ status = 'HELD', bookingId = value.id })
        end,
        release = function(_, actor, value)
            calls.depositRelease = calls.depositRelease + 1
            return NightShift.Result.ok({ status = 'REFUNDED', bookingId = value.id })
        end
    }
    return booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls = makeBooking()
    local service, serviceError = NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit, reservationTtlSeconds = 600
    })
    s13Check(service and not serviceError, 'client mode service should construct')
    local confirmed = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(confirmed.ok and confirmed.value.booking.status == 'RESERVED', 'COME_TO_ME confirm should reserve the booking')
    s13Check(calls.workerReserve == 1 and calls.locationReserve == 1 and calls.depositHold == 1, 'confirm should reserve worker, location, and deposit')
    local retry = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(retry.ok and retry.metadata and retry.metadata.idempotent == true, 'reserved confirmation should be idempotent')
    s13Check(calls.workerReserve == 1 and calls.locationReserve == 1 and calls.depositHold == 1, 'idempotent confirmation must not duplicate resource reservations')
    confirmed.value.booking.quote = { quoteId = 'quote:client:1', providerSecret = 'must-not-leak' }
    confirmed.value.worker.profile = { traits = { private = true }, generationSeed = 'must-not-leak' }
    local nui = service:toNuiResult(confirmed, 'client-mode:confirm')
    s13Check(nui.ok and nui.value.bookingId == booking.id and nui.value.worker.workerKey == booking.workerRef, 'NUI confirmation should expose only safe identifiers')
    s13Check(nui.value.booking.quote == nil and nui.value.worker.profile == nil and nui.value.worker.internalToken == nil, 'NUI confirmation must not expose booking or worker internals')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls = makeBooking()
    locationReservation.reserve = function() return NightShift.Result.err(Codes.RESERVATION_CONFLICT, 'room race') end
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit
    }))
    local raced = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(not raced.ok and raced.error.code == Codes.RESERVATION_CONFLICT, 'location race should fail the confirmation')
    s13Check(calls.workerReserve == 1 and calls.workerRelease == 1 and calls.depositHold == 0, 'location race must roll back the worker before charging')
    s13Check(booking.status == 'ACCEPTED', 'location race must not transition the booking')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls = makeBooking()
    deposit.hold = function() return NightShift.Result.err(Codes.DEPOSIT_INSUFFICIENT_FUNDS, 'insufficient') end
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit
    }))
    local insufficient = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(not insufficient.ok and insufficient.error.code == Codes.DEPOSIT_INSUFFICIENT_FUNDS, 'insufficient funds should fail the confirmation')
    s13Check(calls.workerRelease == 1 and calls.locationRelease == 1 and booking.status == 'ACCEPTED', 'insufficient funds must release every prior reservation')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls = makeBooking()
    worker.get = function(_, key)
        return NightShift.Result.ok({ workerKey = key, profileKey = 'npc-profile:one', state = 'RESERVED', bookingId = 'booking:another' })
    end
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit
    }))
    local raced = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(not raced.ok and raced.error.code == Codes.NPC_WORKER_CONFLICT, 'NPC worker race should fail before any reservation')
    s13Check(calls.workerReserve == 0 and calls.locationReserve == 0 and booking.status == 'ACCEPTED', 'NPC race must not leak location or deposit state')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit = makeBooking()
    booking.quote.expiresAt = 1
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit
    }))
    local expired = service:confirm(42, { quoteId = 'quote:client:1' })
    s13Check(not expired.ok and expired.error.code == Codes.QUOTE_EXPIRED, 'COME_TO_ME confirmation must recheck quote expiry')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit = makeBooking()
    local travel = {
        create = function(_, source, request)
            return NightShift.Result.ok({ travelKey = request.travelKey, bookingId = request.bookingId, workerKey = request.workerKey, profileKey = request.profileKey, state = 'TRAVELLING', progress = 0, destination = request.destination })
        end,
        get = function(_, key)
            return NightShift.Result.ok({ travelKey = key, bookingId = booking.id, workerKey = booking.workerRef, profileKey = 'npc-profile:one', state = 'TRAVELLING', progress = 0, spawnThreshold = 0.65 })
        end,
        shouldSpawn = function() return NightShift.Result.ok({ ready = true }) end,
        updateProgress = function(_, key) return NightShift.Result.ok({ travelKey = key, state = 'TRAVELLING', progress = 0.7 }) end,
        markRecovery = function(_, key, state) return NightShift.Result.ok({ travelKey = key, state = 'RECOVERING', recoveryState = state }) end
    }
    local spawn = {
        request = function(_, source, payload) return NightShift.Result.ok({ serverOwned = true, travelKey = payload.travelKey, bookingId = payload.bookingId, profileKey = payload.profileKey, generation = 1, generationToken = 'npc-generation:1', model = 'a_m_m_business_01', candidate = { kind = 'coords', x = 100, y = 200, z = 30 } }) end,
        confirmSpawn = function(_, source, payload) return NightShift.Result.ok({ serverOwned = true, travelKey = payload.travelKey, bookingId = payload.bookingId, profileKey = payload.profileKey, generationToken = payload.generationToken, entity = payload.entity }) end
    }
    local arrival = {
        accept = function(_, source, payload)
            return NightShift.Result.ok({ booking = { id = booking.id, status = 'ARRIVED', version = booking.version + 1 }, travel = { travelKey = payload.travelKey, state = 'ARRIVED' } })
        end
    }
    booking.status = 'RESERVED'
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit, travelService = travel, spawnService = spawn, arrivalService = arrival
    }))
    local started = service:startTravel(42, booking.id)
    s13Check(started.ok and started.value.booking.status == 'TRAVELLING', 'COME_TO_ME travel should transition the booking')
    local authorization = service:requestSpawn(42, booking.id)
    s13Check(authorization.ok and authorization.value.generationToken, 'spawn authorization should be server-owned')
    local spawnNui = service:toNuiResult(authorization, 'client-mode:spawn')
    s13Check(spawnNui.ok and spawnNui.value.spawn.model == 'a_m_m_business_01' and spawnNui.value.spawn.candidate.x == 100 and spawnNui.value.spawn.generation == 1, 'NUI spawn authorization should preserve only validated model and candidate data')
    local bound = service:confirmSpawn(42, authorization.value)
    s13Check(bound.ok, 'spawn confirmation should preserve the server generation context')
    local arrived = service:confirmArrival(42, { travelKey = started.value.travel.travelKey, profileKey = 'npc-profile:one', generationToken = authorization.value.generationToken, entity = 701 })
    s13Check(arrived.ok, 'validated arrival should complete the travel leg')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit = makeBooking()
    booking.status = 'RESERVED'
    local cancelled = 0
    local travel = {
        create = function(_, source, request)
            return NightShift.Result.ok({ travelKey = request.travelKey, bookingId = request.bookingId, workerKey = request.workerKey, profileKey = request.profileKey, state = 'TRAVELLING', progress = 0 })
        end,
        cancel = function(_, key)
            cancelled = cancelled + 1
            return NightShift.Result.ok({ travelKey = key, state = 'CANCELLED' })
        end,
        get = function(_, key)
            return NightShift.Result.ok({ travelKey = key, bookingId = booking.id, workerKey = booking.workerRef, profileKey = 'npc-profile:one', state = 'TRAVELLING', progress = 0 })
        end
    }
    bookingService.startTravel = function() return NightShift.Result.err(Codes.VERSION_CONFLICT, 'booking transition failed') end
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit, travelService = travel
    }))
    local failed = service:startTravel(42, booking.id)
    s13Check(not failed.ok and failed.error.code == Codes.VERSION_CONFLICT, 'travel transition failure should be returned to the caller')
    s13Check(failed.details and failed.details.travelRollback and failed.details.travelRollback.status == 'CANCELLED' and cancelled == 1, 'travel transition failure must cancel the orphaned travel plan')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit, calls = makeBooking()
    booking.status = 'ARRIVED'
    local sessionToken, sessionCompleted, settlementReady, settleCalls = nil, false, false, 0
    local appointment = {
        start = function(_, actor, id)
            sessionToken = 'appointment:client:1'
            return NightShift.Result.ok({ token = sessionToken, bookingId = id, state = 'ACTIVE', booking = { id = id, status = 'ACTIVE', version = booking.version + 1 } })
        end,
        complete = function(_, actor, token)
            if sessionCompleted then return NightShift.Result.err(Codes.APPOINTMENT_SESSION_REPLAY, 'replay') end
            sessionCompleted = true
            return NightShift.Result.ok({ session = { token = token, state = 'COMPLETED' }, booking = { id = booking.id, status = 'COMPLETED', version = booking.version + 2 } })
        end
    }
    local settlement = {
        settle = function(_, actor, id)
            settleCalls = settleCalls + 1
            if not settlementReady then return NightShift.Result.err(Codes.SETTLEMENT_NOT_READY, 'settlement unavailable') end
            return NightShift.Result.ok({ booking = { id = id, status = 'SETTLED', version = booking.version + 3 }, status = 'SETTLED' })
        end
    }
    local service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit, appointmentSessionService = appointment, settlementService = settlement
    }))
    service._contexts[booking.id] = {
        bookingId = booking.id, workerKey = booking.workerRef, profileKey = 'npc-profile:one',
        locationReservationKey = 'location:configured_default:' .. booking.id,
        locationReservation = { reservationKey = 'location:configured_default:' .. booking.id },
        worker = { workerKey = booking.workerRef }
    }
    local started = service:startSession(42, booking.id, {})
    s13Check(started.ok and started.value.token == sessionToken, 'client mode session should start after arrival')
    local pending = service:completeSession(42, sessionToken, { bookingId = booking.id })
    s13Check(not pending.ok and pending.error.code == Codes.SETTLEMENT_NOT_READY, 'settlement outage should leave a retryable completion')
    local mismatch = service:completeSession(42, 'appointment:wrong', { bookingId = booking.id })
    s13Check(not mismatch.ok and mismatch.error.code == Codes.APPOINTMENT_SESSION_OWNER_MISMATCH and settleCalls == 1, 'pending settlement retry must reject a mismatched session token')
    settlementReady = true
    local settled = service:completeSession(42, sessionToken, { bookingId = booking.id })
    s13Check(settled.ok and settled.value.booking.status == 'SETTLED', 'settlement retry should settle exactly once')
    s13Check(service._activeSessions[booking.id] == nil and service._activeSessionsBySource[42] == nil, 'settlement retry must clear the active session indexes')
    local replay = service:completeSession(42, sessionToken, { bookingId = booking.id })
    s13Check(not replay.ok and replay.error.code == Codes.APPOINTMENT_SESSION_REPLAY, 'double completion must not run settlement again')
    s13Check(settleCalls == 2, 'settlement should run once per initial attempt and retry, never on replay')
end

do
    local booking, bookingService, repository, identity, worker, location, locationReservation, deposit = makeBooking()
    booking.status = 'COMPLETED'
    local reentrant, reentrantError, settleCalls = nil, nil, 0
    local service
    local settlement = {
        settle = function(_, actor, id)
            settleCalls = settleCalls + 1
            reentrant, reentrantError = service:_settle({ id = id, status = 'COMPLETED', workerRef = booking.workerRef, locationRef = booking.locationRef }, actor, {})
            return NightShift.Result.ok({ booking = { id = id, status = 'SETTLED' }, status = 'SETTLED' })
        end
    }
    service = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, locationService = location, locationReservationService = locationReservation,
        depositService = deposit, settlementService = settlement
    }))
    local settled = service:_settle({ id = booking.id, status = 'COMPLETED', workerRef = booking.workerRef, locationRef = booking.locationRef }, { type = 'PLAYER', ref = 'player:one', source = 42 }, {})
    s13Check(settled and settled.status == 'SETTLED' and settleCalls == 1, 'settlement should complete through the canonical service')
    s13Check(not reentrant and reentrantError and reentrantError.error.code == Codes.SETTLEMENT_IN_PROGRESS, 'concurrent settlement should be rejected while the first attempt is in flight')
end

print('NS-130..NS-132 tests passed: COME_TO_ME orchestration, rollback, NUI privacy, travel compensation, and exactly-once settlement')
