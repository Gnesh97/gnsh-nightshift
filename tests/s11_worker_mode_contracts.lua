local function workerModeCheck(value, message)
    assert(value, message)
end

do
    local now = 3000
    local clock = { now = function() return now end, timestamp = function() return '1970-01-01T00:50:00Z' end }
    local availabilityState = { state = 'AVAILABLE', available = true, identityKey = 'player:7', source = 7 }
    local availability = {
        get = function() return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end,
        lockForBooking = function(_, source, bookingId) availabilityState.state, availabilityState.available, availabilityState.bookingId = 'BUSY', false, bookingId; return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end,
        releaseBooking = function() availabilityState.state, availabilityState.available, availabilityState.bookingId = 'AVAILABLE', true, nil; return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end
    }
    local opportunity = { opportunityKey = 'customer-opportunity:7:1', state = 'AVAILABLE', source = 7, identityKey = 'player:7', district = 'vinewood', zone = 'vinewood_hills', demandScore = 65, demandBand = 'HIGH', customer = { profileKey = 'npc-customer:7:1', budgetClass = 3, priceClass = 3, traits = { patience = 80, negotiation = 80 } } }
    local customer = {
        get = function() return NightShift.Result.ok(NightShift.Validators.copy(opportunity)) end,
        claim = function() opportunity.state = 'CLAIMED'; return NightShift.Result.ok(NightShift.Validators.copy(opportunity)) end
    }
    local catalog = { get = function() return NightShift.Result.ok({ id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD', meetingModes = { 'MEET_THERE' }, locationIds = { 'configured_default' } }) end }
    local bookings, sequence, lastAcceptOptions, idempotentBookings = {}, 0, nil, {}
    local draftIdempotencyKey
    local bookingService = {
        createDraft = function(_, actor, input) draftIdempotencyKey = input.idempotencyKey; if idempotentBookings[input.idempotencyKey] then return NightShift.Result.ok(NightShift.Validators.copy(idempotentBookings[input.idempotencyKey])) end; sequence = sequence + 1; local value = { id = 'booking-' .. sequence, version = 1, status = 'DRAFT', workerType = 'PLAYER', workerRef = actor.ref, clientType = 'NPC', clientRef = input.clientRef, locationType = input.locationType, locationRef = input.locationRef, meetingMode = input.meetingMode, servicePackage = { id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD' } }; bookings[value.id] = value; idempotentBookings[input.idempotencyKey] = value; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        applyAuthoritativeQuote = function(_, actor, id, quote, expected) local value = bookings[id]; value.quote = NightShift.Validators.copy(quote); value.version = expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        offer = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'OFFERED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        accept = function(_, actor, id, expected, options) lastAcceptOptions = NightShift.Validators.copy(options); local value = bookings[id]; value.status, value.version, value.agreedPrice = 'ACCEPTED', expected + 1, { amountMinor = value.quote.amountMinor, currency = value.quote.currency }; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        reserve = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'RESERVED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        get = function(_, id) return bookings[id] and NightShift.Result.ok(NightShift.Validators.copy(bookings[id])) or NightShift.Result.err('BOOKING_NOT_FOUND', 'missing') end
    }
    local locationReservation = { reserve = function(_, id) return NightShift.Result.ok({ reservationKey = 'location:configured_default:' .. id, status = 'RESERVED' }) end, release = function() return NightShift.Result.ok({}) end }
    local negotiation = NightShift.NegotiationService.new({ clock = clock, config = { enabled = true, maxRounds = 3, expirySeconds = 300, minimumOfferFactor = 0.75, maximumOfferFactor = 1.25, counterStepFactor = 0.05, counterPatienceCost = 10 } })
    local workerMode, workerError = NightShift.WorkerModeService.new({ clock = clock, customerService = customer, negotiationService = negotiation, workerAvailabilityService = availability, bookingService = bookingService, serviceCatalog = catalog, locationReservationService = locationReservation, settlementService = { settle = function() return NightShift.Result.ok({ status = 'SETTLED' }) end } })
    workerModeCheck(workerMode and not workerError, 'worker mode service should construct')
    local actor = { type = 'PLAYER', ref = 'player:7', source = 7 }
    local started = workerMode:start(actor, opportunity.opportunityKey, { servicePackageId = 'standard', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default', meetingMode = 'MEET_THERE' })
    workerModeCheck(started.ok, 'worker mode should create negotiation from a claimed customer')
    local accepted = workerMode:counter(actor, started.value.negotiation.id, started.value.negotiation.currentOfferMinor, started.value.negotiation.version)
    workerModeCheck(accepted.ok and accepted.value.booking.status == 'RESERVED', 'accepted negotiation should bridge into a reserved booking')
    workerModeCheck(draftIdempotencyKey == 'worker-mode:' .. started.value.negotiation.id .. ':3000', 'booking idempotency must be scoped to the current negotiation instance')
    workerModeCheck(availabilityState.state == 'BUSY' and availabilityState.bookingId == accepted.value.booking.id, 'accepted worker booking must lock availability')
    workerModeCheck(accepted.value.booking.agreedPrice.amountMinor == accepted.value.negotiation.acceptedPrice.amountMinor, 'booking must freeze negotiated price')
    workerModeCheck(lastAcceptOptions and lastAcceptOptions.authoritativeQuote == true and lastAcceptOptions.quote and lastAcceptOptions.quote.expiresAt == nil, 'worker booking acceptance must use the accepted negotiation quote')

    local partial = bookings[accepted.value.booking.id]
    partial.status, partial.version = 'QUOTED', 2
    partial.quote = { amountMinor = accepted.value.negotiation.acceptedPrice.amountMinor, currency = 'USD', quoteId = 'negotiation:' .. accepted.value.negotiation.id }
    local context = workerMode._contexts[accepted.value.negotiation.id]
    context.bookingId, context.reservation = nil, nil
    availabilityState.state, availabilityState.available, availabilityState.bookingId = 'AVAILABLE', true, nil
    local resumed = workerMode:accept(actor, accepted.value.negotiation.id, accepted.value.negotiation.version)
    workerModeCheck(resumed.ok and resumed.value.booking.status == 'RESERVED', 'accepted negotiation should resume a persisted quoted booking after a partial failure')
    workerModeCheck(lastAcceptOptions and lastAcceptOptions.authoritativeQuote == true and lastAcceptOptions.quote and lastAcceptOptions.quote.expiresAt == nil, 'partial worker booking must use an authoritative quote without stale expiry')
end

do
    local now = 4000
    local clock = { now = function() return now end, timestamp = function() return '1970-01-01T01:06:40Z' end }
    local availabilityState = { state = 'AVAILABLE', available = true, identityKey = 'player:8', source = 8 }
    local availability = {
        get = function() return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end,
        lockForBooking = function(_, source, bookingId) availabilityState.state, availabilityState.available, availabilityState.bookingId = 'BUSY', false, bookingId; return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end,
        releaseBooking = function() availabilityState.state, availabilityState.available, availabilityState.bookingId = 'AVAILABLE', true, nil; return NightShift.Result.ok(NightShift.Validators.copy(availabilityState)) end
    }
    local opportunity = { opportunityKey = 'customer-opportunity:8:1', state = 'AVAILABLE', source = 8, identityKey = 'player:8', district = 'vinewood', zone = 'vinewood_hills', demandScore = 65, demandBand = 'HIGH', customer = { profileKey = 'npc-customer:8:1', budgetClass = 3, priceClass = 3, traits = { patience = 80, negotiation = 80 } } }
    local customer = {
        get = function() return NightShift.Result.ok(NightShift.Validators.copy(opportunity)) end,
        claim = function() opportunity.state = 'CLAIMED'; return NightShift.Result.ok(NightShift.Validators.copy(opportunity)) end
    }
    local catalog = { get = function() return NightShift.Result.ok({ id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD', meetingModes = { 'MEET_THERE' }, locationIds = { 'configured_default' } }) end }
    local bookings, sequence = {}, 0
    local bookingService = {
        createDraft = function(_, actor, input) sequence = sequence + 1; local value = { id = 'booking-slice-' .. sequence, version = 1, status = 'DRAFT', workerType = 'PLAYER', workerRef = actor.ref, clientType = 'NPC', clientRef = input.clientRef, locationType = input.locationType, locationRef = input.locationRef, meetingMode = input.meetingMode, servicePackage = { id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD' } }; bookings[value.id] = value; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        applyAuthoritativeQuote = function(_, actor, id, quote, expected) local value = bookings[id]; value.quote = NightShift.Validators.copy(quote); value.version = expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        offer = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'OFFERED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        accept = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version, value.agreedPrice = 'ACCEPTED', expected + 1, { amountMinor = value.quote.amountMinor, currency = value.quote.currency }; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        reserve = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'RESERVED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        startTravel = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'TRAVELLING', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        markArrival = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'ARRIVED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        startActive = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version, value.startAt = 'ACTIVE', expected + 1, '1970-01-01T01:06:40Z'; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        complete = function(_, actor, id, expected) local value = bookings[id]; value.status, value.version = 'COMPLETED', expected + 1; return NightShift.Result.ok(NightShift.Validators.copy(value)) end,
        get = function(_, id) return bookings[id] and NightShift.Result.ok(NightShift.Validators.copy(bookings[id])) or NightShift.Result.err('BOOKING_NOT_FOUND', 'missing') end
    }
    local locationReservation = { reserve = function(_, id) return NightShift.Result.ok({ reservationKey = 'location:configured_default:' .. id, status = 'RESERVED' }) end, release = function() return NightShift.Result.ok({}) end }
    local settlementCalls = 0
    local settlement = { settle = function(_, actor, bookingId) settlementCalls = settlementCalls + 1; local booking = bookings[bookingId]; booking.status, booking.version = 'SETTLED', booking.version + 1; return NightShift.Result.ok({ status = 'SETTLED', booking = NightShift.Validators.copy(booking), payment = { idempotencyKey = 'settlement:' .. bookingId } }) end }
    local profile = { completedBookings = 0, version = 1 }
    local profileService = {
        get = function() return NightShift.Result.ok(NightShift.Validators.copy(profile)) end,
        update = function(_, _, changes) profile.completedBookings = changes.completedBookings; profile.version = profile.version + 1; return NightShift.Result.ok(NightShift.Validators.copy(profile)) end
    }
    local negotiation = NightShift.NegotiationService.new({ clock = clock, config = { enabled = true, maxRounds = 3, expirySeconds = 300, minimumOfferFactor = 0.75, maximumOfferFactor = 1.25, counterStepFactor = 0.05, counterPatienceCost = 10 } })
    local sessions = NightShift.AppointmentSessionService.new({ bookingService = bookingService, clock = clock, minimumDurationSeconds = 5, tokenTtlSeconds = 60, locationVerifier = function() return true end, tokenGenerator = function() return 'slice-session-token' end })
    local workerMode = NightShift.WorkerModeService.new({ clock = clock, customerService = customer, negotiationService = negotiation, workerAvailabilityService = availability, bookingService = bookingService, serviceCatalog = catalog, locationReservationService = locationReservation, appointmentSessionService = sessions, settlementService = settlement, workerProfileService = profileService })
    local actor = { type = 'PLAYER', ref = 'player:8', source = 8 }
    local started = workerMode:start(actor, opportunity.opportunityKey, { servicePackageId = 'standard', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default', meetingMode = 'MEET_THERE' })
    workerModeCheck(started.ok, 'vertical slice should start from an NPC opportunity')
    local booked = workerMode:accept(actor, started.value.negotiation.id, started.value.negotiation.version)
    workerModeCheck(booked.ok and booked.value.booking.status == 'RESERVED', 'vertical slice should create a reserved booking')
    local travelling = workerMode:startTravel(actor, booked.value.booking.id)
    workerModeCheck(travelling.ok and travelling.value.status == 'TRAVELLING', 'vertical slice should start travel')
    local arrived = workerMode:markArrival(actor, booked.value.booking.id)
    workerModeCheck(arrived.ok and arrived.value.status == 'ARRIVED', 'vertical slice should validate arrival state')
    local session = workerMode:startSession(actor, booked.value.booking.id, { locationRef = 'configured_default' })
    workerModeCheck(session.ok and session.value.token == 'slice-session-token', 'vertical slice should issue a bound appointment token')
    local early = workerMode:completeSession(actor, session.value.token, { bookingId = booked.value.booking.id, payerSource = 99, locationRef = 'configured_default' })
    workerModeCheck(not early.ok and early.error.code == 'APPOINTMENT_SESSION_TOO_EARLY', 'vertical slice should reject instant completion')
    now = now + 5
    local configuredSettlement = workerMode._settlement
    workerMode._settlement = nil
    local unavailable = workerMode:completeSession(actor, session.value.token, { bookingId = booked.value.booking.id, payerSource = 99, locationRef = 'configured_default' })
    workerMode._settlement = configuredSettlement
    workerModeCheck(not unavailable.ok and unavailable.error.code == 'SETTLEMENT_NOT_READY', 'unavailable settlement must not consume the appointment session')
    local completed = workerMode:completeSession(actor, session.value.token, { bookingId = booked.value.booking.id, payerSource = 99, locationRef = 'configured_default' })
    workerModeCheck(completed.ok and completed.value.booking.status == 'SETTLED' and settlementCalls == 1, 'vertical slice should settle exactly once')
    workerModeCheck(profile.completedBookings == 1 and availabilityState.state == 'AVAILABLE', 'vertical slice should update the worker counter and release BUSY state')
    local replay = workerMode:completeSession(actor, session.value.token, { bookingId = booked.value.booking.id, payerSource = 99, locationRef = 'configured_default' })
    workerModeCheck(not replay.ok and replay.error.code == 'APPOINTMENT_SESSION_REPLAY' and settlementCalls == 1, 'completed session replay must not settle twice')
end

print('NS-111/NS-113 tests passed: NPC opportunity claim, negotiated booking bridge, session settlement, profile update, and worker BUSY lock')
