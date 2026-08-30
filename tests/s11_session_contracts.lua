local function sessionCheck(value, message)
    assert(value, message)
end

do
    local now = 2000
    local clock = { now = function() return now end, timestamp = function() return '1970-01-01T00:33:20Z' end }
    local bookings = {
        ['booking-1'] = { id = 'booking-1', status = 'ARRIVED', version = 1, workerType = 'PLAYER', workerRef = 'player:7', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default' }
    }
    local bookingService = {
        get = function(_, id)
            local booking = bookings[id]
            return booking and NightShift.Result.ok(NightShift.Validators.copy(booking)) or NightShift.Result.err('BOOKING_NOT_FOUND', 'missing')
        end,
        startActive = function(_, actor, id, expected)
            local booking = bookings[id]
            if not booking or booking.version ~= expected then return NightShift.Result.err('VERSION_CONFLICT', 'version') end
            booking.status, booking.version, booking.startAt = 'ACTIVE', booking.version + 1, '1970-01-01T00:33:20Z'
            return NightShift.Result.ok(NightShift.Validators.copy(booking))
        end,
        complete = function(_, actor, id, expected)
            local booking = bookings[id]
            if not booking or booking.version ~= expected then return NightShift.Result.err('VERSION_CONFLICT', 'version') end
            booking.status, booking.version = 'COMPLETED', booking.version + 1
            return NightShift.Result.ok(NightShift.Validators.copy(booking))
        end
    }
    local sessions, sessionError = NightShift.AppointmentSessionService.new({
        bookingService = bookingService,
        clock = clock,
        minimumDurationSeconds = 5,
        tokenTtlSeconds = 60,
        locationVerifier = function() return true end,
        tokenGenerator = function() return 'session-token-1' end
    })
    sessionCheck(sessions and not sessionError, 'appointment session service should construct')
    local actor = { type = 'PLAYER', ref = 'player:7', source = 7 }
    local started = sessions:start(actor, 'booking-1', { locationRef = 'configured_default' })
    sessionCheck(started.ok and started.value.state == 'ACTIVE', 'session start should activate booking')
    local remote = sessions:complete({ type = 'PLAYER', ref = 'player:99', source = 99 }, started.value.token, { bookingId = 'booking-1' })
    sessionCheck(not remote.ok and remote.error.code == 'APPOINTMENT_SESSION_OWNER_MISMATCH', 'remote completion must be rejected')
    local early = sessions:complete(actor, started.value.token, { bookingId = 'booking-1' })
    sessionCheck(not early.ok and early.error.code == 'APPOINTMENT_SESSION_TOO_EARLY', 'instant completion must be rejected')
    now = now + 5
    local completed = sessions:complete(actor, started.value.token, { bookingId = 'booking-1', locationRef = 'configured_default' })
    sessionCheck(completed.ok and completed.value.booking.status == 'COMPLETED', 'session should complete after minimum duration')
    local replay = sessions:complete(actor, started.value.token, { bookingId = 'booking-1' })
    sessionCheck(not replay.ok and replay.error.code == 'APPOINTMENT_SESSION_REPLAY', 'session token must be one-time')

    bookings['booking-2'] = { id = 'booking-2', status = 'ARRIVED', version = 1, workerType = 'PLAYER', workerRef = 'player:7', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default' }
    local deniedSessions = NightShift.AppointmentSessionService.new({
        bookingService = bookingService,
        clock = clock,
        locationVerifier = function() return NightShift.Result.ok({ allowed = false }) end
    })
    local denied = deniedSessions:start(actor, 'booking-2', { locationRef = 'configured_default' })
    sessionCheck(not denied.ok and denied.error.code == 'APPOINTMENT_SESSION_LOCATION_INVALID', 'explicitly denied proximity result must reject session start')
end

print('NS-112 tests passed: actor/location binding, minimum duration, completion, and one-time token replay protection')
