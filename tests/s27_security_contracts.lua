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

print('NS-270..NS-274 tests passed: security config, rate limits, action tokens, replay, expiry, and abuse boundaries')
