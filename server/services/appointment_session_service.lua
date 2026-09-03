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
    if not value or not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function normalizeBookingId(value)
    if integer(value, 1) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    return os.time()
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and text(value, 64) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function invalid(message, details)
    return Result.err(Codes.APPOINTMENT_SESSION_INVALID, message, details)
end

local function actorValue(actor)
    if type(actor) ~= 'table' or not text(actor.ref, 200) then return nil, invalid('appointment session actor is required') end
    local kind = type(actor.type) == 'string' and actor.type:upper() or 'PLAYER'
    if kind ~= 'PLAYER' and kind ~= 'SYSTEM' and kind ~= 'ADMIN' then return nil, invalid('appointment session actor type is invalid') end
    return { type = kind, ref = actor.ref, source = integer(actor.source, 1, 65535) }
end

local function unwrap(result, fallback)
    if type(result) ~= 'table' then return nil, Result.err(fallback, 'appointment service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function normalizeConfig(options)
    local source = type(options.config) == 'table' and copy(options.config) or copy(NightShift.AppointmentSessionConfig or {})
    local enabled = source.enabled == nil and true or source.enabled
    local minimum = integer(options.minimumDurationSeconds or source.minimumDurationSeconds or source.minDurationSeconds or 30, 0, 86400)
    local ttl = integer(options.tokenTtlSeconds or source.tokenTtlSeconds or 900, 1, 86400)
    local proximity = tonumber(options.maxProximityMeters or source.maxProximityMeters or 8)
    if type(enabled) ~= 'boolean' or not minimum or not ttl or not finite(proximity) or proximity <= 0 or proximity > 1000 then
        return nil, invalid('appointment session configuration is invalid')
    end
    return { enabled = enabled, minimumDurationSeconds = minimum, tokenTtlSeconds = ttl, maxProximityMeters = proximity }
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('appointment session options must be a table') end
    local booking = options.bookingService or options.booking
    if type(booking) ~= 'table' or type(booking.get) ~= 'function' or type(booking.startActive) ~= 'function' or type(booking.complete) ~= 'function' then
        return nil, invalid('appointment session service requires a booking service')
    end
    local config, configError = normalizeConfig(options)
    if not config then return nil, configError end
    local clock = options.clock
    if clock == nil and NightShift.Clock and type(NightShift.Clock.new) == 'function' then clock = NightShift.Clock.new() end
    local allowConfiguredLocation = options.allowConfiguredLocation
    if allowConfiguredLocation == nil then
        allowConfiguredLocation = type(options.environment) == 'string' and options.environment:lower() == 'development'
    end
    return setmetatable({
        _bookingService = booking, _location = options.locationService or options.location,
        _locationVerifier = options.locationVerifier or options.proximityCheck,
        _allowConfiguredLocation = allowConfiguredLocation == true,
        _config = config, _clock = clock,
        _sessions = {}, _byBooking = {}, _byActor = {}, _completed = {}, _sequence = 0,
        _tokenGenerator = options.tokenGenerator or options.sessionTokenGenerator
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_booking(id)
    local ok, result = pcall(self._bookingService.get, self._bookingService, id)
    if not ok then return nil, Result.err(Codes.APPOINTMENT_SESSION_INVALID, 'booking lookup failed') end
    return unwrap(result, Codes.APPOINTMENT_SESSION_INVALID)
end

function Service:_nativeProximity(actor, booking)
    if self._allowConfiguredLocation and booking.locationType == 'CONFIG_LOCATION' then return true end
    local getPed = type(GetPlayerPed) == 'function' and GetPlayerPed or nil
    local getCoords = type(GetEntityCoords) == 'function' and GetEntityCoords or nil
    if not getPed or not getCoords or not self._location or type(self._location.resolve) ~= 'function' or not actor.source then return false end
    local resolved = self._location:resolve(actor.source, { locationType = booking.locationType, locationRef = booking.locationRef, meetingMode = booking.meetingMode })
    if type(resolved) ~= 'table' or not resolved.ok then return false end
    local value = resolved.value and (resolved.value.worldTarget or resolved.value.location and resolved.value.location.worldTarget) or nil
    if type(value) ~= 'table' or not finite(value.x) or not finite(value.y) or not finite(value.z) then return false end
    local okPed, ped = pcall(getPed, actor.source)
    if not okPed or not ped or ped == 0 then return false end
    local okCoords, coords = pcall(getCoords, ped)
    if not okCoords or not coords then return false end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not finite(x) or not finite(y) or not finite(z) then return false end
    local distance = math.sqrt((x - value.x) ^ 2 + (y - value.y) ^ 2 + (z - value.z) ^ 2)
    return distance <= self._config.maxProximityMeters
end

function Service:_verifyLocation(actor, booking, request)
    request = type(request) == 'table' and copy(request) or {}
    if request.locationRef ~= nil and tostring(request.locationRef) ~= tostring(booking.locationRef) then
        return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'session location does not match the booking')
    end
    if request.locationType ~= nil and tostring(request.locationType):upper() ~= tostring(booking.locationType):upper() then
        return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'session location type does not match the booking')
    end
    if type(self._locationVerifier) == 'function' then
        local ok, result = pcall(self._locationVerifier, copy(actor), copy(booking), copy(request))
        if not ok or result == false then return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'server could not verify appointment proximity') end
        if type(result) == 'table' then
            if result.ok == false then return nil, result end
            if result.ok == true then
                local value = result.value
                if value == false or (type(value) == 'table' and value.allowed == false) then
                    return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'server could not verify appointment proximity')
                end
            elseif result.allowed == false then
                return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'server could not verify appointment proximity')
            end
        end
        return true
    end
    if self:_nativeProximity(actor, booking) then return true end
    return nil, Result.err(Codes.APPOINTMENT_SESSION_LOCATION_INVALID, 'server proximity verifier is unavailable')
