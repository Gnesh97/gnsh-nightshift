local function s15Check(value, message)
    assert(value, message)
end

local function s15Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[s15Copy(key, seen)] = s15Copy(item, seen) end
    return output
end

local Codes = NightShift.Errors.Codes

local function fixture(options)
    options = options or {}
    local clock = options.clock or { value = 1000, now = function(self) return self.value end }
    local booking = {
        id = options.id or 'booking:dual:1', version = 1, status = 'ACCEPTED',
        clientType = 'PLAYER', clientRef = 'player:one', workerType = 'NPC', workerRef = 'npc:one',
        meetingMode = 'MEET_THERE', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default',
        quote = { quoteId = options.quoteId or 'quote:dual:1', expiresAt = 2000 },
        agreedPrice = { amountMinor = 500, currency = 'USD', quoteId = options.quoteId or 'quote:dual:1' }
    }
    local plans, released, spawnFailed = {}, 0, options.spawnFailed == true
    local workerReleaseFailed, locationReleaseFailed = options.workerReleaseFailed == true, options.locationReleaseFailed == true
    local function resultBooking() return NightShift.Result.ok(s15Copy(booking)) end
    local bookingService = {}
    function bookingService:get(id) return tostring(id) == tostring(booking.id) and resultBooking() or NightShift.Result.err(Codes.BOOKING_NOT_FOUND, 'missing') end
    function bookingService:offer(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'OFFERED', booking.version + 1; return resultBooking() end
    function bookingService:accept(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'ACCEPTED', booking.version + 1; return resultBooking() end
    function bookingService:reserve(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'RESERVED', booking.version + 1; return resultBooking() end
    function bookingService:startTravel(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'TRAVELLING', booking.version + 1; return resultBooking() end
    function bookingService:markArrival(_, id, expected) if expected and expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'ARRIVED', booking.version + 1; return resultBooking() end
    function bookingService:cancel(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'CANCELLED', booking.version + 1; return resultBooking() end
    function bookingService:interrupt(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'INTERRUPTED', booking.version + 1; return resultBooking() end
    local repository = { findByQuoteId = function(_, quoteId) return quoteId == booking.quote.quoteId and resultBooking() or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end }
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = source == 42 and 'player:one' or 'player:other' }) end }
    local worker = {
        get = function(_, key) return NightShift.Result.ok({ workerKey = key, profileKey = 'profile:one', state = 'AVAILABLE', activeDistrict = 'vinewood', profile = { profileKey = 'profile:one' } }) end,
        reserve = function(_, key, id) return NightShift.Result.ok({ workerKey = key, profileKey = 'profile:one', state = 'RESERVED', bookingId = id, activeDistrict = 'vinewood' }) end,
        release = function()
            released = released + 1
            if workerReleaseFailed then return NightShift.Result.err(Codes.NPC_WORKER_UNAVAILABLE, 'worker release failed') end
            return NightShift.Result.ok({ state = 'AVAILABLE' })
        end
    }
    local location = { resolve = function(_, _, request) return NightShift.Result.ok({ locationType = request.locationType, locationRef = request.locationRef, worldTarget = { kind = 'coords', x = 250, y = -1000, z = 29 }, meetingMode = 'MEET_THERE', reservable = true }) end }
    local locationReservation = {
        reserve = function(_, id, request) return NightShift.Result.ok({ reservationKey = 'reservation:' .. tostring(id), locationRef = request.locationRef, status = 'RESERVED' }) end,
        release = function()
            if locationReleaseFailed then return NightShift.Result.err(Codes.RESERVATION_PROVIDER_FAILED, 'location release failed') end
            return NightShift.Result.ok({ status = 'RELEASED' })
        end
    }
    local travel = {
        create = function(_, _, request)
            local plan = { travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, state = 'TRAVELLING', progress = 0, expectedArrivalAt = clock.value + 10 }
            plans[request.travelKey] = plan
            return NightShift.Result.ok(s15Copy(plan))
        end,
        get = function(_, key) return plans[key] and NightShift.Result.ok(s15Copy(plans[key])) or NightShift.Result.err(Codes.TRAVEL_NOT_FOUND, 'missing') end,
        updateProgress = function(_, key, progress) plans[key].progress = progress; return NightShift.Result.ok(s15Copy(plans[key])) end,
        markArrival = function(_, key) plans[key].state = 'ARRIVED'; return NightShift.Result.ok(s15Copy(plans[key])) end,
        markRecovery = function(_, key, state) plans[key].state = state; return NightShift.Result.ok(s15Copy(plans[key])) end,
        cancel = function(_, key) if plans[key] then plans[key].state = 'CANCELLED' end; return NightShift.Result.ok(s15Copy(plans[key])) end
    }
    local spawn = {
        request = function(_, _, request)
            if spawnFailed then return NightShift.Result.err(Codes.NPC_SPAWN_INVALID, 'spawn failed') end
            return NightShift.Result.ok({ serverOwned = true, travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, generationToken = 'npc:profile:one:1', entity = 701 })
        end,
        confirmSpawn = function(_, _, request) return NightShift.Result.ok({ serverOwned = true, travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, generationToken = request.generationToken, entity = request.entity }) end
    }
    local arrival = { validateOnly = function(_, _, request) return NightShift.Result.ok({ bookingId = request.bookingId, travel = plans[request.travelKey] }) end }
    local dualSessionToken = 'appointment:dual:1'
    local session = {
        start = function(_, _, id) booking.status, booking.version = 'ACTIVE', booking.version + 1; return NightShift.Result.ok({ token = dualSessionToken, bookingId = id, state = 'ACTIVE', booking = resultBooking().value }) end,
        complete = function(_, _, token) booking.status, booking.version = 'COMPLETED', booking.version + 1; return NightShift.Result.ok({ token = token, booking = resultBooking().value }) end
    }
    local settlement = { settle = function() booking.status, booking.version = 'SETTLED', booking.version + 1; return NightShift.Result.ok({ status = 'SETTLED', booking = resultBooking().value }) end }
    local mode = assert(NightShift.DualTravelService.new({
        bookingService = bookingService, repository = repository, identityService = identity, workerService = worker,
        locationService = location, locationReservationService = locationReservation, travelService = travel,
        spawnService = spawn, arrivalService = arrival, appointmentSessionService = session, settlementService = settlement,
        clientProximityCheck = options.proximity, gracePeriodSeconds = options.grace or 30, clock = clock
    }))
    return mode, booking, clock, released, bookingService, repository, identity, worker, location, locationReservation, travel, spawn, arrival, session, settlement
end

do
    local mode, booking, _, _, bookingService, repository, identity, worker = fixture({ proximity = function() return true end })
    local confirmed = mode:confirm(42, { quoteId = booking.quote.quoteId })
    s15Check(confirmed.ok and confirmed.value.phase == 'RESERVED' and booking.status == 'RESERVED', 'MEET_THERE confirmation should reserve booking and destination')
    local travel = mode:startTravel(42, booking.id)
    s15Check(travel.ok and booking.status == 'TRAVELLING', 'MEET_THERE should start one server-owned NPC travel plan')
    local client = mode:confirmClientArrival(42, { bookingId = booking.id })
    s15Check(client.ok and client.value.waiting and booking.status == 'TRAVELLING', 'client arrival alone must wait at the barrier')
    local early = mode:startSession(42, booking.id, {})
    s15Check(not early.ok and early.error.code == Codes.DUAL_TRAVEL_CONFLICT, 'session must not start before both sides arrive')
    local spawn = mode:requestSpawn(42, booking.id)
    local npc = mode:confirmNpcArrival(42, { bookingId = booking.id, entity = 701, generationToken = spawn.value.generationToken })
    s15Check(spawn.ok and npc.ok and npc.value.phase == 'ARRIVED' and booking.status == 'ARRIVED', 'both arrivals should cross the canonical barrier')
    local npcReplay = mode:confirmNpcArrival(42, { bookingId = booking.id, entity = 701, generationToken = spawn.value.generationToken })
    s15Check(npcReplay.ok and npcReplay.metadata and npcReplay.metadata.idempotent == true, 'NPC arrival replay should remain idempotent after the barrier')
    local started = mode:startSession(42, booking.id, {})
    s15Check(started.ok and booking.status == 'ACTIVE', 'dual travel should use the unified appointment session')
    local completed = mode:completeSession(42, started.value.token, { bookingId = booking.id, token = started.value.token })
    s15Check(completed.ok and booking.status == 'SETTLED', 'dual travel should use exactly-once settlement')
    local completionReplay = mode:completeSession(42, started.value.token, { bookingId = booking.id, token = started.value.token })
    s15Check(completionReplay.ok and completionReplay.metadata and completionReplay.metadata.idempotent == true, 'settlement replay should return the stored outcome')
    local facade = assert(NightShift.ClientModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity,
        workerService = worker, dualTravelService = mode
    }))
    local tokenOnlyReplay = facade:completeSession(42, started.value.token, { token = started.value.token })
    s15Check(tokenOnlyReplay.ok and tokenOnlyReplay.metadata and tokenOnlyReplay.metadata.idempotent == true, 'token-only completion should route to MEET_THERE')
end

do
    local mode, booking, _, _, bookingService, repository, identity, worker, location, locationReservation, travel, spawn, arrival, session, settlement =
        fixture({ proximity = function() return true end })
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok, 'restart fixture should confirm before restart')
    local restarted = assert(NightShift.DualTravelService.new({
        bookingService = bookingService, repository = repository, identityService = identity, workerService = worker,
        locationService = location, locationReservationService = locationReservation, travelService = travel,
        spawnService = spawn, arrivalService = arrival, appointmentSessionService = session, settlementService = settlement,
        clientProximityCheck = function() return true end
    }))
    local retry = restarted:confirm(42, { quoteId = booking.quote.quoteId })
    s15Check(retry.ok and retry.metadata and retry.metadata.idempotent == true and booking.status == 'RESERVED', 'reserved confirmation should rehydrate after restart')
