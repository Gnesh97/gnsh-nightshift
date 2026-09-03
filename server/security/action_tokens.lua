NightShift = NightShift or {}
NightShift.Security = NightShift.Security or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Store = {}
Store.__index = Store

local sequence = 0

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

local function text(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= (maximum or 160)
        and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function nonceValue(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= (maximum or 160)
        and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
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
    return Result.err(Codes.ACTION_TOKEN_INVALID, message, details)
end

local function bookingKey(value)
    if type(value) == 'table' then value = value.id or value.bookingId end
    if integer(value, 1) then return tostring(math.floor(tonumber(value))) end
    if text(value, 160) then return tostring(value) end
    return nil
end

local function actionKey(value)
    return text(value, 96) and value or nil
end

local function actorKey(value)
    if type(value) == 'table' then
        local source = integer(value.source or value.playerSource, 0, 65535)
        if source ~= nil then return 'SOURCE:' .. tostring(source) end
        local reference = value.ref or value.identityKey or value.actorRef or value.id
        if not text(reference, 160) then return nil end
        local kind = value.type or value.actorType or 'PLAYER'
        if type(kind) ~= 'string' or not kind:match('^[A-Za-z][A-Za-z0-9_%-]*$') then return nil end
        return tostring(kind):upper() .. ':' .. tostring(reference)
    end
    local source = integer(value, 0, 65535)
    if source ~= nil then return 'SOURCE:' .. tostring(source) end
    if text(value, 160) then return 'REF:' .. tostring(value) end
    return nil
end

local function defaultNonce()
    sequence = sequence + 1
    local first = math.random(0, 2147483647)
    local second = math.random(0, 2147483647)
    local marker = tostring({}):gsub('[^A-Za-z0-9]', '')
    return string.format('%08x%08x%08x%s', first, second, sequence, marker)
end

local function configured(options)
    local root = options.config or NightShift.SecurityConfig or {}
    if type(root) ~= 'table' then return nil, 'security configuration must be a table' end
    local tokenConfig = root.actionTokens or root
    if type(tokenConfig) ~= 'table' then return nil, 'action token configuration must be a table' end
    local enabled = root.enabled
    if enabled == nil then enabled = true end
    local tokenEnabled = tokenConfig.enabled
    if tokenEnabled == nil then tokenEnabled = true end
    local enforce = tokenConfig.enforce
    if enforce == nil then enforce = true end
    local developmentOptOut = tokenConfig.developmentOptOut == true
    if type(enabled) ~= 'boolean' or type(tokenEnabled) ~= 'boolean' or type(enforce) ~= 'boolean'
        or (tokenConfig.developmentOptOut ~= nil and type(tokenConfig.developmentOptOut) ~= 'boolean') then
        return nil, 'action token enabled flags must be boolean'
    end
    if options.environment == 'development' and developmentOptOut then enforce = false end
    local ttl = integer(tokenConfig.ttlSeconds or 90, 1, 3600)
    local maxActive = integer(tokenConfig.maxActive or 4096, 1, 100000)
    local maxTokenLength = integer(tokenConfig.maxTokenLength or 192, 64, 512)
    if not ttl or not maxActive or not maxTokenLength then return nil, 'action token settings are invalid' end
    return { enabled = enabled and tokenEnabled, enforce = enforce, ttlSeconds = ttl,
        maxActive = maxActive, maxTokenLength = maxTokenLength,
        developmentOptOut = developmentOptOut }
end

function Store.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('action token options must be a table') end
    local config, configError = configured(options)
    if not config then return nil, invalid(configError) end
    local nonceFactory = options.nonceFactory or defaultNonce
    if type(nonceFactory) ~= 'function' then return nil, invalid('action token nonce factory is invalid') end
    return setmetatable({
        _config = config, _clock = options.clock, _nonceFactory = nonceFactory,
        _audit = options.audit or options.auditService, _records = {}, _active = 0
    }, Store)
end

function Store:config()
    return copy(self._config)
end

function Store:requires()
    return self._config.enabled == true and self._config.enforce == true
end

function Store:_record(event)
    if type(self._audit) ~= 'table' or type(self._audit.record) ~= 'function' then return end
    pcall(self._audit.record, self._audit, {
        actor = { actorType = 'SYSTEM', ref = 'nightshift:action-token' },
        action = 'security.action_token.' .. tostring(event.reason or 'event'),
        target = { type = 'ACTION_TOKEN', ref = tostring(event.token or 'redacted') },
        result = event.result, reason = event.reason
    })
end

function Store:_purge(now)
    local removed = 0
    for token, record in pairs(self._records) do
        if now >= record.expiresAt then
            self._records[token] = nil
            self._active = math.max(0, self._active - 1)
            removed = removed + 1
        end
    end
    return removed
end

function Store:purge(suppliedNow)
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('action token clock returned an invalid timestamp') end
    return Result.ok({ removed = self:_purge(now), active = self._active })
end

function Store:_newToken()
    for attempt = 1, 8 do
        local ok, nonce = pcall(self._nonceFactory)
        if not ok or not nonceValue(nonce, self._config.maxTokenLength - 4) then return nil end
        local token = 'nst_' .. tostring(nonce)
        if not self._records[token] then return token end
        sequence = sequence + 1
        token = token .. '_' .. tostring(sequence + attempt)
        if #token <= self._config.maxTokenLength and not self._records[token] then return token end
    end
    return nil
end

function Store:issue(actor, bookingId, action, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('action token issue options must be a table') end
    if self._config.enabled ~= true then return Result.err(Codes.ACTION_TOKEN_UNAVAILABLE, 'action token service is disabled') end
    local actorReference, normalizedBooking, normalizedAction = actorKey(actor), bookingKey(bookingId), actionKey(action)
    if not actorReference or not normalizedBooking or not normalizedAction then
        return invalid('action token binding is invalid')
    end
    local now = nowValue(self._clock, options.now)
    if not now then return invalid('action token clock returned an invalid timestamp') end
    self:_purge(now)
    if self._active >= self._config.maxActive then
        return Result.err(Codes.ACTION_TOKEN_UNAVAILABLE, 'action token capacity is exhausted')
    end
    local ttl = options.ttlSeconds == nil and self._config.ttlSeconds or integer(options.ttlSeconds, 1, 3600)
    if not ttl then return invalid('action token TTL is invalid') end
    local token = self:_newToken()
    if not token then return Result.err(Codes.ACTION_TOKEN_UNAVAILABLE, 'action token nonce generation failed') end
    local generation = options.generation
    if generation ~= nil and not nonceValue(tostring(generation), 240) then
        return invalid('action token generation binding is invalid')
    end
    self._records[token] = {
        actor = actorReference, bookingId = normalizedBooking, action = normalizedAction,
        generation = generation and tostring(generation) or nil,
        issuedAt = now, expiresAt = now + ttl, used = false
    }
    self._active = self._active + 1
    return Result.ok({
        token = token, bookingId = normalizedBooking, action = normalizedAction, expiresAt = now + ttl
    }, { ttlSeconds = ttl, oneTime = true })
end

function Store:verify(token, actor, bookingId, action, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('action token verify options must be a table') end
    if self._config.enabled ~= true then return Result.err(Codes.ACTION_TOKEN_UNAVAILABLE, 'action token service is disabled') end
    if not text(token, self._config.maxTokenLength) then return invalid('action token is malformed') end
    local actorReference, normalizedBooking, normalizedAction = actorKey(actor), bookingKey(bookingId), actionKey(action)
    if not actorReference or not normalizedBooking or not normalizedAction then return invalid('action token binding is invalid') end
    local record = self._records[token]
    if not record then return invalid('action token is unknown') end
    local now = nowValue(self._clock, options.now)
    if not now then return invalid('action token clock returned an invalid timestamp') end
    if now >= record.expiresAt then
        self._records[token] = nil
        self._active = math.max(0, self._active - 1)
        self:_record({ token = token, reason = 'expired', result = Result.err(Codes.ACTION_TOKEN_EXPIRED, 'action token has expired') })
        return Result.err(Codes.ACTION_TOKEN_EXPIRED, 'action token has expired')
    end
    if record.used then
        self:_record({ token = token, reason = 'replay', result = Result.err(Codes.ACTION_TOKEN_REPLAY, 'action token has already been consumed') })
        return Result.err(Codes.ACTION_TOKEN_REPLAY, 'action token has already been consumed')
    end
    if record.actor ~= actorReference then return Result.err(Codes.ACTION_TOKEN_ACTOR_MISMATCH, 'action token actor does not match') end
    if record.bookingId ~= normalizedBooking then return Result.err(Codes.ACTION_TOKEN_BOOKING_MISMATCH, 'action token booking does not match') end
    if record.action ~= normalizedAction then return Result.err(Codes.ACTION_TOKEN_ACTION_MISMATCH, 'action token action does not match') end
    if record.generation ~= nil and tostring(options.generation or '') ~= record.generation then
        return Result.err(Codes.ACTION_TOKEN_ACTION_MISMATCH, 'action token generation does not match')
    end
    return Result.ok({
        bookingId = record.bookingId, action = record.action, issuedAt = record.issuedAt, expiresAt = record.expiresAt
    }, { verified = true, oneTime = true })
end

function Store:authorize(actor, bookingId, action, token, options)
    if not self:requires() then return Result.ok({ bypassed = true }, { developmentOptOut = self._config.developmentOptOut == true }) end
    if not text(token, self._config.maxTokenLength) then
        return Result.err(Codes.ACTION_TOKEN_INVALID, 'action token is required')
    end
    return self:consume(token, actor, bookingId, action, options)
end

function Store:consume(token, actor, bookingId, action, options)
    local verified = self:verify(token, actor, bookingId, action, options)
    if type(verified) ~= 'table' or verified.ok ~= true then return verified end
    local record = self._records[token]
    if not record then return Result.err(Codes.ACTION_TOKEN_REPLAY, 'action token has already been consumed') end
    record.used = true
    record.usedAt = nowValue(self._clock, type(options) == 'table' and options.now or nil)
    self:_record({ token = token, reason = 'consumed', result = Result.ok({ bookingId = record.bookingId, action = record.action }) })
    return Result.ok({
        bookingId = record.bookingId, action = record.action, consumedAt = record.usedAt
    }, { consumed = true, oneTime = true })
end

function Store:revoke(token)
    if not text(token, self._config.maxTokenLength) then return invalid('action token is malformed') end
    local removed = self._records[token] and 1 or 0
    if removed == 1 then self._records[token] = nil; self._active = math.max(0, self._active - 1) end
    return Result.ok({ removed = removed }, { idempotent = removed == 0 })
end

function Store:revokeActor(actor)
    local reference = actorKey(actor)
    if not reference then return invalid('action token actor is invalid') end
    local removed = 0
    for token, record in pairs(self._records) do
        if record.actor == reference then self._records[token] = nil; removed = removed + 1 end
    end
    self._active = math.max(0, self._active - removed)
    return Result.ok({ actor = reference, removed = removed }, { idempotent = removed == 0 })
end

function Store:status()
    local used = 0
    for _, record in pairs(self._records) do if record.used then used = used + 1 end end
    return Result.ok({ enabled = self._config.enabled, enforce = self._config.enforce, active = self._active, consumed = used, maxActive = self._config.maxActive })
end

NightShift.ActionTokenStore = Store
NightShift.Security.ActionTokenStore = Store
