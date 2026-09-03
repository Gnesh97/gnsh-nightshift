NightShift = NightShift or {}
NightShift.Security = NightShift.Security or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Limiter = {}
Limiter.__index = Limiter

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
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return math.floor(value)
end

local function sourceValue(value)
    return integer(value, 0, 65535)
end

local function actionValue(value)
    return type(value) == 'string' and #value > 0 and #value <= 64
        and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil and value or nil
end

local function nowValue(clock, supplied)
    if supplied ~= nil then
        supplied = tonumber(supplied)
        if finite(supplied) and supplied >= 0 then return supplied end
        return nil
    end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and finite(value) and value >= 0 then return value end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.RATE_LIMIT_INVALID, message, details)
end

local function normalizeRule(value, fallback)
    value = type(value) == 'table' and value or {}
    fallback = type(fallback) == 'table' and fallback or {}
    local capacity = value.capacity == nil and (fallback.capacity or 20) or tonumber(value.capacity)
    local refill = value.refillPerSecond == nil and (fallback.refillPerSecond or 2) or tonumber(value.refillPerSecond)
    local cost = value.cost == nil and (fallback.cost or 1) or tonumber(value.cost)
    if not finite(capacity) or capacity < 1 or capacity > 10000 or capacity ~= math.floor(capacity)
        or not finite(refill) or refill <= 0 or refill > 1000
        or not finite(cost) or cost <= 0 or cost > capacity then
        return nil
    end
    return { capacity = math.floor(capacity), refillPerSecond = refill, cost = cost }
end

local function configured(options)
    local root = options.config or NightShift.SecurityConfig or {}
    if type(root) ~= 'table' then return nil, 'security configuration must be a table' end
    local rate = root.rateLimit or root
    if type(rate) ~= 'table' then return nil, 'rate limit configuration must be a table' end
    local enabled = root.enabled
    if enabled == nil then enabled = true end
    local rateEnabled = rate.enabled
    if rateEnabled == nil then rateEnabled = true end
    if type(enabled) ~= 'boolean' or type(rateEnabled) ~= 'boolean' then return nil, 'rate limit enabled flags must be boolean' end
    local defaultRule = normalizeRule(rate.default, { capacity = 20, refillPerSecond = 2, cost = 1 })
    if not defaultRule then return nil, 'default rate rule is invalid' end
    local actions = rate.actions == nil and {} or rate.actions
    if type(actions) ~= 'table' then return nil, 'rate action rules must be a table' end
    local normalizedActions, count = {}, 0
    for action, rule in pairs(actions) do
        count = count + 1
        if count > 128 or not actionValue(action) then return nil, 'rate action name is invalid' end
        local normalized = normalizeRule(rule, defaultRule)
        if not normalized then return nil, 'rate action rule is invalid' end
        normalizedActions[action] = normalized
    end
    local maxBuckets = root.maxBuckets
    if maxBuckets == nil then maxBuckets = 2048 end
    maxBuckets = integer(maxBuckets, 1, 100000)
    if not maxBuckets then return nil, 'rate bucket limit is invalid' end
    return {
        enabled = enabled and rateEnabled,
        maxBuckets = maxBuckets,
        default = defaultRule,
        actions = normalizedActions
    }
end

function Limiter.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('rate limiter options must be a table') end
    local config, configError = configured(options)
    if not config then return nil, invalid(configError) end
    return setmetatable({
        _config = config,
        _clock = options.clock,
        _buckets = {},
        _bucketCount = 0,
        _sequence = 0
    }, Limiter)
end

function Limiter:config()
    return copy(self._config)
end

function Limiter:_rule(action)
    return self._config.actions[action] or self._config.default
end

function Limiter:rule(action)
    action = actionValue(action)
    if not action then return invalid('rate limit action is invalid') end
    return Result.ok(copy(self:_rule(action)))
end

function Limiter:_evictOne()
    if self._bucketCount < self._config.maxBuckets then return true end
    local oldestKey, oldestSequence
    for key, bucket in pairs(self._buckets) do
        if oldestSequence == nil or bucket.sequence < oldestSequence then
            oldestKey, oldestSequence = key, bucket.sequence
        end
    end
    if oldestKey == nil then return false end
    self._buckets[oldestKey] = nil
    self._bucketCount = self._bucketCount - 1
    return true
