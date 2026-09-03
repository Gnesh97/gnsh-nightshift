local function check(value, message) assert(value, message) end

check(NightShift.Server.readiness == NightShift.Enums.Readiness.DEGRADED,
    'server lifecycle should expose DEGRADED when optional runtime dependencies are deferred')

do
    local source = { id = 1 }
    local result = NightShift.Result.ok(source, { correlationId = 'abc' })
    source.id = 2
    check(result.ok and result.success and result.metadata.correlationId == 'abc', 'Result.ok shape')
    check(result.value.id == 1 and result.data.id == 1, 'Result.ok must copy caller values')
    local failure = NightShift.Result.err(NightShift.Errors.Codes.VALIDATION, 'bad', { field = 'name' }, { correlationId = 'abc' })
    check(not failure.ok and failure.error.code == 'VALIDATION_FAILED' and failure.details.field == 'name', 'Result.err shape')
    check(NightShift.Errors.Codes.UNAVAILABLE_CAPABILITY == 'CAPABILITY_UNAVAILABLE', 'stable error codes')
end

do
    local clock = NightShift.Clock.new({ now = function() return 0 end })
    check(clock:timestamp() == '1970-01-01T00:00:00Z', 'UTC injected timestamp')
    check(NightShift.Clock.utcTimestamp(1) == '1970-01-01T00:00:01Z', 'UTC formatting')
    check(type(NightShift.Clock.utcTimestamp(math.huge)) == 'string', 'non-finite epoch must fail safe')
end

do
    local entries = {}
    local logger = NightShift.Logger.new({
        clock = NightShift.Clock.new({ now = function() return 0 end }),
        correlationId = 'client id/unsafe',
        debugCategories = { allowed = true },
        sink = function(entry) entries[#entries + 1] = entry end
    })
    local context = {
        account = 'hidden',
        sessionToken = 'hidden',
        webhookUrl = 'hidden',
        nested = { password = 'hidden', visible = 'ok' }
    }
    check(not logger:debug('blocked', 'ignored'), 'debug category filtering')
    check(logger:debug('allowed', 'message', context), 'debug category allowed')
    check(#entries == 1 and entries[1].timestamp == '1970-01-01T00:00:00Z', 'logger entry')
    check(entries[1].context.account == '[REDACTED]' and entries[1].context.sessionToken == '[REDACTED]' and entries[1].context.webhookUrl == '[REDACTED]' and entries[1].context.nested.password == '[REDACTED]' and entries[1].context.nested.visible == 'ok', 'recursive redaction')
    check(context.account == 'hidden' and context.sessionToken == 'hidden' and context.webhookUrl == 'hidden' and context.nested.password == 'hidden', 'redaction must not mutate input')
end

do
    local logger = NightShift.Logger.new({ filter = function() error('filter failure') end, sink = function() error('sink failure') end })
    check(not logger:info('test', 'safe'), 'filter failure isolation')
    local logger2 = NightShift.Logger.new({ sink = function() error('sink failure') end })
    check(logger2:info('test', 'safe'), 'sink failure isolation')
end
