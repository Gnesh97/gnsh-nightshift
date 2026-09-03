local function check(value, message) assert(value, message) end

local loggerEntries = {}
local bus = NightShift.EventBus.new({
    clock = NightShift.Clock.new({ now = function() return 0 end }),
    logger = NightShift.Logger.new({
        clock = NightShift.Clock.new({ now = function() return 0 end }),
        correlationId = 'bus-test',
        sink = function(entry) loggerEntries[#loggerEntries + 1] = entry end
    })
})

do
    local order, secondPayload = {}, nil
    local first = bus:subscribe('booking.committed', function(event)
        order[#order + 1] = 'first'
        event.payload.amount = 999
    end)
    local second = bus:subscribe('booking.committed', function(event)
        order[#order + 1] = 'second'
        secondPayload = event.payload.amount
        check(event.correlationId == 'corr-1', 'correlation must reach handlers')
        check(event.occurredAt == '1970-01-01T00:00:00Z', 'event timestamp must be UTC')
        check(event.committed == true, 'publish must represent a committed event')
    end)
    check(type(first) == 'string' and type(second) == 'string' and first ~= second, 'subscription handles must be opaque and unique')
    local payload = { amount = 100 }
    local result = bus:publishCommitted('booking.committed', payload, { correlationId = 'corr-1' })
    check(result.ok and result.value.delivered == 2 and result.value.failed == 0, 'handlers should run in subscription order')
    check(table.concat(order, ',') == 'first,second', 'handler order must be deterministic')
    check(secondPayload == 100 and payload.amount == 100, 'handler/publisher payload mutation must not leak')
end

do
    local count = 0
    local handle = bus:subscribe('unsubscribe.test', function() count = count + 1 end)
    check(bus:unsubscribe(handle) == true, 'unsubscribe should remove a handler')
    check(bus:unsubscribe(handle) == false, 'repeated unsubscribe should be deterministic')
    check(bus:unsubscribe('unknown-handle') == false, 'unknown unsubscribe should be safe')
    local result = bus:publishCommitted('unsubscribe.test', {})
    check(result.ok and result.value.delivered == 0 and count == 0, 'unsubscribed handler must not run')
end

do
    local order, firstHandle = {}, nil
    firstHandle = bus:subscribe('mutation.during.publish', function()
        order[#order + 1] = 'first'
        bus:unsubscribe(firstHandle)
    end)
    bus:subscribe('mutation.during.publish', function() order[#order + 1] = 'second' end)
    local result = bus:publishCommitted('mutation.during.publish', {})
    check(result.ok and result.value.delivered == 2 and table.concat(order, ',') == 'first,second', 'publish must snapshot listeners before dispatch')
end

do
    local survived = false
    bus:subscribe('failure.isolated', function() error('expected handler failure') end)
    bus:subscribe('failure.isolated', function() survived = true end)
    local result = bus:publishCommitted('failure.isolated', {}, { correlationId = 'failure-corr' })
    check(result.ok and result.value.delivered == 1 and result.value.failed == 1 and survived, 'one handler failure must not abort later handlers')
    check(#loggerEntries > 0 and loggerEntries[#loggerEntries].correlationId == 'failure-corr', 'handler failure must be logged with correlation')
end

do
    local attempts = 0
    local retryBus = NightShift.EventBus.new({ retryLimit = 3 })
    retryBus:subscribe('retryable', function()
        attempts = attempts + 1
        if attempts == 1 then return NightShift.Result.err('TEMPORARY', 'retry me') end
    end)
    local published = retryBus:publishCommitted('retryable', {})
    check(published.ok and published.metadata.retryPending == 1, 'failed handlers should be queued for retry')
    local retried = retryBus:retryFailed()
    check(retried.ok and retried.value.delivered == 1 and retried.value.failed == 0 and attempts == 2 and retryBus:pendingFailures() == 0, 'failed event handlers should recover through bounded retry')
end

do
    local seen
    bus:subscribe('correlation.normalized', function(event) seen = event.correlationId end)
    bus:publishCommitted('correlation.normalized', {}, { correlationId = 'unsafe id/value' })
    check(seen == 'unsafeidvalue', 'correlation IDs must be normalized before dispatch')
    bus:publishCommitted('correlation.normalized', {}, { correlationId = {} })
    check(seen == 'bus-test', 'malformed correlation IDs must use the internal fallback')
end

do
    local called = false
    check(bus:subscribe('', function() end) == nil, 'empty event names must fail')
    check(bus:subscribe('bad-handler', 'not-a-function') == nil, 'non-function handlers must fail')
    local result = bus:publishCommitted('', {})
    check(not result.ok and result.error.code == 'INVALID_EVENT', 'invalid publish must return a structured error')
    check(not called, 'invalid event must not dispatch')
end
