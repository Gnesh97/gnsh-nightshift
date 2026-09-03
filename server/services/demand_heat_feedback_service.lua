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

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function bounded(value, fallback, minimum, maximum)
    value = value == nil and fallback or tonumber(value)
    if not finite(value) or value < minimum or value > maximum then return nil end
    return value
end

local function clampedInput(value, fallback, minimum, maximum)
    value = value == nil and fallback or tonumber(value)
    if not finite(value) then return nil end
    return math.max(minimum, math.min(maximum, value))
end

local function invalid(message)
    return Result.err(Codes.DEMAND_INVALID, message)
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function resolved(value)
    if type(value) == 'table' and value.ok ~= nil then
        return value.ok == true and value.value or nil
    end
    return value
end

local function callResolver(resolver, request)
    if type(resolver) ~= 'function' then return nil end
    local ok, value = pcall(resolver, copy(request))
    return ok and resolved(value) or nil
end

local function normalizeConfig(raw)
    raw = type(raw) == 'table' and copy(raw) or {}
    local enabled = raw.enabled == nil and true or raw.enabled
    if type(enabled) ~= 'boolean' then return nil, invalid('demand heat feedback enabled flag must be boolean') end
    local threshold = bounded(raw.streetPressureThreshold, 70, 0, 100)
    local streetPenalty = bounded(raw.streetOpportunityPenalty, 0.6, 0, 1)
    local privateImpact = bounded(raw.privateAvailabilityModifier, 0.35, 0, 1)
    local demandWeight = bounded(raw.pricingDemandWeight, 0.2, 0, 1)
    local heatWeight = bounded(raw.pricingHeatWeight, 0.15, 0, 1)
    local supplyPenalty = bounded(raw.pricingOversupplyPenalty, 0.3, 0, 1)
    local minimum = bounded(raw.minMultiplier, 0.25, 0.05, 1)
    local maximum = bounded(raw.maxMultiplier, 1.75, 1, 5)
    if not threshold or not streetPenalty or not privateImpact or not demandWeight or not heatWeight
        or not supplyPenalty or not minimum or not maximum or minimum > maximum then
        return nil, invalid('demand heat feedback bounds are invalid')
    end
    return {
        enabled = enabled,
        streetPressureThreshold = threshold,
        streetOpportunityPenalty = streetPenalty,
        privateAvailabilityModifier = privateImpact,
        pricingDemandWeight = demandWeight,
        pricingHeatWeight = heatWeight,
        pricingOversupplyPenalty = supplyPenalty,
        minMultiplier = minimum,
        maxMultiplier = maximum
    }
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('demand heat feedback options must be a table') end
    local config, errorResult = normalizeConfig(options.config or NightShift.DemandHeatFeedbackConfig)
    if not config then return nil, errorResult end
    if options.enabled ~= nil then
        if type(options.enabled) ~= 'boolean' then return nil, invalid('demand heat feedback enabled override must be boolean') end
        config.enabled = options.enabled
    end
    return setmetatable({
        _config = config,
        _heatService = options.heatService,
        _heatResolver = options.heatResolver,
        _clock = options.clock
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_heat(request)
    local value = request.heat or request.streetPressure or request.heatScore
    if value == nil then value = callResolver(self._heatResolver, request) end
    if value == nil and type(self._heatService) == 'table' then
        local resolver = self._heatService.resolve or self._heatService.get
        if type(resolver) == 'function' then
            local ok, resolvedValue = pcall(resolver, self._heatService, request)
            if ok then value = resolved(resolvedValue) end
        end
    end
    return clampedInput(value, 0, 0, 100)
end

function Service:apply(request)
    if not self:isEnabled() then return Result.err(Codes.DEMAND_UNAVAILABLE, 'demand heat feedback is disabled') end
    if type(request) ~= 'table' then return invalid('demand heat feedback request must be a table') end
    local heat = self:_heat(request)
    local demand = clampedInput(request.demandScore or request.demand or request.score, 50, 0, 100)
    local workers = clampedInput(request.activeWorkers or request.supply, 0, 0, 1000000)
    local capacity = clampedInput(request.supplyCapacity or request.workerCapacity, 1, 1, 1000000)
    if not heat or not demand or not workers or not capacity then return invalid('feedback inputs are invalid') end

    local threshold = self._config.streetPressureThreshold
    local pressure = threshold >= 100 and 0 or clamp((heat - threshold) / math.max(1, 100 - threshold), 0, 1)
    local streetMultiplier = 1 - pressure * self._config.streetOpportunityPenalty
    streetMultiplier = clamp(streetMultiplier, self._config.minMultiplier, 1)
    local privateMultiplier = 1 + (heat / 100) * self._config.privateAvailabilityModifier
    privateMultiplier = clamp(privateMultiplier, self._config.minMultiplier, self._config.maxMultiplier)

    local demandPressure = (demand - 50) / 50
    local oversupply = math.max(0, workers - capacity) / capacity
    local pricing = 1
        + demandPressure * self._config.pricingDemandWeight
        + (heat / 100) * self._config.pricingHeatWeight
        - math.min(1, oversupply) * self._config.pricingOversupplyPenalty
    pricing = clamp(pricing, self._config.minMultiplier, self._config.maxMultiplier)

    local value = {
        heatPressure = heat,
        streetOpportunityMultiplier = streetMultiplier,
        privateBookingAvailabilityModifier = privateMultiplier,
        pricingModifier = pricing,
        inputs = { demandScore = demand, activeWorkers = workers, supplyCapacity = capacity },
        explanation = {
            heatPressure = heat,
            streetPressure = pressure,
            demandPressure = demandPressure,
            oversupply = oversupply,
            clamped = pricing == self._config.minMultiplier or pricing == self._config.maxMultiplier
        }
    }
    if request.streetOpportunity ~= nil then
        local opportunity = bounded(request.streetOpportunity, nil, 0, 100)
        if opportunity == nil then return invalid('street opportunity must be between 0 and 100') end
        value.streetOpportunity = opportunity * streetMultiplier
    end
    return Result.ok(value, { explainable = true, serverAuthoritative = true })
end

Service.evaluate = Service.apply
Service.modifiers = Service.apply

NightShift.DemandHeatFeedbackService = Service
NightShift.Services.DemandHeatFeedback = Service
