NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = (NightShift.Errors and NightShift.Errors.Codes) or {}

local function errorResult(code, message, details)
    if Result and Result.err then return Result.err(code, message, details) end
    return { ok = false, success = false, error = { code = code, message = message, details = details } }
end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[key] = copy(item, seen) end
    return output
end

local function finiteNumber(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function integer(value)
    local number = finiteNumber(value)
    if not number or number % 1 ~= 0 then return nil end
    return number
end

local function validText(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function parsePage(options, maximum)
    local limit = options.limit == nil and 20 or integer(options.limit)
    local offset = options.offset == nil and 0 or integer(options.offset)
    if not limit or limit < 1 or limit > maximum or not offset or offset < 0 then
        return nil, errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace pagination is invalid', {
            limit = options.limit,
            offset = options.offset,
            maxPageSize = maximum
        })
    end
    return limit, offset
end

local function validateFilters(options)
    if options.district ~= nil and not validText(options.district, 64) then return false, 'district' end
    if options.travelMode ~= nil and not validText(options.travelMode, 24) then return false, 'travelMode' end
    for _, key in ipairs({ 'priceClass', 'maxPriceClass' }) do
        if options[key] ~= nil then
            local value = integer(options[key])
            if not value or value < 1 or value > 5 then return false, key end
        end
    end
    if options.minRating ~= nil then
        local value = finiteNumber(options.minRating)
        if not value or value < 0 or value > 5 then return false, 'minRating' end
    end
    return true
end

local function etaFor(estimator, worker)
    if type(estimator) ~= 'function' then return nil end
    local ok, value = pcall(estimator, copy(worker))
    if not ok then return nil end
    value = integer(value)
    if not value or value < 0 or value > 1440 then return nil end
    return value
end

local function publicCard(worker, etaEstimator)
    local profile = worker.profile or {}
    local workerKey = worker.workerKey or worker.id or profile.profileKey
    local alias = profile.alias or profile.displayName or worker.alias
    local card = {
        publicId = tostring(workerKey),
        workerId = tostring(workerKey),
        alias = alias and tostring(alias) or 'NightShift worker',
        rating = finiteNumber(profile.rating) or 0,
        priceClass = integer(profile.priceClass or profile.budgetClass) or 1,
        district = worker.activeDistrict or profile.activeDistrict or profile.homeDistrict,
        area = worker.activeDistrict or profile.activeDistrict or profile.homeDistrict,
        travelMode = profile.travelMode,
        availability = 'AVAILABLE',
        profileType = profile.profileType,
        etaMinutes = etaFor(etaEstimator, worker)
    }
    return card
end

local Service = {}
Service.__index = Service

function Service.new(options)
    options = options or {}
    if type(options.workerService) ~= 'table' then
        return nil, errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace requires a worker service')
    end
    local maxPageSize = integer(options.maxPageSize or 50) or 50
    if maxPageSize < 1 or maxPageSize > 100 then
        return nil, errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace max page size is invalid')
    end
    return setmetatable({
        _workerService = options.workerService,
        _maxPageSize = maxPageSize,
        _etaEstimator = options.etaEstimator,
        _clock = options.clock,
        _blacklist = options.blacklistService or options.blacklist
    }, Service)
end

function Service:list(options)
    options = options or {}
    if type(options) ~= 'table' then
        return errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace options must be a table')
    end
    local limit, offsetOrError = parsePage(options, self._maxPageSize)
    if not limit then return offsetOrError end
    local offset = offsetOrError
    local valid, invalidKey = validateFilters(options)
    if not valid then
        return errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace filter is invalid', { field = invalidKey })
    end

    local result = self._workerService:listAvailable({
        district = options.district,
        priceClass = options.priceClass,
        maxPriceClass = options.maxPriceClass,
        minRating = options.minRating,
        travelMode = options.travelMode,
        limit = limit,
        offset = offset
    })
    if type(result) ~= 'table' or result.ok ~= true then
        local details = type(result) == 'table' and (result.error or result.details) or nil
        return errorResult(Codes.MARKETPLACE_QUERY_FAILED or 'MARKETPLACE_QUERY_FAILED', 'Marketplace query failed', details)
    end

    local source = result.value or {}
    local workers = source.items or source
    if type(workers) ~= 'table' then
        return errorResult(Codes.MARKETPLACE_QUERY_FAILED or 'MARKETPLACE_QUERY_FAILED', 'Marketplace returned an invalid worker list')
    end
    local cards = {}
    if self._blacklist and options.source ~= nil then
        local filtered = self._blacklist:filterWorkers(options.source, workers, options)
        if type(filtered) ~= 'table' or filtered.ok ~= true then return errorResult(Codes.MARKETPLACE_QUERY_FAILED or 'MARKETPLACE_QUERY_FAILED', 'Marketplace blacklist filtering failed') end
        workers = filtered.value
    end
    for _, worker in ipairs(workers) do
        if type(worker) == 'table' then cards[#cards + 1] = publicCard(worker, self._etaEstimator) end
    end
    local total = integer(source.total) or #cards
    return Result.ok({
        items = cards,
        total = total,
        limit = limit,
        offset = offset
    }, { total = total, limit = limit, offset = offset })
end

function Service:get(publicId)
    if not validText(publicId, 160) then
        return errorResult(Codes.MARKETPLACE_INVALID or 'MARKETPLACE_INVALID', 'Marketplace worker id is invalid')
    end
    if type(self._workerService.get) ~= 'function' then
        return errorResult(Codes.MARKETPLACE_QUERY_FAILED or 'MARKETPLACE_QUERY_FAILED', 'Marketplace worker lookup is unavailable')
    end
    local result = self._workerService:get(publicId)
    if type(result) ~= 'table' or result.ok ~= true then
        return errorResult(Codes.MARKETPLACE_QUERY_FAILED or 'MARKETPLACE_QUERY_FAILED', 'Marketplace worker lookup failed')
    end
    return Result.ok(publicCard(result.value, self._etaEstimator))
end

Service.query = Service.list
Service.listWorkers = Service.list

NightShift.MarketplaceQueryService = Service
NightShift.Services.MarketplaceQuery = Service
NightShift.Services.Marketplace = Service

return Service
