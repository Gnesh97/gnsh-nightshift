NightShift = NightShift or {}

local Result = NightShift.Result
local Clock = NightShift.Clock
local Logger = NightShift.Logger

local Bus = {}
Bus.__index = Bus

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do
        output[copy(key, seen)] = copy(item, seen)
    end
    return output
end

local function validName(name)
    return type(name) == 'string' and name:match('%S') ~= nil and #name <= 128
end

local function normalizeCorrelation(value, fallback)
    local candidate = type(value) == 'string' and value or fallback
    candidate = type(candidate) == 'string' and candidate or 'unknown'
    candidate = candidate:gsub('[^%w%._%-:]', ''):sub(1, 96)
    return candidate ~= '' and candidate or 'unknown'
end

local function invalid(message, path)
    return Result.err('INVALID_EVENT', message, { path = path })
end

function Bus.new(options)
    options = options or {}
    local clock = options.clock or Clock.new()
    local logger = options.logger or Logger.new({ clock = clock })
    return setmetatable({
        _clock = clock,
        _logger = logger,
        _subscriptions = {},
        _nextHandle = 0,
        _closed = false
    }, Bus)
end

function Bus:subscribe(eventName, handler)
    if self._closed then return nil, Result.err('LIFECYCLE_STOPPED', 'Event bus is stopped') end
    if not validName(eventName) then return nil, invalid('event name must be a non-empty string', 'eventName') end
    if type(handler) ~= 'function' then return nil, invalid('event handler must be a function', 'handler') end
    self._nextHandle = self._nextHandle + 1
    local handle = ('subscription-%d'):format(self._nextHandle)
    local listeners = self._subscriptions[eventName] or {}
    listeners[#listeners + 1] = { handle = handle, handler = handler }
    self._subscriptions[eventName] = listeners
    return handle
end

function Bus:unsubscribe(handle)
    if type(handle) ~= 'string' then return false end
    for eventName, listeners in pairs(self._subscriptions) do
        for index, subscription in ipairs(listeners) do
            if subscription.handle == handle then
                table.remove(listeners, index)
                if #listeners == 0 then self._subscriptions[eventName] = nil end
                return true
            end
        end
    end
    return false
end

local function failureCode(value)
    if type(value) == 'table' and value.error and value.error.code then return value.error.code end
    if type(value) == 'table' and value.code then return value.code end
    return 'HANDLER_FAILED'
end

function Bus:publishCommitted(eventName, payload, metadata)
    if self._closed then return Result.err('LIFECYCLE_STOPPED', 'Event bus is stopped') end
    if not validName(eventName) then return invalid('event name must be a non-empty string', 'eventName') end
    if metadata ~= nil and type(metadata) ~= 'table' then
        return invalid('event metadata must be a table', 'metadata')
    end

    metadata = metadata or {}
    local correlationId = normalizeCorrelation(metadata.correlationId, self._logger.correlationId)
    local timestamp = self._clock:timestamp()
    local envelope = {
        name = eventName,
        eventName = eventName,
        payload = copy(payload),
        metadata = copy(metadata),
        correlationId = correlationId,
        occurredAt = timestamp,
        committed = true
    }

    local delivered, failed, failures = 0, 0, {}
    local listeners = {}
    for index, subscription in ipairs(self._subscriptions[eventName] or {}) do
        listeners[index] = subscription
    end
    for _, subscription in ipairs(listeners) do
        local ok, handlerResult = pcall(subscription.handler, copy(envelope))
        local handlerFailed = not ok or handlerResult == false or (type(handlerResult) == 'table' and handlerResult.ok == false)
        if handlerFailed then
            failed = failed + 1
            failures[#failures + 1] = {
                handle = subscription.handle,
                code = failureCode(ok and handlerResult or nil)
            }
            pcall(function()
                self._logger:withCorrelation(correlationId):error('event_bus', 'Committed event handler failed', {
                    eventName = eventName,
                    subscription = subscription.handle,
                    code = failures[#failures].code
                })
            end)
        else
            delivered = delivered + 1
        end
    end

    return Result.ok({ delivered = delivered, failed = failed, failures = failures }, {
        correlationId = correlationId,
        occurredAt = timestamp
    })
end

function Bus:close()
    self._subscriptions = {}
    self._closed = true
    return true
end

NightShift.EventBus = Bus
