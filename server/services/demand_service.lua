NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local dayNames = {
    MONDAY = 1, TUESDAY = 2, WEDNESDAY = 3, THURSDAY = 4,
    FRIDAY = 5, SATURDAY = 6, SUNDAY = 7
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.DEMAND_INVALID, message, details)
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function unwrap(value)
    if type(value) ~= 'table' then return value end
    if value.ok == false then return nil end
    if value.ok == true then return value.value end
    return value
end

local function callResolver(resolver, request, context)
    if type(resolver) ~= 'function' then return nil end
    local ok, value = pcall(resolver, copy(request), copy(context))
    if not ok then return nil end
    return unwrap(value)
end

local function normalizedDay(value)
    if type(value) == 'string' then
        local upper = value:upper()
        if dayNames[upper] then return dayNames[upper] end
        value = tonumber(value)
    end
    value = tonumber(value)
    if value and value == math.floor(value) and value >= 1 and value <= 7 then return value end
    return nil
end

local function currentParts(clock)
    local epoch = os.time()
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then epoch = tonumber(value) end
    end
    local date = os.date('!*t', epoch)
    local day = date.wday == 1 and 7 or date.wday - 1
    return date.hour, day
end

local function normalizeConfig(raw)
    raw = type(raw) == 'table' and copy(raw) or {}
    local enabled = raw.enabled == nil and true or raw.enabled
    if type(enabled) ~= 'boolean' then return nil, invalid('demand enabled flag must be boolean') end
    local minimum = raw.min == nil and 0 or tonumber(raw.min)
    local maximum = raw.max == nil and 100 or tonumber(raw.max)
    if not finite(minimum) or not finite(maximum) or minimum < 0 or maximum > 100 or maximum < minimum then return nil, invalid('demand score bounds are invalid') end
    local function boundedInteger(name, fallback, minimumValue, maximumValue)
        local value = raw[name] == nil and fallback or tonumber(raw[name])
        return integer(value, minimumValue, maximumValue)
    end
    local generationInterval = boundedInteger('generationIntervalSeconds', 60, 0, 86400)
    local cooldown = boundedInteger('candidateCooldownSeconds', 120, 0, 86400)
    local ttl = boundedInteger('opportunityTtlSeconds', 600, 1, 86400)
    local concurrent = boundedInteger('maxConcurrentOpportunities', 3, 1, 1000)
    local activeCustomers = boundedInteger('maxActiveLogicalCustomers', 50, 1, 100000)
    local minimumScore = raw.minimumDemandScore == nil and 1 or tonumber(raw.minimumDemandScore)
    local window = boundedInteger('window', 60, 0, 86400)
    if not generationInterval or not cooldown or not ttl or not concurrent or not activeCustomers or not window or not finite(minimumScore) or minimumScore < 0 or minimumScore > 100 then
        return nil, invalid('demand generation limits are invalid')
    end
    local function impact(name, fallback)
        local value = raw[name] == nil and fallback or tonumber(raw[name])
        if not finite(value) or value < 0 or value > 1 then return nil end
        return value
    end
    local oversupply = impact('oversupplyPenalty', 0.5)
    local activity = impact('recentActivityImpact', 0.15)
    local police = impact('policePressureImpact', 0.2)
    local heat = impact('heatImpact', 0.2)
    if not oversupply or not activity or not police or not heat then return nil, invalid('demand impact settings are invalid') end
    local defaultDistrict = raw.defaultDistrict
    if defaultDistrict ~= nil then
        if not text(defaultDistrict, 64) then return nil, invalid('default district is invalid') end
        defaultDistrict = defaultDistrict:lower()
    end
    return {
        enabled = enabled,
        min = minimum,
        max = maximum,
        window = window,
        generationIntervalSeconds = generationInterval,
        candidateCooldownSeconds = cooldown,
        opportunityTtlSeconds = ttl,
        maxConcurrentOpportunities = concurrent,
        maxActiveLogicalCustomers = activeCustomers,
        minimumDemandScore = minimumScore,
        oversupplyPenalty = oversupply,
        recentActivityImpact = activity,
        policePressureImpact = police,
        heatImpact = heat,
        defaultDistrict = defaultDistrict
    }
end