end

do
    local mode, booking, _, _, bookingService, repository, identity, worker, location, locationReservation, travel, spawn, arrival, session, settlement =
        fixture({ proximity = function() return true end })
    booking.status, booking.version = 'SETTLED', 7
    local restarted = assert(NightShift.DualTravelService.new({
        bookingService = bookingService, repository = repository, identityService = identity, workerService = worker,
        locationService = location, locationReservationService = locationReservation, travelService = travel,
        spawnService = spawn, arrivalService = arrival, appointmentSessionService = session, settlementService = settlement
    }))
    local restartedToken = 'appointment:dual:restarted'
    local replay = restarted:completeSession(42, restartedToken, { bookingId = booking.id, token = restartedToken })
    s15Check(replay.ok and replay.metadata and replay.metadata.idempotent == true and replay.value.booking.status == 'SETTLED', 'settled completion should be idempotent after restart')
end

do
    local mode, booking, clock = fixture({ proximity = function() return true end, grace = 20 })
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok, 'no-show fixture should confirm')
    s15Check(mode:startTravel(42, booking.id).ok, 'no-show fixture should travel')
    local spawn = mode:requestSpawn(42, booking.id)
    s15Check(mode:confirmNpcArrival(42, { bookingId = booking.id, entity = 701, generationToken = spawn.value.generationToken }).ok, 'worker arrival should be accepted')
    clock.value = clock.value + 21
    local noShow = mode:tick(42, booking.id)
    s15Check(not noShow.ok and noShow.error.code == Codes.CLIENT_NO_SHOW and booking.status == 'CANCELLED', 'late client should produce CLIENT_NO_SHOW and cancellation')
