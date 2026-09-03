NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Defaults = NightShift.AnalyticsCacheConfig or {}

local Cache = {}
Cache.__index = Cache

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) or value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= maximum
end

local function invalid(message, details)
    return Result.err('SUMMARY_CACHE_INVALID', message, details)
end

local function clockNow(clock, supplied)
    if supplied ~= nil then
        supplied = tonumber(supplied)
        return finite(supplied) and supplied or nil
    end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and finite(value) then return value end
    elseif type(clock) == 'function' then
        local ok, value = pcall(clock)
        value = tonumber(value)
        if ok and finite(value) then return value end
    end
    return os.time()
end

local function configured(input, name, fallback)
    return input[name] == nil and fallback or input[name]
end

function Cache.new(options)
    options = options or {}
    local config = type(options.config) == 'table' and options.config or Defaults
    if config.enabled ~= nil and type(config.enabled) ~= 'boolean' then
        return nil, invalid('summary cache enabled flag is invalid')
    end
    local maxEntries = integer(configured(config, 'maxEntries', 64), 1, 512)
    local ttlSeconds = tonumber(configured(config, 'ttlSeconds', 30))
    if not maxEntries or not finite(ttlSeconds) or ttlSeconds <= 0 or ttlSeconds > 86400 then
        return nil, invalid('summary cache bounds are invalid')
    end
    return setmetatable({
        _enabled = config.enabled ~= false,
        _maxEntries = maxEntries,
        _ttlSeconds = ttlSeconds,
        _clock = options.clock,
        _entries = {},
        _sequence = 0,
        _subscriptions = {},
        _eventBus = nil
    }, Cache)
end

function Cache:config()
    return { enabled = self._enabled, maxEntries = self._maxEntries, ttlSeconds = self._ttlSeconds }
end

function Cache:_remove(key)
    if self._entries[key] == nil then return false end
    self._entries[key] = nil
    return true
end

function Cache:_purge(now)
    local removed = 0
    for key, entry in pairs(self._entries) do
        if entry.expiresAt <= now then
            self._entries[key] = nil
            removed = removed + 1
        end
    end
    return removed
end

function Cache:_evictOldest()
    local oldestKey, oldestSequence
    for key, entry in pairs(self._entries) do
        if oldestSequence == nil or entry.sequence < oldestSequence then
            oldestKey, oldestSequence = key, entry.sequence
        end
    end
    if oldestKey ~= nil then self._entries[oldestKey] = nil end
    return oldestKey
end

function Cache:get(key, suppliedNow)
    if not text(key, 160) then return invalid('summary cache key is invalid') end
    if not self._enabled then return Result.ok({ hit = false, disabled = true }) end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('summary cache clock value is invalid') end
    self:_purge(now)
    local entry = self._entries[key]
    if not entry then return Result.ok({ hit = false }) end
    entry.lastAccessAt = now
    return Result.ok({ hit = true, value = copy(entry.value), ageSeconds = math.max(0, now - entry.createdAt) })
end

function Cache:put(key, value, suppliedNow)
    if not text(key, 160) then return invalid('summary cache key is invalid') end
    if type(value) ~= 'table' then return invalid('summary cache value must be a table') end
    if not self._enabled then return Result.ok({ stored = false, disabled = true }) end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('summary cache clock value is invalid') end
    self:_purge(now)
    if self._entries[key] == nil and next(self._entries) ~= nil then
        local count = 0
        for _ in pairs(self._entries) do count = count + 1 end
        if count >= self._maxEntries then self:_evictOldest() end
    end
    self._sequence = self._sequence + 1
    self._entries[key] = {
        value = copy(value), createdAt = now, lastAccessAt = now,
        expiresAt = now + self._ttlSeconds, sequence = self._sequence
    }
    return Result.ok({ stored = true, expiresAt = now + self._ttlSeconds })
end

function Cache:invalidate(key)
    if not text(key, 160) then return invalid('summary cache key is invalid') end
    return Result.ok({ invalidated = self:_remove(key) })
end

function Cache:invalidatePrefix(prefix)
    if not text(prefix, 96) then return invalid('summary cache prefix is invalid') end
    local removed = 0
    for key in pairs(self._entries) do
        if key:sub(1, #prefix) == prefix then
            self._entries[key] = nil
            removed = removed + 1
        end
    end
    return Result.ok({ invalidated = removed })
end

function Cache:invalidateAll()
    local removed = 0
    for key in pairs(self._entries) do
        self._entries[key] = nil
        removed = removed + 1
    end
    return Result.ok({ invalidated = removed })
end

function Cache:subscribe(eventBus, eventNames)
    if type(eventBus) ~= 'table' or type(eventBus.subscribe) ~= 'function' then
        return Result.err('SUMMARY_CACHE_UNAVAILABLE', 'summary cache event bus is unavailable')
    end
    if self._eventBus ~= nil then return Result.ok({ subscriptions = #self._subscriptions }, { idempotent = true }) end
    local names = type(eventNames) == 'table' and eventNames or {
        'booking.created', 'booking.accepted', 'booking.updated', 'booking.no_show',
        'booking.completed', 'booking.settled', 'demand.updated', 'heat.changed',
        'travel.updated'
    }
    local handles = {}
    local function rollback()
        if type(eventBus.unsubscribe) ~= 'function' then return end
        for _, handle in ipairs(handles) do
            pcall(eventBus.unsubscribe, eventBus, handle)
        end
    end
    for _, eventName in ipairs(names) do
        if not text(eventName, 128) then
            rollback()
            return invalid('summary cache event name is invalid')
        end
        local handle, subscribeError = eventBus:subscribe(eventName, function()
            self:invalidateAll()
            return true
        end)
        if not handle then
            rollback()
            return subscribeError or Result.err('SUMMARY_CACHE_UNAVAILABLE', 'summary cache event subscription failed')
        end
        handles[#handles + 1] = handle
    end
    self._eventBus, self._subscriptions = eventBus, handles
    return Result.ok({ subscriptions = #handles })
end

function Cache:status(suppliedNow)
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('summary cache clock value is invalid') end
    local expired = self:_purge(now)
    local entries = 0
    for _ in pairs(self._entries) do entries = entries + 1 end
    return Result.ok({
        enabled = self._enabled, entries = entries, maxEntries = self._maxEntries,
        ttlSeconds = self._ttlSeconds, expired = expired,
        subscriptions = #self._subscriptions
    })
end

function Cache:close()
    if self._eventBus and type(self._eventBus.unsubscribe) == 'function' then
        for _, handle in ipairs(self._subscriptions) do pcall(self._eventBus.unsubscribe, self._eventBus, handle) end
    end
    self._eventBus, self._subscriptions = nil, {}
    self:invalidateAll()
    return true
end

NightShift.SummaryCache = Cache
NightShift.Services.SummaryCache = Cache
