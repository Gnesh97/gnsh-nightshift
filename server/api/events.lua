NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Surface = {}
Surface.__index = Surface

local aliases = {
    bookingCreated = { name = 'nightshift:bookingCreated', source = 'booking.created' },
    bookingAccepted = { name = 'nightshift:bookingAccepted', source = 'booking.state_changed', state = 'ACCEPTED' },
    npcWorkerEnRoute = { name = 'nightshift:npcWorkerEnRoute', source = 'booking.state_changed', state = 'TRAVELLING' },
    bookingArrived = { name = 'nightshift:bookingArrived', source = 'booking.state_changed', state = 'ARRIVED' },
    bookingCompleted = { name = 'nightshift:bookingCompleted', source = 'booking.state_changed', state = 'COMPLETED' },
    bookingSettled = { name = 'nightshift:bookingSettled', source = 'booking.state_changed', state = 'SETTLED' },
    bookingCancelled = { name = 'nightshift:bookingCancelled', source = 'booking.state_changed', state = 'CANCELLED' },
    safetyAlert = { name = 'nightshift:safetyAlert', source = 'booking.incident_reported' },
    reputationChanged = { name = 'nightshift:reputationChanged', source = 'reputation.changed' }
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function invalid(message, details)
    return Result.err(Codes.EVENT_INVALID, message, details)
end

local function unavailable(message, details)
    return Result.err(Codes.EVENT_UNAVAILABLE, message, details)
end

local function sourcePayload(envelope)
    if type(envelope) ~= 'table' then return nil end
    return envelope.payload or envelope.data or envelope.value or envelope
end

local function mapBooking(value)
    local dto = NightShift.Api and NightShift.Api.Dto
    if type(dto) ~= 'table' or type(dto.booking) ~= 'function' then
        return nil, unavailable('public booking DTO is unavailable')
    end
    local source = type(value) == 'table' and type(value.booking) == 'table' and value.booking or value
    local mapped, mapError = dto.booking(source)
    if mapError then return nil, mapError end
    return mapped
end

function Surface.new(options)
    options = options or {}
    local eventBus = options.eventBus
    if type(eventBus) ~= 'table' or type(eventBus.subscribe) ~= 'function'
        or type(eventBus.publishCommitted) ~= 'function' then
        return nil, unavailable('domain event surface requires an event bus')
    end
    return setmetatable({
        _eventBus = eventBus,
        _subscriptions = {},
        _closed = false,
        _native = options.native ~= false
    }, Surface)
end

function Surface:list()
    local output = {}
    for key, definition in pairs(aliases) do
        output[key] = { name = definition.name, source = definition.source, state = definition.state }
    end
    return output
end

function Surface:publish(name, result, metadata)
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'domain event surface is stopped') end
    local definition = aliases[name]
    if not definition then return invalid('domain event alias is not allowlisted', { event = name }) end
    if type(result) ~= 'table' or result.ok ~= true then
        return invalid('domain events require a committed successful result', { event = name }) end
    if metadata ~= nil and type(metadata) ~= 'table' then return invalid('event metadata must be a table', { field = 'metadata' }) end
    local value = result.value
    if value == nil then value = result.data end
    if value == nil then value = result end
    local payload = copy(value)
    if name:match('^booking') or name == 'npcWorkerEnRoute' then
        local mapped, mapError = mapBooking(value)
        if not mapped then return mapError end
        payload = mapped
    end
    local eventMetadata = copy(metadata or {})
    eventMetadata.sourceEvent = eventMetadata.sourceEvent or definition.source
    local published = self._eventBus:publishCommitted(definition.name, payload, eventMetadata)
    if type(published) ~= 'table' or published.ok ~= true then
        return unavailable('domain event bus rejected the event', { event = definition.name }) end
    local nativeTriggered = false
    if self._native and type(rawget(_G, 'TriggerEvent')) == 'function' then
        local ok = pcall(TriggerEvent, definition.name, copy(payload), copy(eventMetadata))
        nativeTriggered = ok
    end
    return Result.ok({ event = definition.name, payload = payload, nativeTriggered = nativeTriggered }, {
        correlationId = published.metadata and published.metadata.correlationId,
        occurredAt = published.metadata and published.metadata.occurredAt
    })
end

function Surface:_handleState(envelope)
    local payload = sourcePayload(envelope)
    if type(payload) ~= 'table' then return invalid('booking event payload is invalid') end
    local state = tostring(payload.newState or payload.status or ''):upper()
    local alias
    for key, definition in pairs(aliases) do
        if definition.source == 'booking.state_changed' and definition.state == state then alias = key; break end
    end
    if not alias then return Result.ok({ ignored = true, state = state }) end
    local result = Result.ok(payload)
    local metadata = copy(type(envelope.metadata) == 'table' and envelope.metadata or {})
    metadata.sourceEvent = envelope.eventName or envelope.name or 'booking.state_changed'
    metadata.eventKey = payload.eventKey
    metadata.oldState = payload.oldState
    metadata.newState = state
    return self:publish(alias, result, metadata)
end

function Surface:_handleCreated(envelope)
    local payload = sourcePayload(envelope)
    if type(payload) ~= 'table' then return invalid('booking created payload is invalid') end
    return self:publish('bookingCreated', Result.ok(payload), {
        sourceEvent = envelope.eventName or envelope.name or 'booking.created',
        correlationId = envelope.correlationId
    })
end

function Surface:_handleSafety(envelope)
    local payload = sourcePayload(envelope)
    if type(payload) ~= 'table' then return invalid('safety event payload is invalid') end
    return self:publish('safetyAlert', Result.ok(payload), {
        sourceEvent = envelope.eventName or envelope.name or 'booking.incident_reported',
        correlationId = envelope.correlationId
    })
end

function Surface:_handleReputation(envelope)
    local payload = sourcePayload(envelope)
    if type(payload) ~= 'table' then return invalid('reputation event payload is invalid') end
    return self:publish('reputationChanged', Result.ok(payload), {
        sourceEvent = envelope.eventName or envelope.name or 'reputation.changed',
        correlationId = envelope.correlationId
    })
end

function Surface:attach()
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'domain event surface is stopped') end
    if #self._subscriptions > 0 then return Result.ok({ attached = true, subscriptions = #self._subscriptions }) end
    local function subscribe(eventName, handler)
        local handle, subscribeError = self._eventBus:subscribe(eventName, handler)
        if not handle then return nil, subscribeError end
        self._subscriptions[#self._subscriptions + 1] = handle
        return handle
    end
    local handle, subscribeError = subscribe('booking.state_changed', function(envelope)
        return self:_handleState(envelope)
    end)
    if not handle then return subscribeError end
    handle, subscribeError = subscribe('booking.created', function(envelope)
        return self:_handleCreated(envelope)
    end)
    if not handle then return subscribeError end
    handle, subscribeError = subscribe('booking.incident_reported', function(envelope)
        return self:_handleSafety(envelope)
    end)
    if not handle then return subscribeError end
    handle, subscribeError = subscribe('reputation.changed', function(envelope)
        return self:_handleReputation(envelope)
    end)
    if not handle then return subscribeError end
    return Result.ok({ attached = true, subscriptions = #self._subscriptions })
end

function Surface:close()
    if self._closed then return true end
    for _, handle in ipairs(self._subscriptions) do
        pcall(self._eventBus.unsubscribe, self._eventBus, handle)
    end
    self._subscriptions = {}
    self._closed = true
    return true
end

NightShift.Api = NightShift.Api or {}
NightShift.DomainEvents = Surface
NightShift.Api.DomainEvents = Surface
