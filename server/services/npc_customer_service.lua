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

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
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

local function sourceValue(value)
    return integer(value, 1, 65535)
end

local function isActive(opportunity)
    return opportunity and (opportunity.state == 'AVAILABLE' or opportunity.state == 'CLAIMED')
end

local function ownerKey(availability, source)
    if type(availability) == 'table' and text(availability.identityKey, 200) then return availability.identityKey end
    return 'source:' .. tostring(source)
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.NPC_CUSTOMER_INVALID, message, details)
end

local function unwrap(value)
    if type(value) ~= 'table' then return value end
    if value.ok == false then return nil, value end
    if value.ok == true then return value.value, value end
    return value, nil
end

local function normalizeConfig(raw)
    raw = type(raw) == 'table' and copy(raw) or {}
    local enabled = raw.enabled == nil and true or raw.enabled
    if type(enabled) ~= 'boolean' then return nil, invalid('customer generator enabled flag must be boolean') end
    local function setting(name, fallback, minimum, maximum)
        local value = raw[name] == nil and fallback or raw[name]
        value = integer(value, minimum, maximum)
        return value
    end
    local generationInterval = setting('generationIntervalSeconds', 60, 0, 86400)
    local cooldown = setting('candidateCooldownSeconds', 120, 0, 86400)
    local ttl = setting('opportunityTtlSeconds', 600, 1, 86400)
    local concurrent = setting('maxConcurrentOpportunities', 3, 1, 1000)
    local active = setting('maxActiveLogicalCustomers', 50, 1, 100000)
    local minimum = raw.minimumDemandScore == nil and 1 or tonumber(raw.minimumDemandScore)
    if not generationInterval or not cooldown or not ttl or not concurrent or not active or not finite(minimum) or minimum < 0 or minimum > 100 then
        return nil, invalid('customer generator limits are invalid')
    end
    local seed = raw.seed == nil and 'nightshift-customer' or raw.seed
    if not text(seed, 96) then return nil, invalid('customer generator seed is invalid') end
    return {
        enabled = enabled,
        generationIntervalSeconds = generationInterval,
        candidateCooldownSeconds = cooldown,
        opportunityTtlSeconds = ttl,
        maxConcurrentOpportunities = concurrent,
        maxActiveLogicalCustomers = active,
        minimumDemandScore = minimum,
        seed = seed
    }
end

function Service.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('customer generator options must be a table') end
    local districts = options.districtService or options.districts
    local demand = options.demandService or options.demand
    local availability = options.availabilityService or options.workerAvailabilityService
    local generator = options.generator or options.profileGenerator or options.npcProfileGenerator
    if type(districts) ~= 'table' or type(districts.resolve) ~= 'function' then return nil, invalid('customer generator requires a district service') end
    if type(demand) ~= 'table' or type(demand.evaluate) ~= 'function' then return nil, invalid('customer generator requires a demand service') end
    if type(availability) ~= 'table' or (type(availability.get) ~= 'function' and type(availability.isAvailable) ~= 'function') then return nil, invalid('customer generator requires a worker availability service') end
    if type(generator) ~= 'table' or type(generator.generate) ~= 'function' then return nil, invalid('customer generator requires an NPC profile generator') end
    local config, errorResult = normalizeConfig(options.config or NightShift.DemandConfig)
    if not config then return nil, errorResult end
    if options.enabled ~= nil then
        if type(options.enabled) ~= 'boolean' then return nil, invalid('customer generator enabled override must be boolean') end
        config.enabled = options.enabled
    end
    local clock = options.clock
    if clock == nil and NightShift.Clock and type(NightShift.Clock.new) == 'function' then clock = NightShift.Clock.new() end
    local service = setmetatable({
        _districts = districts,
        _demand = demand,
        _availability = availability,
        _generator = generator,
        _config = config,
        _clock = clock,
        _districtResolver = options.districtResolver,
        _zoneResolver = options.zoneResolver or options.discoveryZoneResolver,
        _opportunities = {},
        _sourceKeys = {},
        _lastGenerated = {},
        _sequence = 0
    }, Service)
    if type(availability.onChange) == 'function' then
        pcall(availability.onChange, availability, function(record)
            if type(record) == 'table' and record.state == 'OFFLINE' and text(record.identityKey, 200) then
                service:_expireOwner(record.identityKey, now(service._clock))
            end
        end)
    end
    return service
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_availabilityFor(source)
    if type(self._availability.get) == 'function' then
        local ok, result = pcall(self._availability.get, self._availability, source)
        if ok and type(result) == 'table' then
            if result.ok == true and type(result.value) == 'table' then return result.value end
            if result.ok == nil and result.state ~= nil then return result end
        end
    end
    if type(self._availability.isAvailable) == 'function' then
        local ok, available, result = pcall(self._availability.isAvailable, self._availability, source)
        if ok and available == true then
            local value = type(result) == 'table' and (result.ok == true and result.value or result.ok == nil and result) or {}
            if type(value) ~= 'table' then value = {} end
            value.state = value.state or 'AVAILABLE'
            value.available = true
            return value
        end
    end
    return nil
