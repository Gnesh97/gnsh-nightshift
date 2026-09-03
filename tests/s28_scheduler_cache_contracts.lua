local function check(value, message) assert(value, message) end

local Result = NightShift.Result
local Cache = NightShift.SummaryCache
local Analytics = NightShift.AnalyticsService
local AnalyticsRepository = NightShift.Repositories.Analytics
local EventBus = NightShift.EventBus
local ScheduledJob = NightShift.ScheduledBookingJob
check(type(Cache) == 'table' and type(Cache.new) == 'function', 'summary cache must be available')
check(type(Analytics) == 'table' and type(Analytics.new) == 'function', 'analytics service must be available')
check(type(AnalyticsRepository) == 'table' and type(AnalyticsRepository.new) == 'function',
    'analytics repository must be available')

local now = 100
local clock = NightShift.Clock.new({ now = function() return now end })
local cache = assert(Cache.new({ clock = clock, config = { maxEntries = 2, ttlSeconds = 10 } }))
check(not Cache.new({ config = { maxEntries = 0, ttlSeconds = 10 } }),
    'summary cache must reject zero capacity')
check(cache:put('summary:a', { count = 1 }).ok, 'cache should store a summary copy')
local hit = cache:get('summary:a')
check(hit.ok and hit.value.hit and hit.value.value.count == 1, 'cache should return a hit')
hit.value.value.count = 99
check(cache:get('summary:a').value.value.count == 1, 'cache values must be immutable copies')
check(cache:put('summary:b', { count = 2 }).ok and cache:put('summary:c', { count = 3 }).ok,
    'cache should admit bounded entries')
check(cache:get('summary:a').value.hit == false, 'cache should evict the oldest entry at its bound')

local bus = assert(EventBus.new({ clock = clock }))
local attached = assert(cache:subscribe(bus)).value
check(attached.subscriptions > 0, 'cache should subscribe to domain invalidation events')
check(cache:put('summary:active', { count = 4 }).ok, 'cache should store an active summary')
check(bus:publishCommitted('booking.updated', { id = 'booking:one' }).ok,
    'domain event should publish for cache invalidation')
check(cache:get('summary:active').value.hit == false, 'domain event must invalidate cached summaries')

local rollbackCount = 0
local brokenBus = {
    subscribe = function(_, eventName)
        if eventName == 'booking.settled' then
            return nil, Result.err('SUBSCRIBE_FAILED', 'test subscription failure')
        end
        return 'subscription-before-failure'
    end,
    unsubscribe = function(_, handle)
        if handle == 'subscription-before-failure' then rollbackCount = rollbackCount + 1 end
        return true
    end
}
local rollbackCache = assert(Cache.new({ clock = clock, config = { maxEntries = 2, ttlSeconds = 10 } }))
local rollbackResult = rollbackCache:subscribe(brokenBus, { 'booking.updated', 'booking.settled' })
check(not rollbackResult.ok and rollbackCount == 1,
    'partial summary cache subscriptions must roll back on failure')

local analyticsSql
local realAnalyticsRepository = assert(AnalyticsRepository.new({
    db = { query = function(_, sql) analyticsSql = sql; return Result.ok({}) end }
}))
local demandRows = realAnalyticsRepository:demandSummary()
check(demandRows.ok and analyticsSql:find('FROM nightshift_booking_events', 1, true)
    and not analyticsSql:find('FROM nil', 1, true),
    'analytics demand queries must use an explicit event table')
check(not AnalyticsRepository.new({
    db = { query = function() return Result.ok({}) end }, tableName = 'events;drop'
}), 'analytics repository table name must be validated')

local bookingCalls, settlementCalls = 0, 0
local analyticsRepository = {
    bookingSummary = function(_, window)
        bookingCalls = bookingCalls + 1
        check(window.from == 100 and window.to == 200, 'analytics cache key must use normalized window')
        return Result.ok({ { status = 'OFFERED', mode = 'COME_TO_ME', count = 1, averageAmountMinor = 100 } })
    end,
    settlementSummary = function()
        settlementCalls = settlementCalls + 1
        return Result.ok({ { status = 'SETTLED', count = 1 } })
    end
}
local analyticsCache = assert(Cache.new({ clock = clock, config = { maxEntries = 4, ttlSeconds = 60 } }))
local analytics = assert(Analytics.new({
    repository = analyticsRepository, clock = clock, cache = analyticsCache, eventBus = bus
}))
local first = analytics:summary({ from = 100, to = 200 })
check(first.ok and first.metadata.cacheHit == false and first.metadata.cacheStored == true,
    'first analytics summary should populate the cache')
local second = analytics:summary({ from = 100, to = 200 })
check(second.ok and second.metadata.cacheHit == true and bookingCalls == 1 and settlementCalls == 1,
    'second analytics summary should be a cache hit')
check(bus:publishCommitted('heat.changed', { district = 'vinewood' }).ok,
    'heat event should invalidate read-heavy summaries')
local third = analytics:summary({ from = 100, to = 200 })
check(third.ok and third.metadata.cacheHit == false and bookingCalls == 2 and settlementCalls == 2,
    'invalidated analytics summary should refresh from repositories')

local dueCalls, activated = 0, {}
local scheduledRepository = {
    findDueScheduled = function(_, timestamp, options)
        dueCalls = dueCalls + 1
        check(timestamp == 100 and options.limit == 2, 'scheduler must use one bounded due query')
        return Result.ok({
            { id = 'booking:one', version = 1 },
            { id = 'booking:two', version = 1 }
        })
    end
}
local bookingService = {
    activateScheduled = function(_, _, id, version)
        activated[#activated + 1] = { id = id, version = version }
        return Result.ok({ id = id })
    end
}
local scheduler = assert(ScheduledJob.new({
    repository = scheduledRepository, bookingService = bookingService,
    clock = clock, config = { enabled = true, tickSeconds = 1, batchSize = 2, reservationLeadTimeSeconds = 0 }
}))
local run = scheduler:runOnce(100)
check(run.ok and run.value.scanned == 2 and run.value.activated == 2
    and dueCalls == 1 and #activated == 2,
    'scheduled bookings must activate in a bounded batch without per-booking threads')
check(scheduler:stop().ok and scheduler:isRunning() == false, 'scheduler stop must be idempotent')

print('NS-283 tests passed: bounded summary cache, event invalidation, analytics reuse, and batch scheduler execution')
