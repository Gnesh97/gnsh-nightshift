NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function timestamp(clock, epoch)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock, epoch)
        if ok and type(value) == 'string' then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', epoch)
end

local function normalizeRows(result, field)
    if type(result) ~= 'table' or not result.ok then return nil, result end
    if type(result.value) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_STATE_UNKNOWN, field .. ' analytics result is invalid') end
    return result.value
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.analyticsRepository
    if type(repository) ~= 'table' or type(repository.bookingSummary) ~= 'function'
        or type(repository.settlementSummary) ~= 'function' then
        return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'analytics service requires an analytics repository')
    end
    if options.cache ~= nil and
        (type(options.cache) ~= 'table' or type(options.cache.get) ~= 'function'
            or type(options.cache.put) ~= 'function') then
        return nil, Result.err(Codes.REPOSITORY_INVALID, 'analytics summary cache is invalid')
    end
    local service = setmetatable({
        _repository = repository,
        _clock = options.clock,
        _maxWindowSeconds = integer(options.maxWindowSeconds, 60, 31536000) or 7776000,
        _cache = options.cache,
        _cacheSubscription = nil
    }, Service)
    if options.eventBus ~= nil then
        local attached, attachError = service:subscribe(options.eventBus, options.cacheEvents)
        if type(attached) ~= 'table' or attached.ok ~= true then return nil, attachError or attached end
    end
    return service
end

function Service:_range(options)
    options = type(options) == 'table' and options or {}
    local now = type(self._clock) == 'table' and type(self._clock.now) == 'function'
        and self._clock:now() or os.time()
    local to = tonumber(options.to or options['until'] or now)
    local from = tonumber(options.from or options.since or (to - 86400))
    if not from or not to or from < 0 or to <= from or to - from > self._maxWindowSeconds then
        return nil, invalid('analytics time range is invalid')
    end
    return { from = from, to = to, since = timestamp(self._clock, from), ['until'] = timestamp(self._clock, to) }
end

function Service:subscribe(eventBus, eventNames)
    if self._cache == nil then return Result.ok({ subscriptions = 0 }, { skipped = true }) end
    local result = self._cache:subscribe(eventBus, eventNames)
    if result.ok then self._cacheSubscription = result.value end
    return result
end

function Service:_cacheKey(window)
    return ('analytics:%d:%d'):format(math.floor(window.from), math.floor(window.to))
end

function Service:summary(options)
    local window, rangeError = self:_range(options)
    if not window then return rangeError end
    local cacheKey = self:_cacheKey(window)
    if self._cache then
        local cached = self._cache:get(cacheKey)
        if type(cached) == 'table' and cached.ok and cached.value and cached.value.hit then
            return Result.ok(cached.value.value, {
                from = window.since, ['until'] = window['until'],
                bounded = true, cacheHit = true
            })
        end
    end
    local bookingRows, bookingError = normalizeRows(self._repository:bookingSummary(window), 'booking')
    if not bookingRows then return bookingError end
    local settlementRows, settlementError = normalizeRows(self._repository:settlementSummary(window), 'settlement')
    if not settlementRows then return settlementError end
    local travelRows = {}
    if type(self._repository.travelFailureSummary) == 'function' then
        local result = self._repository:travelFailureSummary(window)
        local value, errorResult = normalizeRows(result, 'travel')
        if not value then return errorResult end
        travelRows = value
    end
    local demandRows = {}
    if type(self._repository.demandSummary) == 'function' then
        local result = self._repository:demandSummary(window)
        local value, errorResult = normalizeRows(result, 'demand')
        if not value then return errorResult end
        demandRows = value
    end
    local byStatus, byMode, settlementByStatus = {}, {}, {}
    local demandByDistrict = {}
    local totalBookings, averageSum, averageCount = 0, 0, 0
    local offered, accepted = 0, 0
    for _, row in ipairs(bookingRows) do
        local count = integer(row.count, 0) or 0
        local status = type(row.status) == 'string' and row.status:upper() or 'UNKNOWN'
        local mode = type(row.mode) == 'string' and row.mode:upper() or 'UNKNOWN'
        byStatus[status] = (byStatus[status] or 0) + count
        byMode[mode] = (byMode[mode] or 0) + count
        totalBookings = totalBookings + count
        if status == 'OFFERED' then offered = offered + count end
        if status == 'ACCEPTED' or status == 'RESERVED' or status == 'COMPLETED' or status == 'SETTLED' then accepted = accepted + count end
        local average = tonumber(row.averageAmountMinor)
        if average and average >= 0 then averageSum = averageSum + average * count; averageCount = averageCount + count end
    end
    local settlementFailures = 0
    for _, row in ipairs(settlementRows) do
        local status = type(row.status) == 'string' and row.status:upper() or 'UNKNOWN'
        local count = integer(row.count, 0) or 0
        settlementByStatus[status] = (settlementByStatus[status] or 0) + count
        if status == 'FAILED' or status == 'DECLINED' or status == 'UNKNOWN' then settlementFailures = settlementFailures + count end
    end
    local travelFailures = 0
    for _, row in ipairs(travelRows) do travelFailures = travelFailures + (integer(row.count, 0) or 0) end
    for _, row in ipairs(demandRows) do
        if row.district then
            demandByDistrict[row.district] = (demandByDistrict[row.district] or 0) + (integer(row.count, 0) or 0)
        end
    end
    local summary = {
        window = { from = window.from, to = window.to },
        totalBookings = totalBookings,
        byStatus = byStatus,
        byMode = byMode,
        averageAgreedPriceMinor = averageCount > 0 and averageSum / averageCount or nil,
        settlementByStatus = settlementByStatus,
        settlementFailures = settlementFailures,
        travelEvents = copy(travelRows),
        travelFailures = travelFailures,
        demandByDistrict = demandByDistrict,
        conversion = offered > 0 and accepted / offered or nil,
        gameplayAuthority = false
    }
    local cacheStored = false
    if self._cache then
        local stored = self._cache:put(cacheKey, summary)
        cacheStored = type(stored) == 'table' and stored.ok == true and stored.value and stored.value.stored == true
    end
    return Result.ok(summary, {
        from = window.since, ['until'] = window['until'], bounded = true,
        cacheHit = false, cacheStored = cacheStored
    })
end

Service.dashboard = Service.summary
Service.kpis = Service.summary
NightShift.AnalyticsService = Service
NightShift.Services.Analytics = Service