end

function Service:_districtFor(source, request, availability)
    local districtRef
    if type(self._districtResolver) == 'function' then
        local ok, value = pcall(self._districtResolver, source, copy(request), copy(availability))
        if ok then
            local resolved = unwrap(value)
            if type(resolved) == 'table' then resolved = resolved.id or resolved.district end
            if resolved ~= nil then districtRef = resolved end
        end
    end
    districtRef = districtRef or request.district or request.districtId or request.district_id
    districtRef = districtRef or availability.district or self._districts:defaultId()
    local result = self._districts:resolve(districtRef, { zone = request.zone or request.discoveryZone })
    return result
end

function Service:_zoneFor(source, request, district, availability)
    local zone = request.zone or request.discoveryZone
    if zone == nil and type(self._zoneResolver) == 'function' then
        local ok, value = pcall(self._zoneResolver, source, copy(request), district:copy(), copy(availability))
        if ok then zone = unwrap(value) end
    end
    if zone == nil and #district.allowedZones > 0 then zone = district.allowedZones[1] end
    if zone ~= nil then
        zone = tostring(zone):lower()
        if not district:isZoneAllowed(zone) then return nil, Result.err(Codes.DISTRICT_ZONE_NOT_ALLOWED, 'district does not allow the requested discovery zone', { district = district.id, zone = zone }) end
    end
    return zone
end

function Service:_activeCount(source, identityKey)
    local count = 0
    for _, opportunity in pairs(self._opportunities) do
        if opportunity.source == source and isActive(opportunity)
            and (identityKey == nil or opportunity.identityKey == identityKey) then
            count = count + 1
        end
    end
    return count
end

function Service:_globalActiveCount()
    local count = 0
    for _, opportunity in pairs(self._opportunities) do
        if isActive(opportunity) then count = count + 1 end
    end
    return count
end

function Service:_expire(at)
    local expired = 0
    for key, opportunity in pairs(self._opportunities) do
        if isActive(opportunity) and tonumber(opportunity.expiresAt) and tonumber(opportunity.expiresAt) <= at then
            local nextOpportunity = copy(opportunity)
            nextOpportunity.state = 'EXPIRED'
            nextOpportunity.expiredAt = at
            self._opportunities[key] = nextOpportunity
            expired = expired + 1
        end
    end
    return expired
end

function Service:_expireOwner(identityKey, at)
    local expired = 0
    for key, opportunity in pairs(self._opportunities) do
        if opportunity.identityKey == identityKey and isActive(opportunity) then
            local nextOpportunity = copy(opportunity)
            nextOpportunity.state = 'EXPIRED'
            nextOpportunity.expiredAt = at
            nextOpportunity.expiryReason = 'worker_offline'
            self._opportunities[key] = nextOpportunity
            expired = expired + 1
        end
    end
    return expired
end