end

do
    local mode, booking, clock = fixture({ proximity = function() return true end, grace = 20, locationReleaseFailed = true })
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok and mode:startTravel(42, booking.id).ok, 'cleanup failure fixture should travel')
    s15Check(mode:confirmClientArrival(42, { bookingId = booking.id }).ok, 'cleanup failure fixture should record client arrival')
    clock.value = clock.value + 21
    local recovery = mode:tick(42, booking.id)
    s15Check(not recovery.ok and recovery.error.code == Codes.DUAL_TRAVEL_RECOVERY_REQUIRED and booking.status == 'CANCELLED', 'cleanup failure must surface a retryable recovery outcome')
end

do
    local mode, booking = fixture({ proximity = function() return true end, spawnFailed = true })
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok and mode:startTravel(42, booking.id).ok, 'worker failure fixture should travel')
    local failed = mode:requestSpawn(42, booking.id)
    s15Check(not failed.ok and failed.error.code == Codes.WORKER_NO_SHOW and booking.status == 'CANCELLED', 'NPC spawn failure should become WORKER_NO_SHOW')
end

do
    local mode, booking, clock = fixture({ proximity = function() return true end, grace = 20 })
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok and mode:startTravel(42, booking.id).ok, 'both-late fixture should travel')
    clock.value = clock.value + 31
    local noShow = mode:tick(42, booking.id)
    s15Check(not noShow.ok and noShow.error.code == Codes.WORKER_NO_SHOW and booking.status == 'CANCELLED', 'both late should expire the worker arrival deadline deterministically')
end

do
    local mode, booking = fixture()
    s15Check(mode:confirm(42, { quoteId = booking.quote.quoteId }).ok and mode:startTravel(42, booking.id).ok, 'proximity fixture should travel')
    local rejected = mode:confirmClientArrival(42, { bookingId = booking.id, position = { x = 0, y = 0, z = 0 } })
    s15Check(not rejected.ok and rejected.error.code == Codes.DUAL_TRAVEL_PROXIMITY_UNAVAILABLE, 'client arrival must fail closed without a server verifier')
end

print('NS-150/NS-151/NS-152 tests passed: dual arrival barrier, grace/no-show outcomes, unified session and settlement')