end

function Limiter:_getBucket(source, action, rule, now)
    local key = tostring(source) .. ':' .. action
    local bucket = self._buckets[key]
    if bucket == nil then
        if not self:_evictOne() then return nil end
        bucket = { tokens = rule.capacity, lastAt = now, sequence = 0, accepted = 0, rejected = 0 }
        self._buckets[key] = bucket
        self._bucketCount = self._bucketCount + 1
    else
        local elapsed = math.max(0, now - bucket.lastAt)
        bucket.tokens = math.min(rule.capacity, bucket.tokens + elapsed * rule.refillPerSecond)
        bucket.lastAt = now
    end
    self._sequence = self._sequence + 1
    bucket.sequence = self._sequence
    return bucket
end

function Limiter:allow(source, action, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('rate limit options must be a table') end
    source = sourceValue(source)
    action = actionValue(action)
    if source == nil then return invalid('rate limit source is invalid') end
    if action == nil then return invalid('rate limit action is invalid') end
    if self._config.enabled ~= true then
        return Result.ok({ allowed = true, source = source, action = action, disabled = true }, { disabled = true })
    end
    local now = nowValue(self._clock, options.now)
    if not now then return invalid('rate limiter clock returned an invalid timestamp') end
    local rule = self:_rule(action)
    local cost = options.cost == nil and rule.cost or tonumber(options.cost)
    if not finite(cost) or cost <= 0 or cost > rule.capacity then
        return invalid('rate limit cost is invalid')
    end
    local bucket = self:_getBucket(source, action, rule, now)
    if not bucket then return Result.err(Codes.RATE_LIMIT_UNAVAILABLE, 'rate limit bucket capacity is exhausted') end
    if bucket.tokens + 1e-9 >= cost then
        bucket.tokens = bucket.tokens - cost
        bucket.accepted = bucket.accepted + 1
        return Result.ok({
            allowed = true, source = source, action = action,
            remaining = math.max(0, bucket.tokens), limit = rule.capacity, retryAfter = 0
        }, { rateLimited = false })
    end
    bucket.rejected = bucket.rejected + 1
    local retryAfter = math.max(1, math.ceil((cost - bucket.tokens) / rule.refillPerSecond))
    return Result.err(Codes.RATE_LIMITED, 'rate limit exceeded', {
        source = source, action = action, remaining = math.max(0, bucket.tokens),
        limit = rule.capacity, retryAfter = retryAfter
    }, { retryAfter = retryAfter, rateLimited = true })
end

function Limiter:reset(source, action)
    source = sourceValue(source)
    if source == nil then return invalid('rate limit source is invalid') end
    if action ~= nil then
        action = actionValue(action)
        if not action then return invalid('rate limit action is invalid') end
        local key = tostring(source) .. ':' .. action
        local removed = self._buckets[key] and 1 or 0
        if removed == 1 then self._buckets[key] = nil; self._bucketCount = self._bucketCount - 1 end
        return Result.ok({ source = source, action = action, removed = removed }, { idempotent = removed == 0 })
    end
    local prefix, removed = tostring(source) .. ':', 0
    for key in pairs(self._buckets) do
        if key:sub(1, #prefix) == prefix then self._buckets[key] = nil; removed = removed + 1 end
    end
    self._bucketCount = math.max(0, self._bucketCount - removed)
    return Result.ok({ source = source, removed = removed }, { idempotent = removed == 0 })
end

function Limiter:purge(suppliedNow, maxIdleSeconds)
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('rate limiter clock returned an invalid timestamp') end
    local idle = tonumber(maxIdleSeconds) or 3600
    if not finite(idle) or idle < 1 or idle > 86400 then return invalid('rate limiter idle window is invalid') end
    local removed = 0
    for key, bucket in pairs(self._buckets) do
        if now - bucket.lastAt >= idle then self._buckets[key] = nil; removed = removed + 1 end
    end
    self._bucketCount = math.max(0, self._bucketCount - removed)
    return Result.ok({ removed = removed, buckets = self._bucketCount })
end

function Limiter:status()
    return Result.ok({ enabled = self._config.enabled, buckets = self._bucketCount, maxBuckets = self._config.maxBuckets })
end

NightShift.RateLimiter = Limiter
NightShift.Security.RateLimiter = Limiter
