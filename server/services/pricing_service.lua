NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local PriceQuote = NightShift.Domain.PriceQuote

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

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge and value
end

local function invalid(message, details)
    return Result.err(Codes.PRICING_INVALID, message, details)
end

local function normalizedMap(value, field)
    if value == nil then return {} end
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a table') end
    local output = {}
    for key, item in pairs(value) do
        if type(key) ~= 'string' or not text(key, 64) then return nil, invalid(field .. ' contains an invalid key') end
        item = finite(item)
        if not item or item <= 0 or item > 100 then return nil, invalid(field .. ' multiplier is outside safe bounds', { key = key }) end
        output[key:upper()] = item
    end
    return output
end

local function timestamp(clock, value)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' and value == nil then
        local ok, result = pcall(clock.timestamp, clock)
        if ok and text(result, 64) then return result end
    end
    if type(clock) == 'table' and type(clock.now) == 'function' and value == nil then
        local ok, result = pcall(clock.now, clock)
        result = tonumber(result)
        if ok and finite(result) and NightShift.Clock and type(NightShift.Clock.utcTimestamp) == 'function' then
            return NightShift.Clock.utcTimestamp(result)
        end
    end
    if type(NightShift.Clock) == 'table' and type(NightShift.Clock.utcTimestamp) == 'function' and value ~= nil then
        return NightShift.Clock.utcTimestamp(value)
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', tonumber(value) or os.time())
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return value end
    end
    return os.time()
end

local function round(value)
    return math.floor(value + 0.5)
end

local function key(value)
    return type(value) == 'string' and value:upper() or nil
end

local function demandKey(value)
    if type(value) == 'string' then return value:upper() end
    value = finite(value)
    if not value then return 'NORMAL' end
    if value >= 70 then return 'HIGH' end
    if value <= 30 then return 'LOW' end
    return 'NORMAL'
end

local function reputationKey(value)
    if type(value) == 'string' then return value:upper() end
    value = finite(value)
    if not value then return 'NORMAL' end
    if value < 25 then return 'LOW' end
    if value >= 75 then return 'TRUSTED' end
    return 'NORMAL'
end

