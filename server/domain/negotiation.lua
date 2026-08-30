NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Enums = NightShift.Enums

local Negotiation = {}
Negotiation.__index = Negotiation

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

local function currency(value)
    value = type(value) == 'string' and value:upper() or nil
    return value and value:match('^[A-Z][A-Z][A-Z]$') and value or nil
end

local function timestamp(value)
    if value == nil then return nil end
    if finite(value) then return tonumber(value) end
    return text(value, 64) and value or nil
end

local function invalid(message, details)
    return Result.err(Codes.NEGOTIATION_INVALID, message, details)
end

local function normalizePrice(value, field, required)
    if value == nil and not required then return nil end
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a price snapshot') end
    local amount = integer(value.amountMinor or value.amount, 1, 100000000000)
    local code = currency(value.currency)
    if not amount or not code then return nil, invalid(field .. ' is invalid') end
    local output = { amountMinor = amount, currency = code }
    for _, key in ipairs({ 'quoteId', 'negotiationId', 'bookingId' }) do
        if value[key] ~= nil then
            if not token(tostring(value[key]), 160) then return nil, invalid(field .. '.' .. key .. ' is invalid') end
            output[key] = tostring(value[key])
        end
    end
    for _, key in ipairs({ 'quotedAt', 'acceptedAt', 'agreedAt' }) do
        if value[key] ~= nil then
            local normalized = timestamp(value[key])
            if normalized == nil then return nil, invalid(field .. '.' .. key .. ' is invalid') end
            output[key] = normalized
        end
    end
    return output
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('negotiation must be a table') end
    local id = values.id or values.negotiationId or values.key
    local opportunityKey = values.opportunityKey or values.opportunity
    local workerIdentity = values.workerIdentity or values.workerRef
    local customerProfileKey = values.customerProfileKey or values.customerRef
    local servicePackageId = values.servicePackageId or values.packageId
    if not token(tostring(id or ''), 160) then return nil, invalid('negotiation ID is invalid') end
    if not token(tostring(opportunityKey or ''), 200) then return nil, invalid('opportunity key is invalid') end
    if not token(tostring(workerIdentity or ''), 200) then return nil, invalid('worker identity is invalid') end
    if not token(tostring(customerProfileKey or ''), 160) then return nil, invalid('customer profile key is invalid') end
    if not token(tostring(servicePackageId or ''), 96) then return nil, invalid('service package ID is invalid') end
    local state = type(values.status) == 'string' and values.status:upper() or 'OFFERED'
    if not Enums.NegotiationStates[state] then return nil, invalid('negotiation state is invalid') end
    local initial = integer(values.initialOfferMinor or values.initialOffer, 1, 100000000000)
    local current = integer(values.currentOfferMinor or values.currentOffer, 1, 100000000000)
    local floor = integer(values.floorMinor or values.minimumOfferMinor, 1, 100000000000)
    local ceiling = integer(values.ceilingMinor or values.maximumOfferMinor, 1, 100000000000)
    if not initial or not current or not floor or not ceiling or floor > ceiling or initial < floor or initial > ceiling or current < floor or current > ceiling then
        return nil, invalid('negotiation price bounds are invalid')
    end
    local round = integer(values.round or 0, 0, 100)
    local maxRounds = integer(values.maxRounds or 3, 1, 100)
    local patience = integer(values.patience or 100, 0, 100)
    local version = integer(values.version or 1, 1, 2147483647)
    if not round or not maxRounds or not patience or not version or round > maxRounds then return nil, invalid('negotiation counters are invalid') end
    local code = currency(values.currency)
    if not code then return nil, invalid('negotiation currency is invalid') end
    local demandScore
    if values.demandScore ~= nil then demandScore = tonumber(values.demandScore) end
    if demandScore ~= nil and (not finite(demandScore) or demandScore < 0 or demandScore > 100) then return nil, invalid('negotiation demand score is invalid') end
    local demandBand
    if values.demandBand ~= nil then demandBand = tostring(values.demandBand):upper() end
    if demandBand ~= nil and not Enums.DemandBands[demandBand] then return nil, invalid('negotiation demand band is invalid') end
    local budgetClass = values.budgetClass == nil and 3 or integer(values.budgetClass, 1, 5)
    local priceClass = values.priceClass == nil and budgetClass or integer(values.priceClass, 1, 5)
    if not budgetClass or not priceClass then return nil, invalid('negotiation profile classes are invalid') end
    local district, zone
    if values.district ~= nil then district = tostring(values.district):lower() end
    if values.zone ~= nil then zone = tostring(values.zone):lower() end
    if district ~= nil and not token(district, 64) then return nil, invalid('negotiation district is invalid') end
    if zone ~= nil and not token(zone, 64) then return nil, invalid('negotiation zone is invalid') end
    local meetingMode, locationType, locationRef
    if values.meetingMode ~= nil then meetingMode = tostring(values.meetingMode):upper() end
    if values.locationType ~= nil then locationType = tostring(values.locationType):upper() end
    if values.locationRef ~= nil then locationRef = tostring(values.locationRef) end
    if meetingMode ~= nil and not Enums.MeetingModes[meetingMode] then return nil, invalid('negotiation meeting mode is invalid') end
    if locationType ~= nil and not Enums.LocationTypes[locationType] then return nil, invalid('negotiation location type is invalid') end
    if locationRef ~= nil and not token(locationRef, 160) then return nil, invalid('negotiation location reference is invalid') end
    local createdAt = timestamp(values.createdAt)
    local updatedAt = timestamp(values.updatedAt)
    local expiresAt = timestamp(values.expiresAt)
    if values.createdAt ~= nil and createdAt == nil or values.updatedAt ~= nil and updatedAt == nil or values.expiresAt ~= nil and expiresAt == nil then
        return nil, invalid('negotiation timestamp is invalid')
    end
    local acceptedPrice, acceptedError = normalizePrice(values.acceptedPrice, 'acceptedPrice', false)
    if acceptedError then return nil, acceptedError end
    if state == 'ACCEPTED' and not acceptedPrice then return nil, invalid('accepted negotiation requires a frozen price') end
    local lastAction = values.lastAction
    if lastAction ~= nil and not token(tostring(lastAction), 64) then return nil, invalid('negotiation last action is invalid') end
    local reason = values.walkAwayReason or values.reason
    if reason ~= nil and not text(reason, 160) then return nil, invalid('negotiation reason is invalid') end
    return {
        id = tostring(id), negotiationId = tostring(id),
        opportunityKey = tostring(opportunityKey),
        workerIdentity = tostring(workerIdentity), workerRef = tostring(workerIdentity),
        workerSource = integer(values.workerSource or values.source, 1, 65535),
        customerProfileKey = tostring(customerProfileKey), customerRef = tostring(customerProfileKey),
        servicePackageId = tostring(servicePackageId),
        servicePackage = copy(values.servicePackage),
        meetingMode = meetingMode, locationType = locationType, locationRef = locationRef,
        district = district, zone = zone,
        demandScore = demandScore, demandBand = demandBand,
        budgetClass = budgetClass, priceClass = priceClass,
        currency = code,
        initialOfferMinor = initial, currentOfferMinor = current,
        floorMinor = floor, ceilingMinor = ceiling,
        round = round, maxRounds = maxRounds, patience = patience,
        status = state,
        acceptedPrice = acceptedPrice,
        walkAwayReason = reason,
        lastAction = lastAction and tostring(lastAction) or nil,
        createdAt = createdAt, updatedAt = updatedAt, expiresAt = expiresAt,
        version = version
    }
end

function Negotiation.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(normalized, Negotiation)
end

function Negotiation.validate(values)
    local normalized, errorResult = normalize(values)
    return normalized ~= nil, errorResult
end

function Negotiation.copy(value)
    return copy(value)
end

function Negotiation.apply(value, changes)
    if type(value) ~= 'table' or type(changes) ~= 'table' then return nil, invalid('negotiation changes must be tables') end
    local merged = copy(value)
    local allowed = {
        currentOfferMinor = true, floorMinor = true, ceilingMinor = true, round = true,
        patience = true, status = true, acceptedPrice = true, walkAwayReason = true,
        lastAction = true, updatedAt = true, expiresAt = true, version = true
    }
    for key, item in pairs(changes) do
        if not allowed[key] then return nil, invalid('negotiation field is not mutable', { field = tostring(key) }) end
        merged[key] = copy(item)
    end
    return Negotiation.new(merged)
end

function Negotiation:snapshot()
    return copy(self)
end

NightShift.Domain.Negotiation = Negotiation
NightShift.Negotiation = Negotiation
