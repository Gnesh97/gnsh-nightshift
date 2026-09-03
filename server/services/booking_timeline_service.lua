NightShift = NightShift or {}

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

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function invalid(message, details)
    return Result.err(Codes.BOOKING_TIMELINE_FAILED, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and text(value, 64) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.eventRepository
    if type(repository) ~= 'table' or type(repository.create) ~= 'function' or type(repository.findByKey) ~= 'function' or type(repository.findByBooking) ~= 'function' then
        return nil, invalid('booking timeline service requires an event repository')
    end
    return setmetatable({ _repository = repository, _clock = options.clock }, Service)
end

function Service:record(booking, oldState, newState, metadata)
    if type(booking) ~= 'table' or booking.id == nil then return invalid('timeline booking ID is required') end
    if not text(oldState, 32) or not text(newState, 32) then return invalid('timeline state values are required') end
    metadata = metadata or {}
    if type(metadata) ~= 'table' then return invalid('timeline metadata must be a table') end
    local eventKey = metadata.eventKey
    if eventKey == nil then
        eventKey = ('state:%s:%s:%s'):format(tostring(booking.id), oldState:upper(), newState:upper())
    end
    if not text(eventKey, 128) then return invalid('timeline event key is invalid') end
    local existing = self._repository:findByKey(booking.id, eventKey)
    if type(existing) ~= 'table' then return invalid('timeline lookup returned an invalid result') end
    if existing.ok then return Result.ok(existing.value, { idempotent = true, eventKey = eventKey }) end
    if not notFound(existing) then return existing end

    local event = {
        bookingId = booking.id,
        eventKey = eventKey,
        eventType = metadata.eventType or 'STATE_CHANGED',
        oldState = oldState:upper(),
        newState = newState:upper(),
        actorType = metadata.actorType,
        actorRef = metadata.actorRef,
        reason = metadata.reason,
        correlationId = metadata.correlationId or booking.correlationId,
        metadata = copy(metadata),
        occurredAt = timestamp(self._clock)
    }
    local created = self._repository:create(event)
    if type(created) ~= 'table' then return invalid('timeline create returned an invalid result') end
    if not created.ok then
        local raced = self._repository:findByKey(booking.id, eventKey)
        if type(raced) == 'table' and raced.ok then return Result.ok(raced.value, { idempotent = true, eventKey = eventKey }) end
        return Result.err(Codes.BOOKING_TIMELINE_FAILED, 'booking timeline event could not be persisted', { cause = created.error and created.error.code })
    end
    return Result.ok(created.value, { eventKey = eventKey, occurredAt = event.occurredAt })
end

function Service:history(bookingId, options)
    local result = self._repository:findByBooking(bookingId, options)
    if type(result) ~= 'table' then return invalid('timeline history returned an invalid result') end
    return result
end

function Service:reconstruct(bookingId, initialState, options)
    local history = self:history(bookingId, options)
    if not history.ok then return history end
    local state = type(initialState) == 'string' and initialState:upper() or 'DRAFT'
    local events = history.value or {}
    for _, event in ipairs(events) do
        if type(event.newState) == 'string' then state = event.newState:upper() end
    end
    return Result.ok({ status = state, events = copy(events) }, { bookingId = bookingId })
end

Service.append = Service.record
NightShift.BookingTimelineService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.BookingTimeline = Service
