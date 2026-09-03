local function check(value, message) assert(value, message) end

do
    local config = NightShift.Validators.copy(NightShift.DefaultConfig)
    check(config.security and config.security.rateLimit and config.security.actionTokens,
        'security defaults must be present')
    local normalized, err = NightShift.Validators.validateConfig(config)
    check(normalized and normalized.security and not err, 'security config should normalize')
    config.security.rateLimit.default.capacity = 0
    normalized, err = NightShift.Validators.validateConfig(config)
    check(not normalized and err and err.code == 'INVALID_CONFIG', 'invalid rate rule must fail closed')
end

do
    local now = 100
    local limiter, limiterError = NightShift.RateLimiter.new({
        clock = { now = function() return now end },
        config = {
            enabled = true, maxBuckets = 4,
            rateLimit = {
                enabled = true,
                default = { capacity = 2, refillPerSecond = 1, cost = 1 },
                actions = { critical = { capacity = 1, refillPerSecond = 0.5, cost = 1 } }
            }
        }
    })
    check(limiter and not limiterError, 'rate limiter must initialize')
    check(limiter:allow(1, 'normal').ok and limiter:allow(1, 'normal').ok,
        'burst should allow up to capacity')
    local limited = limiter:allow(1, 'normal')
    check(not limited.ok and limited.error.code == NightShift.Errors.Codes.RATE_LIMITED,
        'third burst must be rejected with stable code')
    check(limiter:allow(2, 'normal').ok, 'rate limit buckets must be source scoped')
    check(limiter:allow(1, 'critical').ok, 'action buckets must be independently scoped')
    check(not limiter:allow(1, 'critical').ok, 'critical action burst must be bounded')
    now = 102
    check(limiter:allow(1, 'normal').ok and limiter:allow(1, 'critical').ok,
        'clock refill must restore capacity deterministically')
    local reset = limiter:reset(1, 'normal')
    check(reset.ok and reset.value.removed == 1, 'action reset must remove one bucket')
    check(not limiter:allow(0, 'normal').ok == false, 'console source remains a valid bucket')
    local invalid = limiter:allow('bad', 'normal')
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.RATE_LIMIT_INVALID,
        'invalid source must fail closed')
end

do
    local now = 200
    local nonce = 0
    local tokens, tokenError = NightShift.ActionTokenStore.new({
        clock = { now = function() return now end },
        nonceFactory = function()
            nonce = nonce + 1
            return 'testnonce' .. tostring(nonce)
        end,
        config = {
            enabled = true,
            actionTokens = { enabled = true, enforce = true, ttlSeconds = 10, maxActive = 8, maxTokenLength = 192 }
        }
    })
    check(tokens and not tokenError, 'action token store must initialize')
    local issued = tokens:issue(12, 42, 'session-complete')
    check(issued.ok and type(issued.value.token) == 'string', 'token issue must return opaque token')
    local token = issued.value.token
    local wrongActor = tokens:verify(token, 13, 42, 'session-complete')
    check(not wrongActor.ok and wrongActor.error.code == NightShift.Errors.Codes.ACTION_TOKEN_ACTOR_MISMATCH,
        'wrong actor must fail')
    local wrongBooking = tokens:verify(token, 12, 43, 'session-complete')
    check(not wrongBooking.ok and wrongBooking.error.code == NightShift.Errors.Codes.ACTION_TOKEN_BOOKING_MISMATCH,
        'wrong booking must fail')
    local wrongAction = tokens:verify(token, 12, 42, 'session-start')
    check(not wrongAction.ok and wrongAction.error.code == NightShift.Errors.Codes.ACTION_TOKEN_ACTION_MISMATCH,
        'wrong action must fail')
    local consumed = tokens:consume(token, 12, 42, 'session-complete')
    check(consumed.ok and consumed.value.bookingId == '42', 'valid token must consume once')
    local replay = tokens:consume(token, 12, 42, 'session-complete')
    check(not replay.ok and replay.error.code == NightShift.Errors.Codes.ACTION_TOKEN_REPLAY,
        'consumed token replay must fail')
    local expiring = tokens:issue({ source = 12 }, 43, 'session-start')
    check(expiring.ok, 'second token must issue')
    now = 211
    local expired = tokens:consume(expiring.value.token, 12, 43, 'session-start')
    check(not expired.ok and expired.error.code == NightShift.Errors.Codes.ACTION_TOKEN_EXPIRED,
        'expired token must fail deterministically')
    local invalid = tokens:consume('not-a-token', 12, 43, 'session-start')
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.ACTION_TOKEN_INVALID,
        'malformed token must fail closed')
