local function s14Check(value, message)
    assert(value, message)
end

local function s14Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[s14Copy(key, seen)] = s14Copy(item, seen) end
    return output
end

local Codes = NightShift.Errors.Codes

do
    local registry = assert(NightShift.NpcEntityRegistry.new())
    local created = assert(registry:register('profile:pickup', { travelKey = 'pickup-travel:1:pickup', bookingId = 'booking:pickup:registry', entity = 701, owner = 42, state = 'BOUND' }))
    local rebound = registry:updateTravel('profile:pickup', created.value.generationToken, 'pickup-travel:1:destination', 'booking:pickup:registry')
    s14Check(rebound.ok and rebound.value.travelKey == 'pickup-travel:1:destination', 'pickup second leg should rebind the same NPC generation')
    local stale = registry:validate('profile:pickup', created.value.generationToken, { travelKey = 'pickup-travel:1:pickup' })
    s14Check(not stale.ok and stale.error.code == Codes.ENTITY_GENERATION_MISMATCH, 'old pickup travel key must not validate after rebind')
end

do
    local pickup = assert(NightShift.PickupLocationService.new({
        candidates = {
            { locationRef = 'pickup:vinewood:1', district = 'vinewood', locationType = 'SAFE_ROADSIDE',
                worldTarget = { kind = 'coords', x = 315, y = -1004, z = 29.3 }, priority = 1,
                roadSuitable = true, navSuitable = true },
            { locationRef = 'pickup:vinewood:blocked', district = 'vinewood', locationType = 'SAFE_ROADSIDE',
                worldTarget = { kind = 'coords', x = 330, y = -1004, z = 29.3 }, priority = 2,
                roadSuitable = false, navSuitable = true }
        }, maxDistance = 5000
    }))
    local selected = pickup:resolve(42, { district = 'vinewood', destination = { kind = 'coords', x = 250, y = -1000, z = 29 } })
    s14Check(selected.ok and selected.value.serverGenerated == true and selected.value.locationRef == 'pickup:vinewood:1', 'pickup resolver should select a server-owned safe roadside point')
    local arbitrary = pickup:resolve(42, { district = 'vinewood', coords = { x = 1, y = 2, z = 3 } })
    s14Check(not arbitrary.ok and arbitrary.error.code == Codes.PICKUP_LOCATION_INVALID, 'pickup resolver must reject arbitrary client coordinates')
    local reserved = pickup:reserve('booking:pickup:location', { district = 'vinewood' }, { source = 42 })
    s14Check(reserved.ok and reserved.value.pickup.serverGenerated == true, 'pickup reservation should retain the server-generated point')
    local retry = pickup:reserve('booking:pickup:location', { district = 'vinewood' }, { source = 42 })
    s14Check(retry.ok and retry.metadata and retry.metadata.idempotent == true, 'pickup reservation should be idempotent')
    local conflict = pickup:reserve('booking:pickup:other', { candidateRef = 'pickup:vinewood:1' }, { source = 42 })
    s14Check(not conflict.ok and conflict.error.code == Codes.PICKUP_LOCATION_CONFLICT, 'a pickup point cannot be reserved by two bookings')
end

