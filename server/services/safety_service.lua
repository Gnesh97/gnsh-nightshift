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
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
    return out
end

local function validText(value, max)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (max or 160)
end

local function id(value)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return tostring(value) end
    if validText(value, 160) and tostring(value):match('^[A-Za-z0-9_.:%-]+$') then return tostring(value) end
end

local function clockNow(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return os.time()
end

local function fail(code, message, details)
    return Result.err(code, message, details)
end

local function actorOf(actor)
    if type(actor) ~= 'table' or not validText(actor.ref, 200) then return nil, fail(Codes.SAFETY_INVALID, 'safety actor is required') end
    local kind = type(actor.type) == 'string' and actor.type:upper() or 'PLAYER'
    if kind ~= 'PLAYER' and kind ~= 'SYSTEM' and kind ~= 'ADMIN' then return nil, fail(Codes.SAFETY_INVALID, 'safety actor type is invalid') end
    return { type = kind, ref = actor.ref, source = actor.source }
end

local function unwrap(result)
    if type(result) ~= 'table' then return nil end
    if result.ok == false then return nil, result end
    return result.ok == true and result.value or result
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' or type(options.bookingService or options.booking) ~= 'table' then
        return nil, fail(Codes.SAFETY_INVALID, 'safety service requires a booking service')
    end
    local interval = tonumber(options.checkInIntervalSeconds or 300)
    if not interval or interval < 0 or interval > 86400 then return nil, fail(Codes.SAFETY_INVALID, 'safety check-in interval is invalid') end
    local clock = options.clock
    return setmetatable({
        _booking = options.bookingService or options.booking,
        _dispatch = options.dispatch,
        _security = options.security,
        _clock = clock,
        _interval = math.floor(interval),
        _states = {}
    }, Service)
end

function Service:_getBooking(bookingId)
    local ok, result = pcall(self._booking.get, self._booking, bookingId)
    if not ok then return nil, fail(Codes.SAFETY_OPERATION_FAILED, 'booking lookup failed') end
    local value, err = unwrap(result)
    if not value then return nil, err or fail(Codes.SAFETY_SESSION_NOT_FOUND, 'booking was not found') end
    return value
end

function Service:_authorize(actor, bookingId)
    local owner, ownerError = actorOf(actor)
    if not owner then return nil, ownerError end
    local key = id(bookingId)
    if not key then return nil, fail(Codes.SAFETY_INVALID, 'booking ID is invalid') end
    local booking, bookingError = self:_getBooking(key)
    if not booking then return nil, bookingError end
    if booking.status ~= 'ACTIVE' then return nil, fail(Codes.SAFETY_NOT_READY, 'safety requires an active booking', { status = booking.status }) end
    local ownsWorker = booking.workerType == 'PLAYER' and tostring(booking.workerRef) == owner.ref
    local ownsClient = booking.clientType == 'PLAYER' and tostring(booking.clientRef) == owner.ref
    if not ownsWorker and not ownsClient then return nil, fail(Codes.SAFETY_OWNER_MISMATCH, 'actor does not own this booking') end
    return owner, booking, key
end

function Service:_state(key, booking, owner)
    local state = self._states[key]
    if state then return state end
    state = { bookingId = key, actorRef = owner.ref, state = 'ACTIVE', checkedIn = false, checkInCount = 0, startedAt = clockNow(self._clock), version = 1 }
    self._states[key] = state
    return state
end

function Service:checkIn(actor, bookingId)
    local owner, booking, key = self:_authorize(actor, bookingId)
    if not owner then return booking end
    local state = self:_state(key, booking, owner)
    if state.actorRef ~= owner.ref then return fail(Codes.SAFETY_OWNER_MISMATCH, 'safety session belongs to another actor') end
    local at = clockNow(self._clock)
    local nextState = copy(state)
    nextState.checkedIn, nextState.lastCheckIn, nextState.checkInCount, nextState.version = true, at, state.checkInCount + 1, state.version + 1
    self._states[key] = nextState
    return Result.ok(copy(nextState), { idempotent = state.checkedIn == true, serverAuthoritative = true })
end

function Service:imOkay(actor, bookingId)
    return self:checkIn(actor, bookingId)
end

function Service:requestEnd(actor, bookingId)
    local owner, booking, key = self:_authorize(actor, bookingId)
    if not owner then return booking end
    local state = self:_state(key, booking, owner)
    if state.actorRef ~= owner.ref then return fail(Codes.SAFETY_OWNER_MISMATCH, 'safety session belongs to another actor') end
    if state.endRequested then
        local existing = copy(state)
        existing.idempotent = true
        return Result.ok(existing, { idempotent = true, serverAuthoritative = true })
    end
    local nextState = copy(state); nextState.endRequested, nextState.endRequestedAt, nextState.version = true, clockNow(self._clock), state.version + 1
    self._states[key] = nextState
    return Result.ok(copy(nextState), { requested = true, serverAuthoritative = true })
end

function Service:requestHelp(actor, bookingId, reason)
    local owner, booking, key = self:_authorize(actor, bookingId)
    if not owner then return booking end
    if reason ~= nil and not validText(reason, 160) then return fail(Codes.SAFETY_INVALID, 'help reason is invalid') end
    local state = self:_state(key, booking, owner)
    local payload = { bookingId = key, actorRef = owner.ref, source = owner.source, reason = reason or 'safety-help-request', requestedAt = clockNow(self._clock) }
    local provider = self._dispatch or self._security
    local providerAvailable = type(provider) == 'table' and type(provider.emitSafetyAlert) == 'function'
    local providerResult
    if providerAvailable then
        local ok, result = pcall(provider.emitSafetyAlert, provider, copy(payload))
        if ok then providerResult = result end
    end
    local nextState = copy(state); nextState.helpRequested, nextState.lastHelpAt, nextState.version = true, payload.requestedAt, state.version + 1
    self._states[key] = nextState
    return Result.ok(copy(nextState), { providerAvailable = providerAvailable, providerResult = copy(providerResult), serverAuthoritative = true })
end

function Service:get(actor, bookingId)
    local owner, booking, key = self:_authorize(actor, bookingId)
    if not owner then return booking end
    local state = self._states[key]
    if not state then return fail(Codes.SAFETY_SESSION_NOT_FOUND, 'safety session was not found') end
    return Result.ok(copy(state))
end

function Service:checkTimers(now)
    now = tonumber(now) or clockNow(self._clock)
    local due = {}
    if self._interval <= 0 then return Result.ok(due) end
    for key, state in pairs(self._states) do
        if state.state == 'ACTIVE' and state.checkedIn and state.lastCheckIn and now - state.lastCheckIn >= self._interval then
            due[#due + 1] = { bookingId = key, actorRef = state.actorRef, overdueSeconds = now - state.lastCheckIn }
        end
    end
    return Result.ok(due, { count = #due, serverAuthoritative = true })
end

NightShift.SafetyService = Service
NightShift.Services.Safety = Service