end

function Service:_token(bookingId, actor, request)
    self._sequence = self._sequence + 1
    if type(self._tokenGenerator) == 'function' then
        local ok, value = pcall(self._tokenGenerator, 'appointment', bookingId, copy(actor), copy(request or {}))
        if ok and token(tostring(value or ''), 200) then return tostring(value) end
    end
    return ('appointment:%s:%d'):format(tostring(bookingId), self._sequence)
end

function Service:_remove(session)
    self._sessions[session.token] = nil
    if self._byBooking[session.bookingId] == session.token then self._byBooking[session.bookingId] = nil end
    if self._byActor[session.actorRef] == session.token then self._byActor[session.actorRef] = nil end
end

function Service:start(actor, bookingId, request)
    if not self:isEnabled() then return invalid('appointment sessions are disabled') end
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    if not normalizeBookingId(bookingId) then return invalid('appointment booking ID is invalid') end
    request = request == nil and {} or request
    if type(request) ~= 'table' then return invalid('appointment session start request must be a table') end
    local booking, bookingError = self:_booking(bookingId)
    if not booking then return bookingError end
    if tostring(booking.id) ~= tostring(bookingId) then return invalid('booking lookup returned a mismatched booking') end
    local workerOwns = booking.workerType == 'PLAYER' and booking.workerRef == owner.ref
    local clientOwns = booking.clientType == 'PLAYER' and booking.clientRef == owner.ref
    if not workerOwns and not clientOwns then return Result.err(Codes.APPOINTMENT_SESSION_OWNER_MISMATCH, 'actor does not own this booking') end
    if booking.status ~= 'ARRIVED' then return Result.err(Codes.APPOINTMENT_SESSION_CONFLICT, 'appointment session requires an ARRIVED booking', { status = booking.status }) end
    local actorSession = self._byActor[owner.ref] and self._sessions[self._byActor[owner.ref]]
    if actorSession then
        if actorSession.bookingId == tostring(bookingId) then return Result.ok(copy(actorSession), { idempotent = true }) end
        return Result.err(Codes.APPOINTMENT_SESSION_CONFLICT, 'worker already has an active appointment session', { bookingId = actorSession.bookingId })
    end
    local bookingSession = self._byBooking[tostring(bookingId)] and self._sessions[self._byBooking[tostring(bookingId)]]
    if bookingSession then return Result.ok(copy(bookingSession), { idempotent = true }) end
    local verified, verifyError = self:_verifyLocation(owner, booking, request)
    if not verified then return verifyError end
    local activeResult = self._bookingService:startActive(owner, booking.id, booking.version, function() return true end)
    local active, activeError = unwrap(activeResult, Codes.APPOINTMENT_SESSION_INVALID)
    if not active then return activeError end
    local at = now(self._clock)
    local session = {
        token = self:_token(booking.id, owner, request),
        bookingId = tostring(booking.id), actorRef = owner.ref, actorSource = owner.source,
        locationType = booking.locationType, locationRef = booking.locationRef,
        state = 'ACTIVE', startedAt = at, startedAtTimestamp = timestamp(self._clock),
        expiresAt = at + self._config.tokenTtlSeconds, version = 1,
        booking = copy(active)
    }
    self._sessions[session.token] = session
    self._byBooking[session.bookingId], self._byActor[session.actorRef] = session.token, session.token
    return Result.ok(session, { started = true, serverAuthoritative = true })
end