function Service.new(options)
    options = options or {}
    local catalog = options.catalog or options.serviceCatalog
    if type(catalog) ~= 'table' or type(catalog.resolve) ~= 'function' then return nil, invalid('pricing service requires a service catalog') end
    local config = copy(options.config or NightShift.PricingConfig or {})
    if config.enabled == nil then config.enabled = true end
    if type(config.enabled) ~= 'boolean' then return nil, invalid('pricing enabled flag must be boolean') end
    local ttl = integer(config.quoteTtlSeconds or config.quoteTTLSeconds or 300, 1, 86400)
    local minimum = integer(config.minAmountMinor or 1, 0, 100000000000)
    local maximum = integer(config.maxAmountMinor or 100000000000, 1, 100000000000)
    if not ttl or not minimum or not maximum or minimum > maximum then return nil, invalid('pricing bounds are invalid') end
    local currency = type(config.currency) == 'string' and config.currency:upper() or 'USD'
    if currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('pricing currency is invalid') end
    local maps = {}
    for _, name in ipairs({ 'npcPriceClasses', 'districtModifiers', 'timeModifiers', 'demandModifiers', 'reputationModifiers' }) do
        local normalized, errorResult = normalizedMap(config[name], name)
        if not normalized then return nil, errorResult end
        maps[name] = normalized
    end
    local fees = config.fees or {}
    if type(fees) ~= 'table' then return nil, invalid('pricing fees must be a table') end
    local travel = integer(fees.travelMinor or fees.travelFeeMinor or 0, 0, 100000000000)
    local location = integer(fees.locationMinor or fees.locationFeeMinor or 0, 0, 100000000000)
    if not travel or not location then return nil, invalid('pricing fees are invalid') end
    local normalized = {
        enabled = config.enabled,
        currency = currency,
        quoteTtlSeconds = ttl,
        minAmountMinor = minimum,
        maxAmountMinor = maximum,
        npcPriceClasses = maps.npcPriceClasses,
        districtModifiers = maps.districtModifiers,
        timeModifiers = maps.timeModifiers,
        demandModifiers = maps.demandModifiers,
        reputationModifiers = maps.reputationModifiers,
        fees = { travelMinor = travel, locationMinor = location }
    }
    return setmetatable({
        _catalog = catalog,
        _config = normalized,
        _clock = options.clock or (NightShift.Clock and NightShift.Clock.new and NightShift.Clock.new() or nil),
        _idGenerator = options.idGenerator,
        _resolvers = {
            npcPriceClass = options.npcPriceClassResolver,
            district = options.districtResolver,
            time = options.timeResolver,
            demand = options.demandResolver,
            reputation = options.reputationResolver,
            travelFee = options.travelFeeResolver,
            locationFee = options.locationFeeResolver
        },
        _sequence = 0
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_resolve(name, request, fallback)
    local resolver = self._resolvers[name]
    if type(resolver) == 'function' then
        local ok, value = pcall(resolver, copy(request))
        if ok and value ~= nil then return value end
    end
    return fallback
end

function Service:_multiplier(mapName, value)
    local map = self._config[mapName] or {}
    local normalized = key(value)
    if normalized and map[normalized] ~= nil then return map[normalized], normalized end
    return 1, normalized or 'NORMAL'
end

function Service:_quoteId(packageId, issuedAt)
    self._sequence = self._sequence + 1
    if type(self._idGenerator) == 'function' then
        local ok, value = pcall(self._idGenerator, packageId, issuedAt, self._sequence)
        if ok and text(value, 128) then return value end
    end
    return ('quote:%s:%s:%d'):format(packageId, issuedAt:gsub('[^%w]', ''), self._sequence)
end

function Service:quote(request)
    if not self:isEnabled() then return Result.err(Codes.PRICING_UNAVAILABLE, 'pricing is disabled') end
    if type(request) ~= 'table' then return invalid('pricing request must be a table') end
    local packageId = request.servicePackageId or request.service_package_id or request.packageId or request.servicePackage
    if type(packageId) == 'table' then packageId = packageId.id end
    if not text(packageId, 96) then return invalid('service package ID is required') end
    local packageResult = self._catalog:resolve(packageId, request)
    if type(packageResult) ~= 'table' or not packageResult.ok then return packageResult end
    local package = packageResult.value
    local issuedEpoch = now(self._clock)
    local issuedAt = timestamp(self._clock)
    local lineItems = { { key = 'base', label = 'service package', amountMinor = package.basePriceMinor or package.priceMinor, multiplier = 1 } }
    local amount = package.basePriceMinor or package.priceMinor
    local function applyMultiplier(name, requested, mapName)
        local multiplier, normalized = self:_multiplier(mapName, requested)
        if multiplier ~= 1 then
            local before = amount
            amount = amount * multiplier
            lineItems[#lineItems + 1] = { key = name, label = name, multiplier = multiplier, amountMinor = round(amount - before), value = normalized }
        end
    end
    local npcClass = self:_resolve('npcPriceClass', request, request.npcPriceClass or request.priceClass or 'STANDARD')
    applyMultiplier('npcPriceClass', npcClass, 'npcPriceClasses')
    local district = self:_resolve('district', request, request.district)
    applyMultiplier('district', district, 'districtModifiers')
    local timeBand = self:_resolve('time', request, request.timeBand or request.time)
    applyMultiplier('time', timeBand, 'timeModifiers')
    local demand = self:_resolve('demand', request, request.demand)
    applyMultiplier('demand', demandKey(demand), 'demandModifiers')
    local reputation = self:_resolve('reputation', request, request.clientReputation or request.reputationTier or request.reputation)
    applyMultiplier('reputation', reputationKey(reputation), 'reputationModifiers')
    local travel = self:_resolve('travelFee', request, self._config.fees.travelMinor)
    local location = self:_resolve('locationFee', request, self._config.fees.locationMinor)
    travel, location = integer(travel, 0, 100000000000), integer(location, 0, 100000000000)
    if not travel or not location then return invalid('server fee resolver returned an invalid amount') end
    if travel > 0 then amount = amount + travel; lineItems[#lineItems + 1] = { key = 'travel', label = 'travel fee', amountMinor = travel, multiplier = 1 } end
    if location > 0 then amount = amount + location; lineItems[#lineItems + 1] = { key = 'location', label = 'location fee', amountMinor = location, multiplier = 1 } end
    amount = round(amount)
    if amount < self._config.minAmountMinor then amount = self._config.minAmountMinor end
    if amount > self._config.maxAmountMinor then amount = self._config.maxAmountMinor end
    local expiresEpoch = issuedEpoch + self._config.quoteTtlSeconds
    local expiresAt = timestamp(self._clock, expiresEpoch)
    local quote = {
        id = self:_quoteId(package.id, issuedAt),
        quoteId = nil,
        amountMinor = amount,
        currency = package.currency or self._config.currency,
        issuedAt = issuedAt,
        quotedAt = issuedAt,
        expiresAt = expiresAt,
        servicePackage = { id = package.id, durationMinutes = package.durationMinutes, currency = package.currency or self._config.currency },
        lineItems = lineItems,
        breakdown = lineItems,
        accepted = false
    }
    quote.quoteId = quote.id
    local normalizedQuote, quoteError = PriceQuote.new(quote)
    if not normalizedQuote then return quoteError end
    return Result.ok(normalizedQuote, { serverAuthoritative = true })
end

Service.createQuote = Service.quote
Service.create = Service.quote
Service.getQuote = Service.quote
NightShift.PricingService = Service
NightShift.Services.Pricing = Service