function Service.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('demand service options must be a table') end
    local districtService = options.districtService or options.districts
    if type(districtService) ~= 'table' or type(districtService.resolve) ~= 'function' then
        return nil, invalid('demand service requires a district service')
    end
    local config, errorResult = normalizeConfig(options.config or NightShift.DemandConfig)
    if not config then return nil, errorResult end
    if options.enabled ~= nil then
        if type(options.enabled) ~= 'boolean' then return nil, invalid('demand enabled override must be boolean') end
        config.enabled = options.enabled
    end
    local clock = options.clock
    if clock == nil and NightShift.Clock and type(NightShift.Clock.new) == 'function' then clock = NightShift.Clock.new() end
    return setmetatable({
        _districts = districtService,
        _config = config,
        _clock = clock,
        _availability = options.availabilityService or options.workerAvailabilityService,
        _resolvers = {
            activeWorkers = options.activeWorkersResolver or options.supplyResolver,
            recentActivity = options.recentActivityResolver or options.activityResolver,
            policePressure = options.policePressureResolver,
            heat = options.heatResolver,
            event = options.eventResolver,
            weather = options.weatherResolver
        }
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_resolveActiveWorkers(request, context)
    if request.activeWorkers ~= nil then return request.activeWorkers end
    local resolved = callResolver(self._resolvers.activeWorkers, request, context)
    if resolved == nil and self._availability and type(self._availability.countAvailable) == 'function' then
        local ok, value = pcall(self._availability.countAvailable, self._availability, { district = context.district.id })
        if ok then resolved = value end
    end
    return resolved == nil and 0 or resolved
end

function Service:_resolveNumber(name, request, context, fallback, minimum, maximum)
    local value = request[name]
    if value == nil then value = callResolver(self._resolvers[name], request, context) end
    value = value == nil and fallback or tonumber(value)
    if not finite(value) or (minimum ~= nil and value < minimum) or (maximum ~= nil and value > maximum) then return nil end
    return value
end

function Service:_resolveModifier(name, request, context)
    local value = request[name .. 'Modifier']
    if value == nil then value = callResolver(self._resolvers[name], request, context) end
    if type(value) == 'table' then value = value.multiplier or value.factor or value.value end
    value = value == nil and 1 or tonumber(value)
    if not finite(value) or value <= 0 or value > 5 then return nil end
    return value
end

function Service:evaluate(request)
    if not self:isEnabled() then return Result.err(Codes.DEMAND_UNAVAILABLE, 'demand engine is disabled') end
    if type(request) ~= 'table' then return invalid('demand request must be a table') end
    local districtRef = request.district or request.districtId or request.district_id
    if districtRef == nil then districtRef = self._config.defaultDistrict end
    local districtResult = self._districts:resolve(districtRef, { zone = request.zone or request.discoveryZone })
    if type(districtResult) ~= 'table' or districtResult.ok ~= true then return districtResult end
    local district = districtResult.value
    local currentHour, currentDay = currentParts(self._clock)
    local hour = request.hour
    if hour == nil and type(request.time) == 'table' then hour = request.time.hour end
    hour = hour == nil and currentHour or tonumber(hour)
    if not integer(hour, 0, 23) then return invalid('demand hour must be an integer from 0 to 23') end
    local day = request.day or request.dayOfWeek
    if day == nil and type(request.time) == 'table' then day = request.time.day end
    day = day == nil and currentDay or normalizedDay(day)
    day = normalizedDay(day)
    if not day then return invalid('demand day must be a weekday or integer from 1 to 7') end
    local context = { district = district, hour = hour, day = day }
    local activeWorkers = self:_resolveActiveWorkers(request, context)
    activeWorkers = integer(activeWorkers, 0, 1000000)
    if activeWorkers == nil then return invalid('active worker count must be a non-negative integer') end
    local capacity = request.workerCapacity or request.supplyCapacity or district.maxActiveCustomers
    capacity = integer(capacity, 1, 1000000)
    if capacity == nil then return invalid('demand supply capacity must be a positive integer') end
    local recentActivity = self:_resolveNumber('recentActivity', request, context, 0, -100, 100)
    local policePressure = self:_resolveNumber('policePressure', request, context, 0, 0, 100)
    local heat = self:_resolveNumber('heat', request, context, 0, 0, 100)
    if recentActivity == nil or policePressure == nil or heat == nil then return invalid('demand pressure input is invalid') end
    local eventModifier = self:_resolveModifier('event', request, context)
    local weatherModifier = self:_resolveModifier('weather', request, context)
    if eventModifier == nil or weatherModifier == nil then return invalid('demand event or weather modifier is invalid') end
    local timeMultiplier = district:timeMultiplier(hour)
    local dayMultiplier = district:dayMultiplier(day)
    local oversupplyRatio = math.max(0, activeWorkers - capacity) / capacity
    local supplyAdjustment = 1 - math.min(1, oversupplyRatio) * self._config.oversupplyPenalty
    local baseline = district.baselineDemand
    local baseScore = baseline * timeMultiplier * dayMultiplier * eventModifier * weatherModifier
    local score = baseScore * supplyAdjustment
        + recentActivity * self._config.recentActivityImpact
        - policePressure * self._config.policePressureImpact
        - heat * self._config.heatImpact
    score = clamp(score, self._config.min, self._config.max)
    local band = score >= 70 and 'HIGH' or score <= 30 and 'LOW' or 'NORMAL'
    local value = {
        score = score,
        demandScore = score,
        band = band,
        demandBand = band,
        district = district.id,
        inputs = {
            activeWorkers = activeWorkers,
            supplyCapacity = capacity,
            hour = hour,
            day = day,
            recentActivity = recentActivity,
            policePressure = policePressure,
            heat = heat
        },
        factors = {
            baseline = baseline,
            timeMultiplier = timeMultiplier,
            dayMultiplier = dayMultiplier,
            eventModifier = eventModifier,
            weatherModifier = weatherModifier,
            supplyAdjustment = supplyAdjustment,
            priceModifier = district.priceModifier,
            riskModifier = district.riskModifier,
            heatModifier = district.heatModifier
        },
        explanation = {
            summary = ('%s demand %s at %d'):format(district.id, band, math.floor(score + 0.5)),
            baseScore = baseScore,
            supplyAdjustment = supplyAdjustment,
            pressureAdjustment = recentActivity * self._config.recentActivityImpact
                - policePressure * self._config.policePressureImpact
                - heat * self._config.heatImpact
        }
    }
    return Result.ok(value, { explainable = true, serverAuthoritative = true })
end

Service.calculate = Service.evaluate
Service.score = Service.evaluate
Service.getDemand = Service.evaluate

function Service:bandFor(score)
    score = tonumber(score)
    if not finite(score) then return nil end
    return score >= 70 and 'HIGH' or score <= 30 and 'LOW' or 'NORMAL'
end

NightShift.DemandService = Service
NightShift.Services.Demand = Service