do
    local booking = {
        id = 'booking:pickup:vehicle', version = 1, status = 'TRAVELLING',
        clientType = 'PLAYER', clientRef = 'player:one', workerType = 'NPC', workerRef = 'npc:one', meetingMode = 'PICKUP'
    }
    local vehicleState = { exists = true, serverVisible = true, vehicleId = 'car:one', seatAvailable = true, npcNearby = true }
    local bookingService = {
        get = function(_, id) return tostring(id) == booking.id and NightShift.Result.ok(s14Copy(booking)) or NightShift.Result.err(Codes.BOOKING_NOT_FOUND, 'missing') end
    }
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = source == 42 and 'player:one' or 'player:other' }) end }
    local resolver = { resolve = function(_, source, request) return NightShift.Result.ok(s14Copy(vehicleState)) end }
    local vehicles = assert(NightShift.PickupVehicleService.new({ bookingService = bookingService, identityService = identity, vehicleLocationService = resolver }))
    local wrongOwner = vehicles:bind(99, { bookingId = booking.id, vehicleId = 'car:one' })
    s14Check(not wrongOwner.ok and wrongOwner.error.code == Codes.PICKUP_OWNER_MISMATCH, 'wrong player cannot bind the pickup vehicle')
    vehicleState.seatAvailable = false
    local noSeat = vehicles:bind(42, { bookingId = booking.id, vehicleId = 'car:one' })
    s14Check(not noSeat.ok and noSeat.error.code == Codes.PICKUP_VEHICLE_SEAT_UNAVAILABLE, 'unavailable passenger seat must be rejected')
    vehicleState.seatAvailable = true
    local bound = vehicles:bind(42, { bookingId = booking.id, vehicleId = 'car:one', seat = 0 })
    s14Check(bound.ok and bound.value.state == 'BOUND' and bound.value.vehicleRef == 'vehicle:car:one', 'vehicle binding should be server-owned and booking-scoped')
    local entered = vehicles:confirmEntry(42, { bookingId = booking.id })
    s14Check(entered.ok and entered.value.state == 'OCCUPIED', 'vehicle entry should transition the binding')
    vehicleState.exists = false
    local destroyed = vehicles:validate(42, { bookingId = booking.id })
    s14Check(not destroyed.ok and destroyed.error.code == Codes.PICKUP_VEHICLE_DESTROYED, 'destroyed vehicles must require recovery')
end

do
    local clock = { value = 100, now = function(self) return self.value end }
    local recovered, noShow = false, false
    local controller = assert(NightShift.ClientPickupController.new({
        clock = clock, waitingTimeoutSeconds = 30, playerProximityMeters = 5,
        playerDistance = function() return 2 end,
        entityExists = function() return true end,
        onRecovery = function() recovered = true end,
        onNoShow = function() noShow = true end
    }))
    local context = {
        serverOwned = true, bookingId = 'booking:pickup:controller', workerKey = 'npc:one', profileKey = 'profile:one',
        generationToken = 'npc:profile:one:1', entity = 701, ownerRef = 'player:one', ownerSource = 42,
        pickup = { worldTarget = { kind = 'coords', x = 315, y = -1004, z = 29.3 } }
    }
    local started = controller:start(context)
    s14Check(started.ok and started.value.state == 'WAITING', 'pickup controller should enter waiting state after arrival')
    local wrong = controller:claim({ bookingId = context.bookingId, ownerRef = 'player:other', source = 99 })
    s14Check(not wrong.ok and wrong.error.code == Codes.PICKUP_OWNER_MISMATCH and controller:get().value.state == 'WAITING', 'wrong player cannot claim a waiting NPC')
    clock.value = 131
    local timedOut = controller:tick()
    s14Check(not timedOut.ok and timedOut.error.code == Codes.PICKUP_WAITING_TIMEOUT and noShow and not recovered, 'waiting timeout should produce a no-show recovery signal')
end

