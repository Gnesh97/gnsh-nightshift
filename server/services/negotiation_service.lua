NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Negotiation

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    local metatable = getmetatable(value)
    if metatable ~= nil then setmetatable(output, metatable) end
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

local function timestamp(clock, value)
    if value ~= nil then return value end
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, result = pcall(clock.timestamp, clock)
        if ok and text(result, 64) then return result end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, result = pcall(clock.now, clock)
        if ok and finite(result) then return tonumber(result) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.NEGOTIATION_INVALID, message, details)
end

local function actorValue(actor)
    if type(actor) ~= 'table' or not text(actor.ref, 200) then return nil, invalid('negotiation worker actor is required') end
    local kind = type(actor.type) == 'string' and actor.type:upper() or 'PLAYER'
    if kind ~= 'PLAYER' and kind ~= 'SYSTEM' and kind ~= 'ADMIN' then return nil, invalid('negotiation actor type is invalid') end
    local source = integer(actor.source, 1, 65535)
    return { type = kind, ref = actor.ref, source = source }
end

local function normalizeConfig(source)
    source = type(source) == 'table' and copy(source) or {}
    local enabled = source.enabled == nil and true or source.enabled
    local maxRounds = integer(source.maxRounds or source.maximumRounds or 3, 1, 100)
    local expiry = integer(source.expirySeconds or source.ttlSeconds or 300, 1, 86400)
    local minimum = tonumber(source.minimumOfferFactor or source.floorFactor or 0.75)
    local maximum = tonumber(source.maximumOfferFactor or source.ceilingFactor or 1.25)
    local step = tonumber(source.counterStepFactor or 0.05)
    local cost = integer(source.counterPatienceCost or 10, 0, 100)
    if type(enabled) ~= 'boolean' or not maxRounds or not expiry or not finite(minimum) or not finite(maximum) or not finite(step) or not cost then
        return nil, invalid('negotiation configuration is invalid')
    end
    if minimum <= 0 or maximum < minimum or maximum > 10 or step <= 0 or step > 1 then return nil, invalid('negotiation price factors are invalid') end
    local budget = source.budgetMultipliers or {}
    local demand = source.demandMultipliers or {}
    if type(budget) ~= 'table' or type(demand) ~= 'table' then return nil, invalid('negotiation multiplier maps are invalid') end
    local budgetMap, demandMap = {}, {}
    for index = 1, 5 do
        local value = tonumber(budget[index] or budget[tostring(index)] or ({ [1] = 0.90, [2] = 0.95, [3] = 1.00, [4] = 1.10, [5] = 1.20 })[index])
        if not finite(value) or value <= 0 or value > 10 then return nil, invalid('negotiation budget multiplier is invalid', { class = index }) end
        budgetMap[index] = value
    end
    for _, band in ipairs({ 'LOW', 'NORMAL', 'HIGH' }) do
        local value = tonumber(demand[band] or demand[band:lower()] or ({ LOW = 0.95, NORMAL = 1.00, HIGH = 1.10 })[band])
        if not finite(value) or value <= 0 or value > 10 then return nil, invalid('negotiation demand multiplier is invalid', { band = band }) end
        demandMap[band] = value
    end
    return {
        enabled = enabled, maxRounds = maxRounds, expirySeconds = expiry,
        minimumOfferFactor = minimum, maximumOfferFactor = maximum,
        counterStepFactor = step, counterPatienceCost = cost,
        budgetMultipliers = budgetMap, demandMultipliers = demandMap
    }
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function normalizedBand(value)
    value = value == nil and 'NORMAL' or tostring(value):upper()
    return NightShift.Enums.DemandBands[value] and value or nil
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('negotiation service options must be a table') end
    local config, configError = normalizeConfig(options.config or NightShift.NegotiationConfig)
    if not config then return nil, configError end
    local clock = options.clock
    if clock == nil and NightShift.Clock and type(NightShift.Clock.new) == 'function' then clock = NightShift.Clock.new() end
    return setmetatable({
        _config = config, _clock = clock, _negotiations = {}, _idempotency = {}, _sequence = 0,
        _idGenerator = options.idGenerator or options.negotiationIdGenerator
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:configuration()
    return copy(self._config)
end

function Service:_nextId(input, source)
    if text(input.id or input.negotiationId, 160) then return tostring(input.id or input.negotiationId) end
    self._sequence = self._sequence + 1
    if type(self._idGenerator) == 'function' then
        local ok, value = pcall(self._idGenerator, 'negotiation', copy(input), source)
        if ok and token(tostring(value or ''), 160) then return tostring(value) end
    end
    return ('negotiation:%s:%d'):format(tostring(source or 'server'), self._sequence)
end

function Service:_expire(negotiation, at)
    if type(negotiation) ~= 'table' or negotiation.status == 'ACCEPTED' or negotiation.status == 'DECLINED' or negotiation.status == 'WALKED_AWAY' or negotiation.status == 'EXPIRED' then return negotiation end
    local expiry = tonumber(negotiation.expiresAt)
    if expiry and expiry <= at then
        local nextValue = Domain.apply(negotiation, { status = 'EXPIRED', lastAction = 'expired', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
        if nextValue and nextValue.ok == nil then
            self._negotiations[negotiation.id] = nextValue
            return nextValue
        end
    end
    return negotiation
end

function Service:_find(id)
    if not token(tostring(id or ''), 160) then return nil, invalid('negotiation ID is invalid') end
    local value = self._negotiations[tostring(id)]
    if not value then return nil, Result.err(Codes.NEGOTIATION_NOT_FOUND, 'negotiation was not found', { id = id }) end
    value = self:_expire(value, now(self._clock))
    self._negotiations[tostring(id)] = value
    return value
end

function Service:_owned(actor, negotiation)
    if actor.type == 'SYSTEM' or actor.type == 'ADMIN' then return true end
    return negotiation.workerIdentity == actor.ref and negotiation.workerSource == nil or negotiation.workerIdentity == actor.ref and negotiation.workerSource == actor.source
end

function Service:_expected(negotiation, expected)
    if expected == nil then return true end
    expected = integer(expected, 1)
    if not expected then return nil, invalid('expected negotiation version is invalid') end
    if expected ~= negotiation.version then
        return nil, Result.err(Codes.VERSION_CONFLICT, 'negotiation version does not match', { id = negotiation.id, expectedVersion = expected, actualVersion = negotiation.version })
    end
    return true
end

function Service:createOffer(actor, input)
    if not self:isEnabled() then return Result.err(Codes.NEGOTIATION_INVALID, 'negotiation is disabled') end
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    if type(input) ~= 'table' then return invalid('negotiation offer input must be a table') end
    local idempotencyKey = input.idempotencyKey
    if idempotencyKey ~= nil and not token(tostring(idempotencyKey), 200) then return invalid('negotiation idempotency key is invalid') end
    if idempotencyKey and self._idempotency[tostring(idempotencyKey)] then
        local existing = self._idempotency[tostring(idempotencyKey)]
        if not self:_owned(owner, existing) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation idempotency key belongs to another worker') end
        return Result.ok(copy(existing), { idempotent = true })
    end
    local id = self:_nextId(input, owner.source)
    local existing = self._negotiations[id]
    if existing then
        if not self:_owned(owner, existing) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation ID belongs to another worker') end
        return Result.ok(copy(existing), { idempotent = true })
    end
    local package = type(input.servicePackage) == 'table' and input.servicePackage or {}
    local base = integer(input.basePriceMinor or input.basePrice or package.priceMinor or package.basePriceMinor, 1, 100000000000)
    if not base then return invalid('negotiation base price is invalid') end
    local code = type(input.currency or package.currency) == 'string' and tostring(input.currency or package.currency):upper() or 'USD'
    if code:match('^[A-Z][A-Z][A-Z]$') == nil then return invalid('negotiation currency is invalid') end
    local budgetClass = integer(input.budgetClass or (type(input.profile) == 'table' and input.profile.budgetClass) or 3, 1, 5)
    local priceClass = integer(input.priceClass or (type(input.profile) == 'table' and input.profile.priceClass) or budgetClass, 1, 5)
    if not budgetClass or not priceClass then return invalid('negotiation profile class is invalid') end
    local demandBandInput = input.demandBand
    if demandBandInput == nil and type(input.demand) == 'table' then demandBandInput = input.demand.band end
    local band = normalizedBand(demandBandInput)
    if not band then return invalid('negotiation demand band is invalid') end
    local score = input.demandScore or (type(input.demand) == 'table' and input.demand.score)
    score = score == nil and nil or tonumber(score)
    if score ~= nil and (not finite(score) or score < 0 or score > 100) then return invalid('negotiation demand score is invalid') end
    local floor = math.max(1, math.floor(base * self._config.minimumOfferFactor + 0.5))
    local ceiling = math.max(floor, math.floor(base * self._config.maximumOfferFactor + 0.5))
    local target = math.floor(base * self._config.budgetMultipliers[budgetClass] * self._config.demandMultipliers[band] + 0.5)
    local initial = clamp(target, floor, ceiling)
    local profile = input.profile or {}
    local patience = integer(input.patience or (type(profile) == 'table' and type(profile.traits) == 'table' and profile.traits.patience) or 100, 0, 100)
    if not patience then return invalid('negotiation patience is invalid') end
    local at = now(self._clock)
    local expiry = input.expiresAt or at + self._config.expirySeconds
    local value, valueError = Domain.new({
        id = id, opportunityKey = input.opportunityKey, workerIdentity = owner.ref, workerSource = owner.source,
        customerProfileKey = input.customerProfileKey or input.customerRef, servicePackageId = input.servicePackageId or package.id,
        servicePackage = package, meetingMode = input.meetingMode, locationType = input.locationType, locationRef = input.locationRef,
        district = input.district, zone = input.zone, demandScore = score, demandBand = band,
        budgetClass = budgetClass, priceClass = priceClass, currency = code,
        initialOfferMinor = initial, currentOfferMinor = initial, floorMinor = floor, ceilingMinor = ceiling,
        round = 0, maxRounds = self._config.maxRounds, patience = patience,
        status = 'OFFERED', createdAt = at, updatedAt = at, expiresAt = expiry, version = 1
    })
    if not value then return valueError end
    self._negotiations[id] = value
    if idempotencyKey then self._idempotency[tostring(idempotencyKey)] = value end
    return Result.ok(value, { created = true, serverAuthoritative = true })
end

function Service:counter(actor, id, amount, expected)
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    local negotiation, findError = self:_find(id)
    if not negotiation then return findError end
    if not self:_owned(owner, negotiation) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation belongs to another worker') end
    if negotiation.status == 'EXPIRED' then return Result.err(Codes.NEGOTIATION_EXPIRED, 'negotiation has expired') end
    if negotiation.status ~= 'OFFERED' and negotiation.status ~= 'COUNTERED' then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation is no longer open', { status = negotiation.status }) end
    local expectedOk, expectedError = self:_expected(negotiation, expected)
    if not expectedOk then return expectedError end
    amount = integer(amount, 1, 100000000000)
    if not amount or amount < negotiation.floorMinor or amount > negotiation.ceilingMinor then
        return Result.err(Codes.NEGOTIATION_COUNTER_INVALID, 'counter must stay within the server offer bounds', { floorMinor = negotiation.floorMinor, ceilingMinor = negotiation.ceilingMinor })
    end
    local nextRound = negotiation.round + 1
    if nextRound > negotiation.maxRounds then
        local walked = Domain.apply(negotiation, { status = 'WALKED_AWAY', walkAwayReason = 'round-limit', lastAction = 'walk-away', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
        if walked and walked.ok == nil then self._negotiations[negotiation.id] = walked end
        return Result.err(Codes.NEGOTIATION_ROUND_LIMIT, 'negotiation round limit was reached', { id = negotiation.id })
    end
    if amount >= negotiation.currentOfferMinor then
        local accepted = Domain.apply(negotiation, {
            status = 'ACCEPTED', round = nextRound, currentOfferMinor = amount,
            acceptedPrice = { amountMinor = amount, currency = negotiation.currency, negotiationId = negotiation.id, acceptedAt = timestamp(self._clock) },
            lastAction = 'customer-accepted-counter', updatedAt = timestamp(self._clock), version = negotiation.version + 1
        })
        if not accepted or accepted.ok ~= nil then return accepted or Result.err(Codes.NEGOTIATION_INVALID, 'accepted negotiation could not be normalized') end
        self._negotiations[negotiation.id] = accepted
        return Result.ok(accepted, { accepted = true, serverAuthoritative = true })
    end
    local step = math.max(1, math.floor(negotiation.ceilingMinor * self._config.counterStepFactor + 0.5))
    local response = clamp(amount + step, negotiation.floorMinor, negotiation.currentOfferMinor)
    local patience = math.max(0, negotiation.patience - self._config.counterPatienceCost)
    if patience <= 0 and response > amount then
        local walked = Domain.apply(negotiation, { status = 'WALKED_AWAY', round = nextRound, patience = 0, walkAwayReason = 'patience-exhausted', lastAction = 'walk-away', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
        if walked and walked.ok == nil then self._negotiations[negotiation.id] = walked end
        return Result.err(Codes.NEGOTIATION_WALKED_AWAY, 'customer patience was exhausted')
    end
    local countered = Domain.apply(negotiation, { status = 'COUNTERED', round = nextRound, currentOfferMinor = response, patience = patience, lastAction = 'customer-countered', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
    if not countered or countered.ok ~= nil then return countered or Result.err(Codes.NEGOTIATION_INVALID, 'counter response could not be normalized') end
    self._negotiations[negotiation.id] = countered
    return Result.ok(countered, { countered = true, serverAuthoritative = true })
end

function Service:accept(actor, id, expected)
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    local negotiation, findError = self:_find(id)
    if not negotiation then return findError end
    if not self:_owned(owner, negotiation) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation belongs to another worker') end
    if negotiation.status == 'EXPIRED' then return Result.err(Codes.NEGOTIATION_EXPIRED, 'negotiation has expired') end
    if negotiation.status ~= 'OFFERED' and negotiation.status ~= 'COUNTERED' then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation is no longer open') end
    local expectedOk, expectedError = self:_expected(negotiation, expected)
    if not expectedOk then return expectedError end
    local accepted = Domain.apply(negotiation, {
        status = 'ACCEPTED', acceptedPrice = { amountMinor = negotiation.currentOfferMinor, currency = negotiation.currency, negotiationId = negotiation.id, acceptedAt = timestamp(self._clock) },
        lastAction = 'worker-accepted-offer', updatedAt = timestamp(self._clock), version = negotiation.version + 1
    })
    if not accepted or accepted.ok ~= nil then return accepted or Result.err(Codes.NEGOTIATION_INVALID, 'negotiation acceptance could not be normalized') end
    self._negotiations[negotiation.id] = accepted
    return Result.ok(accepted, { accepted = true, serverAuthoritative = true })
end

function Service:decline(actor, id, expected, reason)
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    local negotiation, findError = self:_find(id)
    if not negotiation then return findError end
    if not self:_owned(owner, negotiation) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation belongs to another worker') end
    if negotiation.status ~= 'OFFERED' and negotiation.status ~= 'COUNTERED' then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation is no longer open') end
    local expectedOk, expectedError = self:_expected(negotiation, expected)
    if not expectedOk then return expectedError end
    reason = text(reason, 160) and reason or 'worker-declined'
    local declined = Domain.apply(negotiation, { status = 'DECLINED', walkAwayReason = reason, lastAction = 'worker-declined', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
    if not declined or declined.ok ~= nil then return declined or Result.err(Codes.NEGOTIATION_INVALID, 'negotiation decline could not be normalized') end
    self._negotiations[negotiation.id] = declined
    return Result.ok(declined)
end

function Service:walkAway(actor, id, expected, reason)
    local owner, ownerError = actorValue(actor)
    if not owner then return ownerError end
    local negotiation, findError = self:_find(id)
    if not negotiation then return findError end
    if not self:_owned(owner, negotiation) then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation belongs to another worker') end
    if negotiation.status ~= 'OFFERED' and negotiation.status ~= 'COUNTERED' then return Result.err(Codes.NEGOTIATION_CONFLICT, 'negotiation is no longer open') end
    local expectedOk, expectedError = self:_expected(negotiation, expected)
    if not expectedOk then return expectedError end
    local walked = Domain.apply(negotiation, { status = 'WALKED_AWAY', walkAwayReason = text(reason, 160) and reason or 'worker-walked-away', lastAction = 'walk-away', updatedAt = timestamp(self._clock), version = negotiation.version + 1 })
    if not walked or walked.ok ~= nil then return walked or Result.err(Codes.NEGOTIATION_INVALID, 'negotiation walk-away could not be normalized') end
    self._negotiations[negotiation.id] = walked
    return Result.ok(walked)
end

function Service:get(id)
    local value, errorResult = self:_find(id)
    if not value then return errorResult end
    return Result.ok(value)
end

function Service:list(actor)
    local owner, ownerError
    if actor ~= nil then
        owner, ownerError = actorValue(actor)
        if not owner then return ownerError end
    end
    local output = {}
    for _, value in pairs(self._negotiations) do
        value = self:_expire(value, now(self._clock))
        if not owner or self:_owned(owner, value) then output[#output + 1] = copy(value) end
    end
    table.sort(output, function(left, right) return left.createdAt < right.createdAt end)
    return Result.ok(output, { count = #output })
end

Service.start = Service.createOffer
Service.offer = Service.createOffer
Service.counterOffer = Service.counter
Service.acceptOffer = Service.accept
Service.declineOffer = Service.decline

NightShift.NegotiationService = Service
NightShift.Services.Negotiation = Service