end

do
    local defaultStore = NightShift.ActionTokenStore.new({
        clock = { now = function() return 500 end },
        config = NightShift.SecurityConfig
    })
    local generated = defaultStore:issue(1, 99, 'session-start')
    check(generated.ok and #generated.value.token <= NightShift.SecurityConfig.actionTokens.maxTokenLength,
        'default nonce generator must produce a bounded token')
end

do
    local now = 300
    local tokens = NightShift.ActionTokenStore.new({
        clock = { now = function() return now end }, nonceFactory = function() return 'generation' end,
        config = { enabled = true, actionTokens = { enabled = true, enforce = true, ttlSeconds = 30 } }
    })
    local issued = tokens:issue(12, 77, 'client-mode:arrival', { generation = 'gen:1' })
    check(issued.ok, 'generation-bound token must issue')
    local wrongGeneration = tokens:authorize(12, 77, 'client-mode:arrival', issued.value.token, { generation = 'gen:2' })
    check(not wrongGeneration.ok and wrongGeneration.error.code == NightShift.Errors.Codes.ACTION_TOKEN_ACTION_MISMATCH,
        'generation mismatch must fail closed')
    local missing = tokens:authorize(12, 77, 'client-mode:arrival', nil)
    check(not missing.ok and missing.error.code == NightShift.Errors.Codes.ACTION_TOKEN_INVALID,
        'critical action without token must fail closed')
    local accepted = tokens:authorize(12, 77, 'client-mode:arrival', issued.value.token, { generation = 'gen:1' })
    check(accepted.ok and accepted.value.consumedAt ~= nil, 'valid critical token must be consumed')
end

do
    local development = NightShift.ActionTokenStore.new({
        environment = 'development', config = { enabled = true,
            actionTokens = { enabled = true, enforce = true, developmentOptOut = true } }
    })
    check(development and not development:requires(), 'development opt-out must be explicit and observable')
    local production = NightShift.ActionTokenStore.new({
        environment = 'production', config = { enabled = true,
            actionTokens = { enabled = true, enforce = true, developmentOptOut = true } }
    })
    check(production and production:requires(), 'production must ignore development opt-out')
end