do
    local clock = { value = 1000, now = function(self) return self.value end }
    local booking = {
        id = 'booking:pickup:e2e', version = 1, status = 'ACCEPTED',
        clientType = 'PLAYER', clientRef = 'player:one', workerType = 'NPC', workerRef = 'npc:one', meetingMode = 'PICKUP',
        locationType = 'CONFIG_LOCATION', locationRef = 'configured_default',
        quote = { quoteId = 'quote:pickup:e2e', expiresAt = 2000 }
    }
    local plans = {}
    local bookingService = {}
    local function resultBooking()
        return NightShift.Result.ok(s14Copy(booking))
    end
    function bookingService:get(id) return tostring(id) == booking.id and resultBooking() or NightShift.Result.err(Codes.BOOKING_NOT_FOUND, 'missing') end
    function bookingService:reserve(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'RESERVED', booking.version + 1; return resultBooking() end
    function bookingService:startTravel(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'TRAVELLING', booking.version + 1; return resultBooking() end
    function bookingService:markArrival(_, id, expected) if expected and expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'ARRIVED', booking.version + 1; return resultBooking() end
    function bookingService:interrupt(_, id, expected) if expected ~= booking.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end; booking.status, booking.version = 'INTERRUPTED', booking.version + 1; return resultBooking() end
    local repository = { findByQuoteId = function(_, quoteId) return quoteId == booking.quote.quoteId and resultBooking() or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end }
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = source == 42 and 'player:one' or 'player:other' }) end }
    local worker = {
        get = function(_, key) return NightShift.Result.ok({ workerKey = key, profileKey = 'profile:one', state = 'AVAILABLE', activeDistrict = 'vinewood', profile = { profileKey = 'profile:one' } }) end,
        reserve = function(_, key, id) return NightShift.Result.ok({ workerKey = key, profileKey = 'profile:one', state = 'RESERVED', bookingId = id, activeDistrict = 'vinewood' }) end,
        release = function() return NightShift.Result.ok({ state = 'AVAILABLE' }) end
    }
    local location = { resolve = function(_, source, request) return NightShift.Result.ok({ locationType = request.locationType, locationRef = request.locationRef, worldTarget = { kind = 'coords', x = 250, y = -1000, z = 29 }, meetingMode = 'PICKUP' }) end }
    local locationReservation = {
        reserve = function(_, id, request) return NightShift.Result.ok({ reservationKey = 'reservation:' .. tostring(request.locationRef), locationRef = request.locationRef, status = 'RESERVED' }) end,
        release = function() return NightShift.Result.ok({ status = 'RELEASED' }) end
    }
    local pickupLocation = assert(NightShift.PickupLocationService.new({ candidates = {
        { locationRef = 'pickup:vinewood:e2e', district = 'vinewood', locationType = 'SAFE_ROADSIDE', worldTarget = { kind = 'coords', x = 315, y = -1004, z = 29.3 }, priority = 1 }
    } }))
    local vehicle = { resolve = function() return NightShift.Result.ok({ vehicleId = 'car:e2e', exists = true, serverVisible = true, seatAvailable = true, npcNearby = true }) end }
    local pickupVehicle = assert(NightShift.PickupVehicleService.new({ bookingService = bookingService, identityService = identity, vehicleLocationService = vehicle }))
    local travel = {
        create = function(_, source, request) local plan = { travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, state = 'TRAVELLING', progress = 0 }; plans[request.travelKey] = plan; return NightShift.Result.ok(s14Copy(plan)) end,
        get = function(_, key) return plans[key] and NightShift.Result.ok(s14Copy(plans[key])) or NightShift.Result.err(Codes.TRAVEL_NOT_FOUND, 'missing') end,
        markArrival = function(_, key) plans[key].state = 'ARRIVED'; return NightShift.Result.ok(s14Copy(plans[key])) end,
        updateProgress = function(_, key, value) plans[key].progress = value; return NightShift.Result.ok(s14Copy(plans[key])) end,
        cancel = function(_, key) plans[key].state = 'CANCELLED'; return NightShift.Result.ok(s14Copy(plans[key])) end
    }
    local spawn = {
        request = function(_, source, request) return NightShift.Result.ok({ serverOwned = true, travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, generationToken = 'npc:profile:one:1', entity = 701 }) end,
        confirmSpawn = function(_, source, request) return NightShift.Result.ok({ serverOwned = true, travelKey = request.travelKey, bookingId = request.bookingId, profileKey = request.profileKey, generationToken = request.generationToken, entity = request.entity }) end
    }
    local arrival = {
        validateOnly = function(_, source, request) return NightShift.Result.ok({ bookingId = request.bookingId, travel = plans[request.travelKey] }) end,
        accept = function(_, source, request) booking.status, booking.version = 'ARRIVED', booking.version + 1; return NightShift.Result.ok({ booking = resultBooking().value, travel = plans[request.travelKey] }) end
    }
    local pickupSessionToken = 'appointment:pickup:e2e'
    local session = {
        start = function(_, actor, id) booking.status, booking.version = 'ACTIVE', booking.version + 1; return NightShift.Result.ok({ token = pickupSessionToken, bookingId = id, state = 'ACTIVE', booking = resultBooking().value }) end,
        complete = function(_, actor, token) booking.status, booking.version = 'COMPLETED', booking.version + 1; return NightShift.Result.ok({ session = { token = token, state = 'COMPLETED' }, booking = resultBooking().value }) end
    }
    local settlement = { settle = function(_, actor, id) booking.status, booking.version = 'SETTLED', booking.version + 1; return NightShift.Result.ok({ status = 'SETTLED', booking = resultBooking().value }) end }
    local mode = assert(NightShift.PickupModeService.new({
        bookingService = bookingService, repository = repository, identityService = identity, workerService = worker,
        locationService = location, locationReservationService = locationReservation, pickupLocationService = pickupLocation,
        pickupVehicleService = pickupVehicle, travelService = travel, spawnService = spawn, arrivalService = arrival,
        appointmentSessionService = session, settlementService = settlement, clock = clock
    }))
    local confirmed = mode:confirm(42, { quoteId = booking.quote.quoteId })
    s14Check(confirmed.ok and confirmed.value.phase == 'PICKUP_PENDING' and booking.status == 'RESERVED', 'pickup confirmation should reserve the booking and safe pickup point')
    local travelling = mode:startTravel(42, booking.id)
    s14Check(travelling.ok and travelling.value.travel.travelKey:match(':pickup$') and booking.status == 'TRAVELLING', 'pickup first leg should use a dedicated travel plan')
    local authorized = mode:requestSpawn(42, booking.id)
    local spawned = mode:confirmSpawn(42, { bookingId = booking.id, travelKey = authorized.value.spawn.travelKey, profileKey = 'profile:one', generationToken = authorized.value.spawn.generationToken, entity = 701 })
    s14Check(authorized.ok and spawned.ok, 'pickup NPC spawn must remain generation-bound')
    local waiting = mode:confirmPickupArrival(42, { bookingId = booking.id, entity = 701 })
    s14Check(waiting.ok and waiting.value.waiting == true and booking.status == 'TRAVELLING', 'pickup arrival must not mark the booking destination-arrived')
    local bound = mode:bindVehicle(42, { bookingId = booking.id, vehicleId = 'car:e2e', seat = 0 })
    s14Check(bound.ok and bound.value.phase == 'VEHICLE_BOUND', 'pickup vehicle should bind after NPC waiting')
    local destinationTravel = mode:startDestinationTravel(42, booking.id)
    s14Check(destinationTravel.ok and destinationTravel.value.travel.travelKey:match(':destination$'), 'pickup should start its destination leg after vehicle binding')
    local destination = mode:confirmDestinationArrival(42, { bookingId = booking.id })
    s14Check(destination.ok and booking.status == 'ARRIVED', 'destination arrival should transition the canonical booking')
    local started = mode:startSession(42, booking.id, {})
    s14Check(started.ok and booking.status == 'ACTIVE', 'pickup should use the unified appointment session')
    local completed = mode:completeSession(42, started.value.token, { bookingId = booking.id })
    s14Check(completed.ok and booking.status == 'SETTLED', 'pickup should complete through exactly-once settlement')
end

print('NS-140..NS-143 tests passed: server-owned pickup, waiting/no-show, owner vehicle binding, dual-leg progression, recovery contracts')