function Service:generate(source, request)
    if not self:isEnabled() then return Result.err(Codes.NPC_CUSTOMER_UNAVAILABLE, 'customer generation is disabled') end
    source = sourceValue(source)
    if not source then return invalid('customer generation source must be a positive integer') end
    if request == nil then request = {} end
    if type(request) ~= 'table' then return invalid('customer generation request must be a table') end
    local at = now(self._clock)
    self:_expire(at)
    local availability = self:_availabilityFor(source)
    if type(availability) ~= 'table' or availability.state ~= 'AVAILABLE' or availability.available ~= true then
        return Result.err(Codes.WORKER_AVAILABILITY_DENIED, 'worker must explicitly opt in before receiving customers', { source = source })
    end
    local identityKey = ownerKey(availability, source)
    local districtResult = self:_districtFor(source, request, availability)
    if type(districtResult) ~= 'table' or districtResult.ok ~= true then return districtResult end
    local district = districtResult.value
    local zone, zoneError = self:_zoneFor(source, request, district, availability)
    if zoneError then return zoneError end
    local sourceCount = self:_activeCount(source, identityKey)
    local capacity = math.min(self._config.maxConcurrentOpportunities, district.maxActiveCustomers, self._config.maxActiveLogicalCustomers)
    if sourceCount >= capacity or self:_globalActiveCount() >= self._config.maxActiveLogicalCustomers then
        return Result.err(Codes.NPC_CUSTOMER_CAPACITY, 'customer opportunity capacity has been reached', { source = source, district = district.id, capacity = capacity })
    end
    local last = self._lastGenerated[identityKey]
    local cooldown = math.max(self._config.generationIntervalSeconds, self._config.candidateCooldownSeconds)
    if last ~= nil and at - last < cooldown then
        return Result.err(Codes.NPC_CUSTOMER_COOLDOWN, 'customer generation is cooling down', { source = source, retryAt = last + cooldown, remainingSeconds = cooldown - (at - last) })
    end
    local demandRequest = copy(request)
    demandRequest.district = district.id
    demandRequest.zone = zone
    if demandRequest.activeWorkers == nil and type(self._availability.countAvailable) == 'function' then
        local ok, count = pcall(self._availability.countAvailable, self._availability, { district = district.id })
        if ok then demandRequest.activeWorkers = count end
    end
    local demandResult = self._demand:evaluate(demandRequest)
    if type(demandResult) ~= 'table' or demandResult.ok ~= true then return demandResult end
    local demand = demandResult.value
    if tonumber(demand.score) < self._config.minimumDemandScore then
        return Result.err(Codes.DEMAND_TOO_LOW, 'district demand is below the customer generation threshold', { district = district.id, score = demand.score, minimum = self._config.minimumDemandScore })
    end
    self._sequence = self._sequence + 1
    local seed = ('%s:%s:%d'):format(self._config.seed, source, self._sequence)
    local profileKey = ('npc-customer:%s:%d'):format(source, self._sequence)
    local generated = self._generator:generate({
        role = 'CUSTOMER',
        seed = seed,
        profileKey = profileKey,
        homeDistrict = district.id,
        activeDistrict = district.id,
        availability = 'AVAILABLE'
    })
    if type(generated) ~= 'table' or generated.ok ~= true or type(generated.value) ~= 'table' then
        return Result.err(Codes.NPC_CUSTOMER_GENERATION_FAILED, 'NPC customer profile generation failed', { source = source })
    end
    local opportunityKey = ('customer-opportunity:%s:%d'):format(source, self._sequence)
    local opportunity = {
        opportunityKey = opportunityKey,
        key = opportunityKey,
        source = source,
        identityKey = identityKey,
        state = 'AVAILABLE',
        district = district.id,
        zone = zone,
        customer = copy(generated.value),
        profile = copy(generated.value),
        demand = copy(demand),
        demandScore = demand.score,
        demandBand = demand.band,
        createdAt = at,
        expiresAt = at + self._config.opportunityTtlSeconds,
        physicalCandidate = nil,
        worldTarget = nil
    }
    self._opportunities[opportunityKey] = opportunity
    self._sourceKeys[identityKey] = self._sourceKeys[identityKey] or {}
    self._sourceKeys[identityKey][opportunityKey] = true
    self._lastGenerated[identityKey] = at
    return Result.ok(opportunity, { generated = true, serverAuthoritative = true })
end

function Service:get(opportunityKey)
    if not token(opportunityKey, 200) then return invalid('customer opportunity key is invalid') end
    local opportunity = self._opportunities[opportunityKey]
    if not opportunity then return Result.err(Codes.NPC_CUSTOMER_NOT_FOUND, 'customer opportunity was not found', { opportunityKey = opportunityKey }) end
    if isActive(opportunity) and tonumber(opportunity.expiresAt) and tonumber(opportunity.expiresAt) <= now(self._clock) then self:_expire(now(self._clock)); opportunity = self._opportunities[opportunityKey] end
    return Result.ok(opportunity)