function Service:complete(actor, sessionToken, request)
    if not self:isEnabled() then return invalid('appointment sessions are disabled') end
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    if not token(tostring(sessionToken or ''), 200) then return invalid('appointment session token is invalid') end
    local completed = self._completed[tostring(sessionToken)]
    if completed then return Result.err(Codes.APPOINTMENT_SESSION_REPLAY, 'appointment session token has already been completed', { bookingId = completed.bookingId }) end
    local session = self._sessions[tostring(sessionToken)]
    if not session then return Result.err(Codes.APPOINTMENT_SESSION_NOT_FOUND, 'appointment session was not found') end
    if session.state ~= 'ACTIVE' then return Result.err(Codes.APPOINTMENT_SESSION_REPLAY, 'appointment session is not active') end
    if session.actorRef ~= owner.ref or (session.actorSource and owner.source and session.actorSource ~= owner.source) then
        return Result.err(Codes.APPOINTMENT_SESSION_OWNER_MISMATCH, 'appointment session belongs to another worker')
    end
    request = request == nil and {} or request
    if type(request) ~= 'table' then return invalid('appointment session completion request must be a table') end
    if request.bookingId ~= nil and tostring(request.bookingId) ~= session.bookingId then
        return Result.err(Codes.APPOINTMENT_SESSION_INVALID, 'session token is bound to another booking')
    end
    local at = now(self._clock)
    if session.expiresAt <= at then
        self:_remove(session)
        return Result.err(Codes.APPOINTMENT_SESSION_NOT_FOUND, 'appointment session token has expired')
    end
    local booking, bookingError = self:_booking(session.bookingId)
    if not booking then return bookingError end
    if booking.status ~= 'ACTIVE' then return Result.err(Codes.APPOINTMENT_SESSION_CONFLICT, 'booking is not active for completion', { status = booking.status }) end
    local verified, verifyError = self:_verifyLocation(owner, booking, request)
    if not verified then return verifyError end
    local elapsed = at - session.startedAt
    if elapsed < self._config.minimumDurationSeconds then
        return Result.err(Codes.APPOINTMENT_SESSION_TOO_EARLY, 'minimum appointment duration has not elapsed', { elapsedSeconds = elapsed, minimumDurationSeconds = self._config.minimumDurationSeconds })
    end
    local result = self._bookingService:complete(owner, booking.id, booking.version, function() return true end)
    local completedBooking, completeError = unwrap(result, Codes.APPOINTMENT_SESSION_INVALID)
    if not completedBooking then return completeError end
    local nextSession = copy(session)
    nextSession.state, nextSession.completedAt, nextSession.completedAtTimestamp, nextSession.booking, nextSession.version = 'COMPLETED', at, timestamp(self._clock), copy(completedBooking), session.version + 1
    self:_remove(session)
    self._completed[nextSession.token] = copy(nextSession)
    return Result.ok({ session = nextSession, booking = completedBooking }, { completed = true, oneTime = true, serverAuthoritative = true })
end

function Service:interrupt(actor, sessionToken, reason)
    if not self:isEnabled() then return invalid('appointment sessions are disabled') end
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    if not token(tostring(sessionToken or ''), 200) then return invalid('appointment session token is invalid') end
    local session = self._sessions[tostring(sessionToken)]
    if not session then
        local completed = self._completed[tostring(sessionToken)]
        if completed then return Result.ok({ session = copy(completed), booking = copy(completed.booking) }, { idempotent = true }) end
        return Result.err(Codes.APPOINTMENT_SESSION_NOT_FOUND, 'appointment session was not found')
    end
    if session.actorRef ~= owner.ref or (session.actorSource and owner.source and session.actorSource ~= owner.source) then
        return Result.err(Codes.APPOINTMENT_SESSION_OWNER_MISMATCH, 'appointment session belongs to another client')
    end
    local booking, bookingError = self:_booking(session.bookingId)
    if not booking then return bookingError end
    if booking.status ~= 'ACTIVE' and booking.status ~= 'ARRIVED' then
        return Result.err(Codes.APPOINTMENT_SESSION_CONFLICT, 'appointment session cannot be interrupted in its current booking state', { status = booking.status })
    end
    local transitioned = self._bookingService:interrupt(owner, booking.id, booking.version, reason or 'client-disconnected')
    local nextBooking, transitionError = unwrap(transitioned, Codes.APPOINTMENT_SESSION_INVALID)
    if not nextBooking then return transitionError end
    local nextSession = copy(session)
    nextSession.state, nextSession.interruptedAt, nextSession.booking, nextSession.version = 'CANCELLED', now(self._clock), copy(nextBooking), session.version + 1
    self:_remove(session)
    self._completed[nextSession.token] = copy(nextSession)
    return Result.ok({ session = nextSession, booking = nextBooking }, { interrupted = true, serverAuthoritative = true })
end

function Service:get(sessionToken)
    if not token(tostring(sessionToken or ''), 200) then return invalid('appointment session token is invalid') end
    local session = self._sessions[tostring(sessionToken)] or self._completed[tostring(sessionToken)]
    if not session then return Result.err(Codes.APPOINTMENT_SESSION_NOT_FOUND, 'appointment session was not found') end
    return Result.ok(session)
end

NightShift.AppointmentSessionService = Service
NightShift.Services.AppointmentSession = Service