do
    -- Exercise the real NUI request boundary with a minimal server surface.
    -- A browser-provided generation must match the server-owned NPC registry
    -- before a replacement arrival token can be issued.
    local oldRegister, oldAddHandler, oldTrigger, oldSource = rawget(_G, 'RegisterNetEvent'),
        rawget(_G, 'AddEventHandler'), rawget(_G, 'TriggerClientEvent'), rawget(_G, 'source')
    local listeners, responses, nonce = {}, {}, 0
    _G.RegisterNetEvent = function() end
    _G.AddEventHandler = function(name, handler) listeners[name] = handler end
    _G.TriggerClientEvent = function(_, playerSource, requestId, result)
        responses[#responses + 1] = { source = playerSource, id = requestId, result = result }
    end
    _G.source = 12
    local tokens = NightShift.ActionTokenStore.new({
        clock = { now = function() return 700 end },
        nonceFactory = function() nonce = nonce + 1; return 'nui' .. tostring(nonce) end,
        config = { enabled = true, actionTokens = { enabled = true, enforce = true, ttlSeconds = 30 } }
    })
    local bookingStatus = 'TRAVELLING'
    local services = {
        actionTokens = tokens,
        identity = { resolve = function() return NightShift.Result.ok({ identityKey = 'client:1' }) end },
        booking = { get = function(_, bookingId)
            return NightShift.Result.ok({ id = tonumber(bookingId), bookingId = tostring(bookingId),
                clientRef = 'client:1', status = bookingStatus })
        end },
        clientMode = {
            travel = function()
                return NightShift.Result.err('TRANSIENT_FAILURE', 'test service failure')
            end
        },
        npcEntityRegistry = { get = function(_, profileKey)
            return NightShift.Result.ok({ profileKey = profileKey, bookingId = '77', travelKey = 'travel:77', generationToken = 'npc:profile:77:1' })
        end }
    }
    local oldServer = NightShift.Server
    NightShift.Server = { instance = { results = { services = { services = services } } } }
    dofile('server/api/nui_callbacks.lua')
    local handler = listeners['gnsh-nightshift:nui:request']
    check(type(handler) == 'function', 'NUI request handler must be registered')
    _G.source = '12'
    handler('string-source', 'favorite:list', {})
    local stringSourceResponse = responses[#responses]
    check(stringSourceResponse and stringSourceResponse.id == 'string-source'
        and tonumber(stringSourceResponse.source) == 12 and stringSourceResponse.result,
        'NUI request must normalize a string player source')
    _G.source = 12
    handler('generation-ok', 'security:action-token', {
        bookingId = 77, action = 'client-mode:arrival', profileKey = 'profile:77',
        travelKey = 'travel:77', generation = 'npc:profile:77:1'
    })
    local accepted = responses[#responses] and responses[#responses].result
    check(accepted and accepted.ok and accepted.value and accepted.value.token,
        'matching server generation should issue a replacement token')
    local wrongGeneration = tokens:authorize(12, 77, 'client-mode:arrival', accepted.value.token,
        { generation = 'npc:profile:77:2' })
    check(not wrongGeneration.ok and wrongGeneration.error.code == NightShift.Errors.Codes.ACTION_TOKEN_ACTION_MISMATCH,
        'replacement token must retain its server-verified generation binding')
    handler('generation-missing', 'security:action-token', {
        bookingId = 77, action = 'client-mode:arrival', profileKey = 'profile:77', travelKey = 'travel:77'
    })
    local missing = responses[#responses] and responses[#responses].result
    check(missing and not missing.ok and missing.error and missing.error.code == 'ACTION_TOKEN_INVALID',
        'generation-bound refresh without generation must fail closed')
    handler('generation-bad', 'security:action-token', {
        bookingId = 77, action = 'client-mode:arrival', profileKey = 'profile:77',
        travelKey = 'travel:77', generation = 'npc:profile:77:999'
    })
    local rejected = responses[#responses] and responses[#responses].result
    check(rejected and not rejected.ok and rejected.error and rejected.error.code == 'ACTION_TOKEN_INVALID',
        'mismatched browser generation must be rejected before issuance')
    handler('generation-alias', 'security:action-token', {
        bookingId = 77, action = 'client-mode:arrival', profileKey = 'profile:77',
        travelKey = 'travel:77', generationToken = 'npc:profile:77:1'
    })
    local alias = responses[#responses] and responses[#responses].result
    check(alias and alias.ok and alias.value and alias.value.token,
        'generationToken alias should normalize at the refresh boundary')
    handler('retry-seed', 'security:action-token', { bookingId = 77, action = 'client-mode:travel' })
    local retrySeed = responses[#responses] and responses[#responses].result
    check(retrySeed and retrySeed.ok and retrySeed.value and retrySeed.value.token,
        'retry test must obtain an initial lifecycle token')
    handler('travel-failure', 'client-mode:travel', { bookingId = 77, actionToken = retrySeed.value.token })
    local failure = responses[#responses] and responses[#responses].result
    check(failure and not failure.ok and failure.error and failure.error.code == 'TRANSIENT_FAILURE',
        'service failure must cross the real NUI callback boundary')
    local replayed = tokens:authorize(12, 77, 'client-mode:travel', retrySeed.value.token)
    check(not replayed.ok and replayed.error.code == NightShift.Errors.Codes.ACTION_TOKEN_REPLAY,
        'a token consumed before a service failure must not be reusable')
    handler('retry-refresh', 'security:action-token', { bookingId = 77, action = 'client-mode:travel' })
    local refreshed = responses[#responses] and responses[#responses].result
    check(refreshed and refreshed.ok and refreshed.value and refreshed.value.token
        and refreshed.value.token ~= retrySeed.value.token,
        'retry flow must issue a fresh token after a service failure')
    local retryAuthorized = tokens:authorize(12, 77, 'client-mode:travel', refreshed.value.token)
    check(retryAuthorized.ok, 'fresh retry token must authorize the same lifecycle action')
    bookingStatus = 'SETTLED'
    handler('terminal-booking', 'security:action-token', { bookingId = 77, action = 'client-mode:session-start' })
    local terminal = responses[#responses] and responses[#responses].result
    check(terminal and not terminal.ok and terminal.error and terminal.error.code == 'API_FORBIDDEN',
        'terminal bookings must not receive lifecycle tokens')
    if oldServer then NightShift.Server = oldServer else NightShift.Server = nil end
    if oldRegister == nil then _G.RegisterNetEvent = nil else _G.RegisterNetEvent = oldRegister end
    if oldAddHandler == nil then _G.AddEventHandler = nil else _G.AddEventHandler = oldAddHandler end
    if oldTrigger == nil then _G.TriggerClientEvent = nil else _G.TriggerClientEvent = oldTrigger end
    if oldSource == nil then _G.source = nil else _G.source = oldSource end
end

print('NS-270..NS-275 tests passed: security config, rate limits, action tokens, replay, expiry, abuse boundaries, and NUI generation binding')