end

function Service:list(source, options)
    source = sourceValue(source)
    if not source then return invalid('customer list source must be a positive integer') end
    if options == nil then options = {} end
    if type(options) ~= 'table' then return invalid('customer list options must be a table') end
    self:_expire(now(self._clock))
    local availability = self:_availabilityFor(source)
    local identityKey = ownerKey(availability, source)
    local output = {}
    for _, opportunity in pairs(self._opportunities) do
        if opportunity.source == source and opportunity.identityKey == identityKey
            and (options.includeExpired == true or opportunity.state == 'AVAILABLE') then
            output[#output + 1] = copy(opportunity)
        end
    end
    table.sort(output, function(left, right) return left.createdAt < right.createdAt end)
    local limit = options.limit == nil and self._config.maxConcurrentOpportunities or integer(options.limit, 1, 100)
    local offset = options.offset == nil and 0 or integer(options.offset, 0, 100000)
    if not limit or not offset then return invalid('customer list pagination is invalid') end
    local paged = {}
    for index = offset + 1, math.min(#output, offset + limit) do paged[#paged + 1] = output[index] end
    return Result.ok({ items = paged, count = #output, limit = limit, offset = offset })
end

function Service:claim(source, opportunityKey)
    source = sourceValue(source)
    if not source or not token(opportunityKey, 200) then return invalid('customer claim request is invalid') end
    local found = self:get(opportunityKey)
    if not found.ok then return found end
    local opportunity = found.value
    local availability = self:_availabilityFor(source)
    if opportunity.source ~= source or opportunity.identityKey ~= ownerKey(availability, source) then
        return Result.err(Codes.NPC_CUSTOMER_INVALID, 'customer opportunity owner mismatch')
    end
    if type(availability) ~= 'table' or availability.state ~= 'AVAILABLE' or availability.available ~= true then
        return Result.err(Codes.WORKER_AVAILABILITY_DENIED, 'worker must be available to claim a customer opportunity')
    end
    if opportunity.state ~= 'AVAILABLE' then return Result.err(Codes.NPC_CUSTOMER_CONFLICT, 'customer opportunity is not available', { state = opportunity.state }) end
    local nextOpportunity = copy(opportunity)
    nextOpportunity.state = 'CLAIMED'
    nextOpportunity.claimedAt = now(self._clock)
    self._opportunities[opportunityKey] = nextOpportunity
    return Result.ok(nextOpportunity)
end

function Service:dismiss(source, opportunityKey, reason)
    source = sourceValue(source)
    if not source or not token(opportunityKey, 200) then return invalid('customer dismissal request is invalid') end
    local found = self:get(opportunityKey)
    if not found.ok then return found end
    local opportunity = found.value
    local availability = self:_availabilityFor(source)
    if opportunity.source ~= source or opportunity.identityKey ~= ownerKey(availability, source) then
        return Result.err(Codes.NPC_CUSTOMER_INVALID, 'customer opportunity owner mismatch')
    end
    if opportunity.state ~= 'AVAILABLE' and opportunity.state ~= 'CLAIMED' then return Result.ok(opportunity, { idempotent = true }) end
    local nextOpportunity = copy(opportunity)
    nextOpportunity.state = 'DISMISSED'
    nextOpportunity.dismissedAt = now(self._clock)
    nextOpportunity.dismissReason = text(reason, 120) and reason or nil
    self._opportunities[opportunityKey] = nextOpportunity
    return Result.ok(nextOpportunity)
end

function Service:expire(at)
    at = finite(at) and tonumber(at) or now(self._clock)
    return Result.ok({ expired = self:_expire(at), at = at })
end

function Service:activeCount(source)
    source = sourceValue(source)
    if not source then return 0 end
    self:_expire(now(self._clock))
    local availability = self:_availabilityFor(source)
    return self:_activeCount(source, ownerKey(availability, source))
end

Service.create = Service.generate
Service.generateCustomer = Service.generate
Service.listCandidates = Service.list
Service.claimOpportunity = Service.claim
Service.dismissOpportunity = Service.dismiss

NightShift.NpcCustomerService = Service
NightShift.Services.NpcCustomer = Service
