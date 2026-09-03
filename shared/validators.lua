NightShift = NightShift or {}
NightShift.Validators = NightShift.Validators or {}
local V = NightShift.Validators
local function copy(v, seen) if type(v) ~= 'table' then return v end; seen=seen or {}; if seen[v] then return seen[v] end; local r={}; seen[v]=r; for k,x in pairs(v) do r[copy(k,seen)]=copy(x,seen) end; return r end
local function fail(c,p,m) local e=NightShift.Errors.create(c,m,{path=p,field=p}); e.path,e.field=p,p; return nil,e end
local function text(v) return type(v)=='string' and v:match('%S')~=nil end
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function positive(v) return finite(v) and v>0 end
local function integer(v) return positive(v) and math.floor(v)==v end
local function array(a,p,label)
    if type(a)~='table' then return fail('INVALID_CONFIG',p,label..' must be an array') end
    local count=0; for k in pairs(a) do if type(k)~='number' or k<1 or math.floor(k)~=k then return fail('INVALID_CONFIG',p,label..' must be contiguous') end; count=count+1 end
    for i=1,count do if rawget(a,i)==nil then return fail('INVALID_CONFIG',p,label..' must be contiguous') end end
    return true
end
local function ids(a,p,label)
    local ok,e=array(a,p,label); if not ok then return nil,e end; local r,s={},{}
    for i,x in ipairs(a) do if type(x)~='table' or not text(x.id) then return fail('INVALID_CONFIG',p..'['..i..'].id',label..' IDs must be non-empty') end; if s[x.id] then return fail('DUPLICATE_ID',p..'['..i..'].id','duplicate '..label..' ID') end; s[x.id]=true; r[i]=copy(x) end
    return r,s
end

local locationTypes = NightShift.Enums and NightShift.Enums.LocationTypes or {}
local meetingModes = NightShift.Enums and NightShift.Enums.MeetingModes or {}
local locationCategories = { configured=true, housing=true, motel=true, venue=true, vehicle=true, roadside=true, custom=true }
local booleanValue

local function token(value, maximum)
    return type(value) == 'string' and #value <= (maximum or 160) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function normalizeLocation(raw, path)
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', path, 'location must be a table') end
    local allowed = {
        id=true, locationRef=true, ref=true, key=true, locationType=true, type=true,
        category=true, provider=true, worldTarget=true, world_target=true,
        accessRequirements=true, access_requirements=true, meetingModes=true,
        allowedMeetingModes=true, allowed_meeting_modes=true, maxTravelDistance=true,
        max_travel_distance=true, blockedTags=true, blocked_tags=true, available=true,
        reservable=true, version=true, recordId=true, record_id=true, idNumber=true,
        createdAt=true, created_at=true, updatedAt=true, updated_at=true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'location field is not allowlisted') end
    end
    local id = raw.id or raw.locationRef or raw.ref or raw.key
    if not token(id, 160) then return fail('LOCATION_INVALID', path .. '.id', 'location reference is invalid') end
    local kind = raw.locationType or raw.type
    kind = kind == nil and 'CONFIG_LOCATION' or tostring(kind):upper()
    if not locationTypes[kind] then return fail('LOCATION_INVALID', path .. '.type', 'location type is not supported') end
    local category = raw.category
    category = category == nil and ({
        PROPERTY = 'housing', MOTEL_ROOM = 'motel', HOTEL_ROOM = 'motel',
        VENUE_ROOM = 'venue', VEHICLE = 'vehicle', SAFE_ROADSIDE = 'roadside',
        CUSTOM_PROVIDER = 'custom'
    })[kind] or category
    category = category == nil and 'configured' or tostring(category):lower()
    if not locationCategories[category] then return fail('INVALID_CONFIG', path .. '.category', 'location category is invalid') end
    local output = copy(raw)
    output.id, output.locationRef, output.type, output.locationType, output.category = id, id, kind, kind, category
    local target = raw.worldTarget or raw.world_target
    if target ~= nil then
        if type(target) ~= 'table' then return fail('LOCATION_TARGET_INVALID', path .. '.worldTarget', 'world target must be a table') end
        local targetKind = target.kind or target.type or 'coords'
        targetKind = tostring(targetKind):lower()
        if targetKind ~= 'coords' and targetKind ~= 'provider' then return fail('LOCATION_TARGET_INVALID', path .. '.worldTarget.kind', 'world target kind is invalid') end
        local normalizedTarget = { kind = targetKind }
        if targetKind == 'coords' then
            for _, axis in ipairs({ 'x', 'y', 'z' }) do
                local limit = axis == 'z' and 10000 or 100000
                if not finite(target[axis]) or math.abs(target[axis]) > limit then return fail('LOCATION_TARGET_INVALID', path .. '.worldTarget.' .. axis, 'world target coordinate is outside safe bounds') end
                normalizedTarget[axis] = target[axis]
            end
            if target.heading ~= nil then
                if not finite(target.heading) or math.abs(target.heading) > 360 then return fail('LOCATION_TARGET_INVALID', path .. '.worldTarget.heading', 'world target heading is invalid') end
                normalizedTarget.heading = target.heading
            end
        elseif target.provider ~= nil then
            if not token(target.provider, 64) then return fail('LOCATION_TARGET_INVALID', path .. '.worldTarget.provider', 'world target provider is invalid') end
            normalizedTarget.provider = target.provider
        end
        output.worldTarget, output.world_target = normalizedTarget, copy(normalizedTarget)
    end
    local modes = raw.meetingModes or raw.allowedMeetingModes or raw.allowed_meeting_modes or {}
    local modeOk, modeError = array(modes, path .. '.meetingModes', 'meeting modes')
    if not modeOk then return nil, modeError end
    local normalizedModes, seenModes = {}, {}
    for index, mode in ipairs(modes) do
        local normalizedMode = type(mode) == 'string' and mode:upper() or nil
        if not normalizedMode or not meetingModes[normalizedMode] or seenModes[normalizedMode] then
            return fail('INVALID_CONFIG', path .. '.meetingModes[' .. index .. ']', 'meeting mode is invalid or duplicated')
        end
        seenModes[normalizedMode] = true
        normalizedModes[index] = normalizedMode
    end
    output.meetingModes, output.allowedMeetingModes = normalizedModes, copy(normalizedModes)
    local requirements = raw.accessRequirements or raw.access_requirements or {}
    if type(requirements) ~= 'table' then return fail('LOCATION_INVALID', path .. '.accessRequirements', 'access requirements must be a table') end
    local normalizedRequirements = {}
    local allowedRequirements = { public=true, owner=true, permission=true, ace=true, minGrade=true, min_grade=true }
    for key, value in pairs(requirements) do
        if not allowedRequirements[key] then return fail('LOCATION_INVALID', path .. '.accessRequirements.' .. tostring(key), 'access requirement is not allowlisted') end
        if key == 'public' or key == 'owner' then
            if type(value) ~= 'boolean' then return fail('LOCATION_INVALID', path .. '.accessRequirements.' .. tostring(key), 'access requirement must be boolean') end
        elseif key == 'minGrade' or key == 'min_grade' then
            if not finite(value) or value < 0 or value ~= math.floor(value) then return fail('LOCATION_INVALID', path .. '.accessRequirements.' .. tostring(key), 'minimum grade must be a non-negative integer') end
        elseif not token(value, 96) then
            return fail('LOCATION_INVALID', path .. '.accessRequirements.' .. tostring(key), 'access requirement value is invalid')
        end
        normalizedRequirements[key == 'min_grade' and 'minGrade' or key] = value
    end
    output.accessRequirements, output.access_requirements = normalizedRequirements, copy(normalizedRequirements)
    local maxDistance = raw.maxTravelDistance or raw.max_travel_distance
    if maxDistance ~= nil and (not finite(maxDistance) or maxDistance <= 0 or maxDistance > 100000) then
        return fail('LOCATION_INVALID', path .. '.maxTravelDistance', 'maximum travel distance is invalid')
    end
    output.maxTravelDistance = maxDistance
    local tags = raw.blockedTags or raw.blocked_tags or {}
    local tagsOk, tagsError = array(tags, path .. '.blockedTags', 'blocked tags')
    if not tagsOk then return nil, tagsError end
    local normalizedTags, seenTags = {}, {}
    for index, tag in ipairs(tags) do
        local normalizedTag = type(tag) == 'string' and tag:upper() or nil
        if not normalizedTag or not token(normalizedTag, 64) or seenTags[normalizedTag] then return fail('LOCATION_INVALID', path .. '.blockedTags[' .. index .. ']', 'blocked tag is invalid or duplicated') end
        seenTags[normalizedTag] = true
        normalizedTags[index] = normalizedTag
    end
    output.blockedTags = normalizedTags
    local available, availableError = booleanValue(raw.available, path .. '.available', true)
    if available == nil then return nil, availableError end
    local reservable, reservableError = booleanValue(raw.reservable, path .. '.reservable', true)
    if reservable == nil then return nil, reservableError end
    output.available, output.reservable = available, reservable
    if raw.provider ~= nil and not token(raw.provider, 64) then return fail('LOCATION_INVALID', path .. '.provider', 'location provider is invalid') end
    return output
end

local function validateLocations(raw)
    if raw == nil then raw = NightShift.LocationConfig end
    if raw == nil then raw = {} end
    local normalized, seen = {}, {}
    local ok, arrayError = array(raw, 'locations', 'locations')
    if not ok then return nil, arrayError end
    for index, location in ipairs(raw) do
        local value, valueError = normalizeLocation(location, 'locations[' .. index .. ']')
        if not value then return nil, valueError end
        if seen[value.id] then return fail('DUPLICATE_ID', 'locations[' .. index .. '].id', 'duplicate location ID') end
        seen[value.id] = true
        normalized[index] = value
    end
    return normalized, seen
end

local function currency(value, path, fallback)
    value = value == nil and fallback or value
    if type(value) ~= 'string' then return fail('INVALID_CONFIG', path, 'currency must be a three-letter code') end
    value = value:upper()
    if value:match('^[A-Z][A-Z][A-Z]$') == nil then return fail('INVALID_CONFIG', path, 'currency must be a three-letter code') end
    return value
end

booleanValue = function(value, path, fallback)
    value = value == nil and fallback or value
    if type(value) ~= 'boolean' then return fail('INVALID_CONFIG', path, 'value must be boolean') end
    return value
end

local function numericMap(value, path, default)
    if value == nil then value = default or {} end
    if type(value) ~= 'table' then return fail('INVALID_CONFIG', path, 'modifier map must be a table') end
    local output = {}
    for key, item in pairs(value) do
        if not text(key) or not finite(item) or item <= 0 or item > 100 then
            return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'modifier must be a finite positive number')
        end
        output[tostring(key):upper()] = item
    end
    return output
end

local function validateServiceCatalog(raw, locations)
    if raw == nil then raw = NightShift.ServiceCatalogConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'serviceCatalog', 'service catalog must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'serviceCatalog.enabled', true)
    if enabled == nil then return nil, enabledError end
    local code, codeError = currency(raw.currency, 'serviceCatalog.currency', 'USD')
    if not code then return nil, codeError end
    local packages = raw.packages or raw.servicePackages
    if packages == nil then packages = {} end
    local normalized, packageIds = ids(packages, 'serviceCatalog.packages', 'service package')
    if not normalized then return nil, packageIds end
    if #normalized == 0 and enabled then return fail('INVALID_CONFIG', 'serviceCatalog.packages', 'service catalog requires at least one package') end
    local locationIds = {}
    for _, location in ipairs(locations or {}) do locationIds[location.id] = true end
    local normalizedIds = {}
    for index, package in ipairs(normalized) do
        local normalizedId = tostring(package.id):lower()
        if normalizedIds[normalizedId] then return fail('DUPLICATE_ID', 'serviceCatalog.packages[' .. index .. '].id', 'duplicate service package ID') end
        normalizedIds[normalizedId] = true
        local price = package.basePriceMinor
        if price == nil then price = package.basePrice end
        if price == nil then price = package.priceMinor end
        if price == nil then price = package.price end
        if not integer(price) then return fail('INVALID_PRICE', 'serviceCatalog.packages[' .. index .. '].basePriceMinor', 'base price must be a positive integer in minor units') end
        package.basePriceMinor = price
        local duration = package.durationMinutes or package.duration
        if not integer(duration) then return fail('INVALID_DURATION', 'serviceCatalog.packages[' .. index .. '].durationMinutes', 'duration must be a positive integer') end
        package.durationMinutes = duration
        local minimum = package.minClientReputation or package.minReputation or package.reputationRequired or 0
        if not finite(minimum) or minimum < 0 or minimum > 1000000 then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].minClientReputation', 'reputation requirement is invalid') end
        package.minClientReputation = minimum
        local modes = package.meetingModes or package.modes
        if modes ~= nil then
            local modeOk, modeError = array(modes, 'serviceCatalog.packages[' .. index .. '].meetingModes')
            if not modeOk then return nil, modeError end
            local seenModes = {}
            for modeIndex, mode in ipairs(modes) do
                if not text(mode) or not mode:match('^[A-Za-z][A-Za-z0-9_%-]*$') then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].meetingModes[' .. modeIndex .. ']', 'meeting mode is invalid') end
                local normalizedMode = mode:upper()
                if seenModes[normalizedMode] then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].meetingModes', 'meeting modes must be unique') end
                seenModes[normalizedMode] = true
            end
            package.meetingModes = copy(modes)
        end
        local refs = package.locationIds or package.locations
        if refs ~= nil then
            local refsOk, refsError = array(refs, 'serviceCatalog.packages[' .. index .. '].locationIds')
            if not refsOk then return nil, refsError end
            local seenRefs = {}
            for refIndex, ref in ipairs(refs) do
                if not text(ref) or seenRefs[ref] then return fail('INVALID_LOCATION_REFERENCE', 'serviceCatalog.packages[' .. index .. '].locationIds[' .. refIndex .. ']', 'location reference must be unique and non-empty') end
                if next(locationIds) ~= nil and not locationIds[ref] then return fail('INVALID_LOCATION_REFERENCE', 'serviceCatalog.packages[' .. index .. '].locationIds[' .. refIndex .. ']', 'location reference is not allowlisted') end
                seenRefs[ref] = true
            end
            package.locationIds = copy(refs)
        end
        local categories = package.locationCategories or package.categories
        if categories ~= nil then
            local categoryOk, categoryError = array(categories, 'serviceCatalog.packages[' .. index .. '].locationCategories')
            if not categoryOk then return nil, categoryError end
            package.locationCategories = copy(categories)
        end
        if package.currency ~= nil then
            local packageCurrency, packageCurrencyError = currency(package.currency, 'serviceCatalog.packages[' .. index .. '].currency', code)
            if not packageCurrency then return nil, packageCurrencyError end
            package.currency = packageCurrency
        end
    end
    output.enabled, output.currency, output.packages = enabled, code, normalized
    output.servicePackages = copy(normalized)
    return output
end

local function validatePricing(raw)
    if raw == nil then raw = NightShift.PricingConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'pricing', 'pricing must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'pricing.enabled', true)
    if enabled == nil then return nil, enabledError end
    local code, codeError = currency(raw.currency, 'pricing.currency', 'USD')
    if not code then return nil, codeError end
    local ttl = raw.quoteTtlSeconds == nil and 300 or raw.quoteTtlSeconds
    if not integer(ttl) or ttl > 86400 then return fail('INVALID_CONFIG', 'pricing.quoteTtlSeconds', 'quote TTL must be a positive integer no greater than one day') end
    local minimum = raw.minAmountMinor == nil and 1 or raw.minAmountMinor
    local maximum = raw.maxAmountMinor == nil and 100000000000 or raw.maxAmountMinor
    if not integer(minimum) or not integer(maximum) or minimum > maximum then return fail('INVALID_CONFIG', 'pricing', 'pricing bounds are invalid') end
    local npc, npcError = numericMap(raw.npcPriceClasses or raw.npcModifiers, 'pricing.npcPriceClasses')
    if not npc then return nil, npcError end
    local district, districtError = numericMap(raw.districtModifiers, 'pricing.districtModifiers')
    if not district then return nil, districtError end
    local time, timeError = numericMap(raw.timeModifiers, 'pricing.timeModifiers')
    if not time then return nil, timeError end
    local demand, demandError = numericMap(raw.demandModifiers, 'pricing.demandModifiers')
    if not demand then return nil, demandError end
    local reputation, reputationError = numericMap(raw.reputationModifiers, 'pricing.reputationModifiers')
    if not reputation then return nil, reputationError end
    local fees = raw.fees == nil and {} or raw.fees
    if type(fees) ~= 'table' then return fail('INVALID_CONFIG', 'pricing.fees', 'pricing fees must be a table') end
    local travel = fees.travelMinor or fees.travel or 0
    local location = fees.locationMinor or fees.location or 0
    if not finite(travel) or travel < 0 or math.floor(travel) ~= travel or not finite(location) or location < 0 or math.floor(location) ~= location then return fail('INVALID_CONFIG', 'pricing.fees', 'pricing fees must be non-negative integers') end
    output.enabled, output.currency, output.quoteTtlSeconds = enabled, code, ttl
    output.minAmountMinor, output.maxAmountMinor = minimum, maximum
    output.npcPriceClasses, output.districtModifiers, output.timeModifiers = npc, district, time
    output.demandModifiers, output.reputationModifiers = demand, reputation
    output.fees = { travelMinor = travel, locationMinor = location }
    return output
end

local function validateCancellation(raw)
    if raw == nil then raw = NightShift.CancellationConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'cancellation', 'cancellation must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'cancellation.enabled', true)
    if enabled == nil then return nil, enabledError end
    if raw.account ~= nil and not text(raw.account) then return fail('INVALID_CONFIG', 'cancellation.account', 'cancellation account is invalid') end
    local percentages = raw.percentages or raw.refundPercentages or {}
    if type(percentages) ~= 'table' then return fail('INVALID_CONFIG', 'cancellation.percentages', 'cancellation percentages must be a table') end
    local normalized = {}
    for status, percentage in pairs(percentages) do
        if not text(status) or not finite(percentage) or percentage < 0 or percentage > 100 then return fail('INVALID_CONFIG', 'cancellation.percentages.' .. tostring(status), 'refund percentage must be between zero and one hundred') end
        normalized[tostring(status):upper()] = percentage
    end
    output.enabled, output.account, output.percentages = enabled, raw.account or 'cash', normalized
    return output
end

local districtDays = {
    MONDAY = 1, TUESDAY = 2, WEDNESDAY = 3, THURSDAY = 4,
    FRIDAY = 5, SATURDAY = 6, SUNDAY = 7
}

local function districtToken(value)
    return type(value) == 'string' and #value <= 64 and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function normalizeDemandCurve(raw, path, kind)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', path, 'demand curve must be a table') end
    local output = {}
    local array24 = kind == 'time' and #raw == 24
    for key, value in pairs(raw) do
        local normalizedKey
        if kind == 'time' then
            normalizedKey = tonumber(key)
            if array24 then normalizedKey = tonumber(key) - 1 end
            if not normalizedKey or normalizedKey ~= math.floor(normalizedKey) or normalizedKey < 0 or normalizedKey > 23 then
                return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'time curve hour must be an integer from 0 to 23')
            end
        else
            if type(key) == 'number' then
                normalizedKey = key
            elseif type(key) == 'string' then
                normalizedKey = districtDays[key:upper()]
            end
            if not normalizedKey or normalizedKey ~= math.floor(normalizedKey) or normalizedKey < 1 or normalizedKey > 7 then
                return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'day curve key must be a weekday or integer from 1 to 7')
            end
        end
        if not finite(value) or value < 0 or value > 5 then
            return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'demand curve multiplier is outside safe bounds')
        end
        if output[normalizedKey] ~= nil then
            return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'demand curve contains duplicate keys')
        end
        output[normalizedKey] = value
    end
    return output
end

local function normalizeDemandZones(raw, path)
    if raw == nil then return {} end
    local ok, arrayError = array(raw, path, 'demand discovery zones')
    if not ok then return nil, arrayError end
    local output, seen = {}, {}
    for index, value in ipairs(raw) do
        value = type(value) == 'string' and value:lower() or nil
        if not districtToken(value) or seen[value] then
            return fail('INVALID_CONFIG', path .. '[' .. index .. ']', 'demand discovery zone is invalid or duplicated')
        end
        seen[value] = true
        output[index] = value
    end
    return output
end

local function normalizeDemandDistricts(raw, path)
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', path, 'demand districts must be a table') end
    local output, seen = {}, {}
    local allowed = {
        id = true, districtId = true, district_id = true, key = true,
        baseline = true, baselineDemand = true, baseline_demand = true, demandBaseline = true,
        priceModifier = true, price_modifier = true, riskModifier = true, risk_modifier = true,
        heatModifier = true, heat_modifier = true, allowedZones = true,
        allowedStreetZones = true, allowed_street_zones = true,
        streetDiscoveryZones = true, street_discovery_zones = true,
        timeCurve = true, time_curve = true, timeDemand = true, time_demand = true,
        dayCurve = true, day_curve = true, dayDemand = true, day_demand = true,
        maxActiveCustomers = true, max_active_customers = true,
        maxActiveLogicalCustomers = true, max_active_logical_customers = true,
        available = true, version = true
    }
    local function add(rawValue, fallbackId, index)
        if type(rawValue) ~= 'table' then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. ']', 'district profile must be a table') end
        for key in pairs(rawValue) do
            if not allowed[key] then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].' .. tostring(key), 'district field is not allowlisted') end
        end
        local id = rawValue.id or rawValue.districtId or rawValue.district_id or rawValue.key or fallbackId
        id = type(id) == 'string' and id:lower() or nil
        if not districtToken(id) then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].id', 'district ID is invalid') end
        if seen[id] then return fail('DUPLICATE_ID', path .. '[' .. tostring(index) .. '].id', 'duplicate district ID') end
        seen[id] = true
        local baseline = rawValue.baselineDemand
        if baseline == nil then baseline = rawValue.baseline end
        if baseline == nil then baseline = rawValue.baseline_demand end
        if baseline == nil then baseline = rawValue.demandBaseline end
        baseline = baseline == nil and 50 or baseline
        if not finite(baseline) or baseline < 0 or baseline > 100 then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].baseline', 'district baseline must be between zero and one hundred') end
        local price = rawValue.priceModifier or rawValue.price_modifier
        price = price == nil and 1 or price
        if not finite(price) or price <= 0 or price > 10 then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].priceModifier', 'district price modifier is outside safe bounds') end
        local risk = rawValue.riskModifier or rawValue.risk_modifier
        risk = risk == nil and 0 or risk
        if not finite(risk) or risk < 0 or risk > 100 then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].riskModifier', 'district risk modifier is outside safe bounds') end
        local heat = rawValue.heatModifier or rawValue.heat_modifier
        heat = heat == nil and 0 or heat
        if not finite(heat) or heat < 0 or heat > 100 then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].heatModifier', 'district heat modifier is outside safe bounds') end
        local zones = rawValue.allowedZones or rawValue.allowedStreetZones or rawValue.allowed_street_zones
            or rawValue.streetDiscoveryZones or rawValue.street_discovery_zones
        local normalizedZones, zoneError = normalizeDemandZones(zones, path .. '[' .. tostring(index) .. '].allowedZones')
        if not normalizedZones then return nil, zoneError end
        local timeCurve, timeError = normalizeDemandCurve(rawValue.timeCurve or rawValue.time_curve or rawValue.timeDemand or rawValue.time_demand, path .. '[' .. tostring(index) .. '].timeCurve', 'time')
        if not timeCurve then return nil, timeError end
        local dayCurve, dayError = normalizeDemandCurve(rawValue.dayCurve or rawValue.day_curve or rawValue.dayDemand or rawValue.day_demand, path .. '[' .. tostring(index) .. '].dayCurve', 'day')
        if not dayCurve then return nil, dayError end
        local maximum = rawValue.maxActiveCustomers or rawValue.max_active_customers or rawValue.maxActiveLogicalCustomers or rawValue.max_active_logical_customers
        maximum = maximum == nil and 10 or maximum
        if not finite(maximum) or maximum < 1 or maximum > 100000 or maximum ~= math.floor(maximum) then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].maxActiveCustomers', 'district active customer capacity is invalid') end
        local available, availableError = booleanValue(rawValue.available, path .. '[' .. tostring(index) .. '].available', true)
        if available == nil then return nil, availableError end
        local version = rawValue.version == nil and 1 or rawValue.version
        if not finite(version) or version < 1 or version ~= math.floor(version) then return fail('INVALID_CONFIG', path .. '[' .. tostring(index) .. '].version', 'district version is invalid') end
        output[id] = {
            id = id, key = id, baseline = baseline, baselineDemand = baseline,
            priceModifier = price, riskModifier = risk, heatModifier = heat,
            allowedZones = normalizedZones, streetDiscoveryZones = copy(normalizedZones),
            timeCurve = timeCurve, dayCurve = dayCurve, maxActiveCustomers = maximum,
            available = available, version = version
        }
        return true
    end
    if #raw > 0 then
        local ok, errorResult = array(raw, path, 'demand districts')
        if not ok then return nil, errorResult end
        for index, value in ipairs(raw) do
            local okValue, valueError = add(value, nil, index)
            if not okValue then return nil, valueError end
        end
    else
        for key, value in pairs(raw) do
            local okValue, valueError = add(value, key, key)
            if not okValue then return nil, valueError end
        end
    end
    return output
end

local function validateReputationConfig(raw)
    if raw == nil then raw = NightShift.ReputationConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'reputation', 'reputation configuration must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'reputation.enabled', true)
    if enabled == nil then return nil, enabledError end
    local function bounded(name, fallback, minimum, maximum)
        local value = raw[name]
        value = value == nil and fallback or value
        if not finite(value) or value < minimum or value > maximum then
            return nil, fail('INVALID_CONFIG', 'reputation.' .. name, 'reputation value is outside safe bounds')
        end
        return value
    end
    local minimum, minimumError = bounded('min', 0, 0, 100)
    if minimum == nil then return nil, minimumError end
    local maximum, maximumError = bounded('max', 100, minimum, 100)
    if maximum == nil then return nil, maximumError end
    if maximum < minimum then return fail('INVALID_CONFIG', 'reputation.max', 'reputation maximum must not be below minimum') end
    local initial, initialError = bounded('initial', math.floor((minimum + maximum) / 2), minimum, maximum)
    if initial == nil then return nil, initialError end
    local threshold = raw.regularThreshold == nil and 3 or raw.regularThreshold
    if not finite(threshold) or threshold < 1 or threshold > 1000 or threshold ~= math.floor(threshold) then
        return fail('INVALID_CONFIG', 'reputation.regularThreshold', 'regular threshold must be a bounded integer')
    end
    local function deltaMap(name)
        local source = raw[name]
        if source == nil then source = {} end
        if type(source) ~= 'table' then return nil, fail('INVALID_CONFIG', 'reputation.' .. name, 'reputation delta map must be a table') end
        local allowed = { completion = true, cancellation = true, noShow = true, paymentReliability = true }
        local map = {}
        for key, value in pairs(source) do
            if not allowed[key] or not finite(value) or value < -100 or value > 100 then
                return nil, fail('INVALID_CONFIG', 'reputation.' .. name .. '.' .. tostring(key), 'reputation delta is outside safe bounds')
            end
            map[key] = value
        end
        return map
    end
    local worker, workerError = deltaMap('worker')
    if not worker then return nil, workerError end
    local client, clientError = deltaMap('client')
    if not client then return nil, clientError end
    local review = raw.review
    if review == nil then review = {} end
    if type(review) ~= 'table' then return nil, fail('INVALID_CONFIG', 'reputation.review', 'review config must be a table') end
    local reviewMinimum = review.minimum == nil and 1 or review.minimum
    local reviewMaximum = review.maximum == nil and 5 or review.maximum
    local textMaxLength = review.textMaxLength == nil and 1000 or review.textMaxLength
    if not finite(reviewMinimum) or reviewMinimum < 1 or reviewMinimum > 5 or reviewMinimum ~= math.floor(reviewMinimum) then
        return nil, fail('INVALID_CONFIG', 'reputation.review.minimum', 'review minimum is invalid')
    end
    if not finite(reviewMaximum) or reviewMaximum < reviewMinimum or reviewMaximum > 5 or reviewMaximum ~= math.floor(reviewMaximum) then
        return nil, fail('INVALID_CONFIG', 'reputation.review.maximum', 'review maximum is invalid')
    end
    if not finite(textMaxLength) or textMaxLength < 0 or textMaxLength > 2000 or textMaxLength ~= math.floor(textMaxLength) then
        local _, errorResult = fail('INVALID_CONFIG', 'reputation.review.textMaxLength', 'review text limit is invalid')
        return nil, errorResult
    end
    output.enabled, output.min, output.max, output.initial = enabled, minimum, maximum, initial
    output.regularThreshold, output.worker, output.client = threshold, worker, client
    output.review = { minimum = reviewMinimum, maximum = reviewMaximum, textMaxLength = textMaxLength }
    local favorite = raw.favorite
    if favorite == nil then favorite = {} end
    if type(favorite) ~= 'table' then
        local _, errorResult = fail('INVALID_CONFIG', 'reputation.favorite', 'favorite config must be a table')
        return nil, errorResult
    end
    local persistentOnly, favoriteError = booleanValue(favorite.persistentOnly, 'reputation.favorite.persistentOnly', true)
    if persistentOnly == nil then return nil, favoriteError end
    output.favorite = { persistentOnly = persistentOnly }
    local relationship = raw.relationship
    if relationship == nil then relationship = {} end
    if type(relationship) ~= 'table' then
        local _, errorResult = fail('INVALID_CONFIG', 'reputation.relationship', 'relationship config must be a table')
        return nil, errorResult
    end
    local relationshipThreshold = relationship.regularThreshold == nil and threshold or relationship.regularThreshold
    if not finite(relationshipThreshold) or relationshipThreshold < 1 or relationshipThreshold > 1000 or relationshipThreshold ~= math.floor(relationshipThreshold) then
        local _, errorResult = fail('INVALID_CONFIG', 'reputation.relationship.regularThreshold', 'relationship threshold is invalid')
        return nil, errorResult
    end
    local function relationshipDelta(name, fallback)
        local value = relationship[name] == nil and fallback or relationship[name]
        if not finite(value) or value < -100 or value > 100 then
            local _, errorResult = fail('INVALID_CONFIG', 'reputation.relationship.' .. name, 'relationship trust delta is invalid')
            return nil, errorResult
        end
        return value
    end
    local trustPerSettled, settledError = relationshipDelta('trustPerSettled', 10)
    if trustPerSettled == nil then return nil, settledError end
    local trustPerCancelled, cancelledError = relationshipDelta('trustPerCancelled', 0)
    if trustPerCancelled == nil then return nil, cancelledError end
    output.relationship = {
        regularThreshold = relationshipThreshold,
        trustPerSettled = trustPerSettled,
        trustPerCancelled = trustPerCancelled
    }
    return output
end

local function validateDemandConfig(raw)
    if raw == nil then raw = NightShift.DemandConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'demand', 'demand configuration must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'demand.enabled', true)
    if enabled == nil then return nil, enabledError end
    local function boundedDemand(value, path, fallback, maximumBound)
        value = value == nil and fallback or value
        if not finite(value) or value < 0 or value > maximumBound then return fail('INVALID_CONFIG', path, 'value is outside safe bounds') end
        return value
    end
    local minimum, minimumError = boundedDemand(raw.min, 'demand.min', 0, 100)
    if minimum == nil then return nil, minimumError end
    local maximum, maximumError = boundedDemand(raw.max, 'demand.max', 100, 100)
    if maximum == nil then return nil, maximumError end
    if maximum < minimum then return fail('INVALID_CONFIG', 'demand.max', 'demand maximum must not be below minimum') end
    local window, windowError = boundedDemand(raw.window, 'demand.window', 60, 86400)
    if window == nil then return nil, windowError end
    local function integerSetting(name, fallback, upper)
        local value = raw[name]
        value = value == nil and fallback or value
        if not finite(value) or value < 0 or value > upper or value ~= math.floor(value) then local _, errorResult = fail('INVALID_CONFIG', 'demand.' .. name, 'demand setting must be a bounded integer'); return nil, errorResult end
        return value
    end
    local generationInterval, generationError = integerSetting('generationIntervalSeconds', 60, 86400)
    if generationInterval == nil then return nil, generationError end
    local cooldown, cooldownError = integerSetting('candidateCooldownSeconds', 120, 86400)
    if cooldown == nil then return nil, cooldownError end
    local ttl, ttlError = integerSetting('opportunityTtlSeconds', 600, 86400)
    if ttl == nil or ttl < 1 then return nil, ttlError or fail('INVALID_CONFIG', 'demand.opportunityTtlSeconds', 'opportunity TTL must be positive') end
    local concurrent, concurrentError = integerSetting('maxConcurrentOpportunities', 3, 1000)
    if concurrent == nil or concurrent < 1 then return nil, concurrentError or fail('INVALID_CONFIG', 'demand.maxConcurrentOpportunities', 'maximum concurrent opportunities must be positive') end
    local activeCustomers, activeError = integerSetting('maxActiveLogicalCustomers', 50, 100000)
    if activeCustomers == nil or activeCustomers < 1 then return nil, activeError or fail('INVALID_CONFIG', 'demand.maxActiveLogicalCustomers', 'maximum active logical customers must be positive') end
    local minimumScore, scoreError = boundedDemand(raw.minimumDemandScore, 'demand.minimumDemandScore', 1, 100)
    if minimumScore == nil then return nil, scoreError end
    local function impact(name, fallback)
        local value = raw[name]
        value = value == nil and fallback or value
        if not finite(value) or value < 0 or value > 1 then local _, errorResult = fail('INVALID_CONFIG', 'demand.' .. name, 'demand impact must be between zero and one'); return nil, errorResult end
        return value
    end
    local oversupply, oversupplyError = impact('oversupplyPenalty', 0.5)
    if oversupply == nil then return nil, oversupplyError end
    local activity, activityError = impact('recentActivityImpact', 0.15)
    if activity == nil then return nil, activityError end
    local police, policeError = impact('policePressureImpact', 0.2)
    if police == nil then return nil, policeError end
    local heat, heatError = impact('heatImpact', 0.2)
    if heat == nil then return nil, heatError end
    local defaultDistrict = raw.defaultDistrict
    if defaultDistrict ~= nil then
        defaultDistrict = type(defaultDistrict) == 'string' and defaultDistrict:lower() or nil
        if not districtToken(defaultDistrict) then return fail('INVALID_CONFIG', 'demand.defaultDistrict', 'default district is invalid') end
    end
    local districtSource = raw.districts or raw.profiles
    local districts, districtError = normalizeDemandDistricts(districtSource, 'demand.districts')
    if not districts then return nil, districtError end
    if defaultDistrict ~= nil and next(districts) ~= nil and not districts[defaultDistrict] then return fail('INVALID_CONFIG', 'demand.defaultDistrict', 'default district is not configured') end
    output.enabled, output.min, output.max, output.window = enabled, minimum, maximum, window
    output.generationIntervalSeconds, output.candidateCooldownSeconds = generationInterval, cooldown
    output.opportunityTtlSeconds, output.maxConcurrentOpportunities = ttl, concurrent
    output.maxActiveLogicalCustomers, output.minimumDemandScore = activeCustomers, minimumScore
    output.oversupplyPenalty, output.recentActivityImpact = oversupply, activity
    output.policePressureImpact, output.heatImpact = police, heat
    output.defaultDistrict, output.districts = defaultDistrict, districts
    output.profiles = copy(districts)
    return output
end

local function validateSchedulingConfig(raw)
    if raw == nil then raw = NightShift.SchedulingConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'scheduling', 'scheduling configuration must be a table') end
    local allowed = {
        enabled = true, tickSeconds = true, batchSize = true,
        reservationLeadTimeSeconds = true, noShowGraceSeconds = true,
        conflictBufferSeconds = true, defaultDurationSeconds = true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'scheduling.' .. tostring(key), 'scheduling field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'scheduling.enabled', true)
    if enabled == nil then return nil, enabledError end
    local function setting(name, fallback, minimum, maximum)
        local value = raw[name]
        value = value == nil and fallback or value
        if not finite(value) or value < minimum or value > maximum or value ~= math.floor(value) then
            local _, errorResult = fail('INVALID_CONFIG', 'scheduling.' .. name, 'scheduling setting is outside safe bounds')
            return nil, errorResult
        end
        return value
    end
    local tick, tickError = setting('tickSeconds', 15, 1, 86400)
    if tick == nil then return nil, tickError end
    local batch, batchError = setting('batchSize', 50, 1, 100)
    if batch == nil then return nil, batchError end
    local lead, leadError = setting('reservationLeadTimeSeconds', 300, 0, 604800)
    if lead == nil then return nil, leadError end
    local grace, graceError = setting('noShowGraceSeconds', 300, 0, 604800)
    if grace == nil then return nil, graceError end
    local buffer, bufferError = setting('conflictBufferSeconds', 60, 0, 3600)
    if buffer == nil then return nil, bufferError end
    local duration, durationError = setting('defaultDurationSeconds', 1800, 1, 86400)
    if duration == nil then return nil, durationError end
    return {
        enabled = enabled, tickSeconds = tick, batchSize = batch,
        reservationLeadTimeSeconds = lead, noShowGraceSeconds = grace,
        conflictBufferSeconds = buffer, defaultDurationSeconds = duration
    }
end

local function validateRecoveryConfig(raw)
    if raw == nil then raw = NightShift.RecoveryConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'recovery', 'recovery configuration must be a table') end
    local allowed = {
        enabled = true, required = true, apply = true, pageSize = true, maxPages = true,
        disconnectGraceSeconds = true, interruptReserved = true,
        interruptTravelling = true, interruptActive = true,
        retryCompletedSettlement = true, releaseHeldDeposits = true,
        releaseReservations = true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'recovery.' .. tostring(key), 'recovery field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'recovery.enabled', true)
    if enabled == nil then return nil, enabledError end
    local required, requiredError = booleanValue(raw.required, 'recovery.required', false)
    if required == nil then return nil, requiredError end
    local apply, applyError = booleanValue(raw.apply, 'recovery.apply', false)
    if apply == nil then return nil, applyError end
    local function setting(name, fallback, minimum, maximum)
        local value = raw[name]
        value = value == nil and fallback or value
        if not finite(value) or value < minimum or value > maximum or value ~= math.floor(value) then
            local _, errorResult = fail('INVALID_CONFIG', 'recovery.' .. name, 'recovery setting is outside safe bounds')
            return nil, errorResult
        end
        return value
    end
    local pageSize, pageError = setting('pageSize', 100, 1, 1000)
    if pageSize == nil then return nil, pageError end
    local maxPages, pagesError = setting('maxPages', 20, 1, 100)
    if maxPages == nil then return nil, pagesError end
    local grace, graceError = setting('disconnectGraceSeconds', 30, 0, 86400)
    if grace == nil then return nil, graceError end
    local function flag(name, fallback)
        local value, errorResult = booleanValue(raw[name], 'recovery.' .. name, fallback)
        if value == nil then return nil, errorResult end
        return value
    end
    local interruptReserved, reservedError = flag('interruptReserved', true)
    if interruptReserved == nil then return nil, reservedError end
    local interruptTravelling, travellingError = flag('interruptTravelling', true)
    if interruptTravelling == nil then return nil, travellingError end
    local interruptActive, activeError = flag('interruptActive', true)
    if interruptActive == nil then return nil, activeError end
    local retryCompletedSettlement, settlementError = flag('retryCompletedSettlement', true)
    if retryCompletedSettlement == nil then return nil, settlementError end
    local releaseHeldDeposits, depositError = flag('releaseHeldDeposits', true)
    if releaseHeldDeposits == nil then return nil, depositError end
    local releaseReservations, reservationError = flag('releaseReservations', true)
    if releaseReservations == nil then return nil, reservationError end
    return {
        enabled = enabled, required = required, apply = apply, pageSize = pageSize,
        maxPages = maxPages, disconnectGraceSeconds = grace,
        interruptReserved = interruptReserved, interruptTravelling = interruptTravelling,
        interruptActive = interruptActive, retryCompletedSettlement = retryCompletedSettlement,
        releaseHeldDeposits = releaseHeldDeposits, releaseReservations = releaseReservations
    }
end

local function validateNpcStreamingConfig(raw, environment, physicalNpc)
    if raw == nil then raw = NightShift.NpcStreamingConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'npcStreaming', 'NPC streaming configuration must be a table') end
    local allowed = {
        enabled = true, spawnThreshold = true, arrivalRadius = true,
        navigationTimeout = true, stuckTimeout = true, playerAwayDistance = true,
        maxPlausibleArrivalDistance = true, defaultEtaSeconds = true,
        returnCooldownSeconds = true, budget = true, modelAllowlist = true,
        defaultModel = true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'npcStreaming.' .. tostring(key), 'NPC streaming field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'npcStreaming.enabled', true)
    if enabled == nil then return nil, enabledError end
    local function bounded(name, fallback, minimum, maximum)
        local value = raw[name] == nil and fallback or tonumber(raw[name])
        if not finite(value) or value < minimum or value > maximum then
            return fail('INVALID_CONFIG', 'npcStreaming.' .. name, 'NPC streaming value is outside safe bounds')
        end
        return value
    end
    local threshold, thresholdError = bounded('spawnThreshold', 0.65, 0, 1)
    if threshold == nil then return nil, thresholdError end
    local arrival, arrivalError = bounded('arrivalRadius', 4, 0.1, 100)
    if arrival == nil then return nil, arrivalError end
    local navigation, navigationError = bounded('navigationTimeout', 120, 1, 86400)
    if navigation == nil then return nil, navigationError end
    local stuck, stuckError = bounded('stuckTimeout', 15, 1, 3600)
    if stuck == nil then return nil, stuckError end
    local away, awayError = bounded('playerAwayDistance', 120, 1, 100000)
    if away == nil then return nil, awayError end
    local plausible, plausibleError = bounded('maxPlausibleArrivalDistance', 12, 0.1, 100000)
    if plausible == nil then return nil, plausibleError end
    local eta, etaError = bounded('defaultEtaSeconds', 60, 0, 86400)
    if eta == nil then return nil, etaError end
    local cooldown, cooldownError = bounded('returnCooldownSeconds', 15, 0, 86400)
    if cooldown == nil then return nil, cooldownError end
    local budget = raw.budget == nil and {} or raw.budget
    if type(budget) ~= 'table' then return fail('INVALID_CONFIG', 'npcStreaming.budget', 'NPC streaming budget must be a table') end
    local budgetAllowed = {
        enabled = true, maxActive = true, maxPerSource = true,
        maxPerDistrict = true, maxTracked = true, leaseSeconds = true
    }
    for key in pairs(budget) do
        if not budgetAllowed[key] then return fail('INVALID_CONFIG', 'npcStreaming.budget.' .. tostring(key), 'NPC budget field is not allowlisted') end
    end
    local budgetEnabled, budgetEnabledError = booleanValue(budget.enabled, 'npcStreaming.budget.enabled', true)
    if budgetEnabled == nil then return nil, budgetEnabledError end
    local function budgetInteger(name, fallback, minimum, maximum)
        local value = budget[name] == nil and fallback or tonumber(budget[name])
        if not finite(value) or value < minimum or value > maximum or value ~= math.floor(value) then
            return fail('INVALID_CONFIG', 'npcStreaming.budget.' .. name, 'NPC budget value is outside safe bounds')
        end
        return value
    end
    local maxActive, maxActiveError = budgetInteger('maxActive', 64, 1, 100000)
    if maxActive == nil then return nil, maxActiveError end
    local maxPerSource, maxPerSourceError = budgetInteger('maxPerSource', 8, 1, 100000)
    if maxPerSource == nil then return nil, maxPerSourceError end
    local maxPerDistrict, maxPerDistrictError = budgetInteger('maxPerDistrict', 32, 1, 100000)
    if maxPerDistrict == nil then return nil, maxPerDistrictError end
    local maxTracked, maxTrackedError = budgetInteger('maxTracked', 512, 1, 1000000)
    if maxTracked == nil then return nil, maxTrackedError end
    local leaseSeconds, leaseError = budgetInteger('leaseSeconds', 120, 1, 86400)
    if leaseSeconds == nil then return nil, leaseError end
    local models = raw.modelAllowlist == nil and {} or raw.modelAllowlist
    if type(models) ~= 'table' then return fail('INVALID_CONFIG', 'npcStreaming.modelAllowlist', 'NPC model allowlist must be a table') end
    local normalizedModels, modelCount = {}, 0
    for key, value in pairs(models) do
        local model = type(key) == 'number' and value or key
        local allowedValue = type(key) == 'number' and true or value
        if not token(model, 96) or allowedValue ~= true then
            return fail('INVALID_CONFIG', 'npcStreaming.modelAllowlist', 'NPC model allowlist contains an invalid entry')
        end
        normalizedModels[model] = true
        modelCount = modelCount + 1
        if modelCount > 128 then return fail('INVALID_CONFIG', 'npcStreaming.modelAllowlist', 'NPC model allowlist is too large') end
    end
    local defaultModel = raw.defaultModel
    if defaultModel ~= nil and not token(defaultModel, 96) then
        return fail('INVALID_CONFIG', 'npcStreaming.defaultModel', 'NPC default model is invalid')
    end
    if defaultModel ~= nil and modelCount > 0 and not normalizedModels[defaultModel] then
        return fail('INVALID_CONFIG', 'npcStreaming.defaultModel', 'NPC default model is not allowlisted')
    end
    local strict = tostring(environment or 'development'):lower() == 'production'
        or tostring(environment or ''):lower() == 'prod' or physicalNpc == true
    if strict and (modelCount == 0 or defaultModel == nil or not normalizedModels[defaultModel]) then
        return fail('NPC_SPAWN_MODEL_NOT_ALLOWED', 'npcStreaming.modelAllowlist',
            'production physical NPCs require a non-empty allowlist and allowlisted default model')
    end
    return {
        enabled = enabled, spawnThreshold = threshold, arrivalRadius = arrival,
        navigationTimeout = navigation, stuckTimeout = stuck, playerAwayDistance = away,
        maxPlausibleArrivalDistance = plausible, defaultEtaSeconds = eta,
        returnCooldownSeconds = cooldown,
        budget = { enabled = budgetEnabled, maxActive = maxActive,
            maxPerSource = maxPerSource, maxPerDistrict = maxPerDistrict,
            maxTracked = maxTracked, leaseSeconds = leaseSeconds },
        modelAllowlist = normalizedModels,
        defaultModel = defaultModel
    }
end

local function validateSecurityConfig(raw)
    if raw == nil then raw = NightShift.SecurityConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'security', 'security configuration must be a table') end
    local allowed = { enabled = true, persistentCounters = true, maxBuckets = true, rateLimit = true, actionTokens = true }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'security.' .. tostring(key), 'security field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'security.enabled', true)
    if enabled == nil then return nil, enabledError end
    local persistent, persistentError = booleanValue(raw.persistentCounters, 'security.persistentCounters', false)
    if persistent == nil then return nil, persistentError end
    local maxBuckets = raw.maxBuckets == nil and 2048 or tonumber(raw.maxBuckets)
    if not finite(maxBuckets) or maxBuckets < 64 or maxBuckets > 100000 or maxBuckets ~= math.floor(maxBuckets) then
        return fail('INVALID_CONFIG', 'security.maxBuckets', 'security bucket limit is outside safe bounds')
    end
    local rate = raw.rateLimit == nil and {} or raw.rateLimit
    if type(rate) ~= 'table' then return fail('INVALID_CONFIG', 'security.rateLimit', 'rate limit configuration must be a table') end
    for key in pairs(rate) do
        if key ~= 'enabled' and key ~= 'default' and key ~= 'actions' then
            return fail('INVALID_CONFIG', 'security.rateLimit.' .. tostring(key), 'rate limit field is not allowlisted')
        end
    end
    local rateEnabled, rateError = booleanValue(rate.enabled, 'security.rateLimit.enabled', true)
    if rateEnabled == nil then return nil, rateError end
    local function rule(rawRule, path, fallback)
        rawRule = rawRule == nil and (fallback or {}) or rawRule
        if type(rawRule) ~= 'table' then return fail('INVALID_CONFIG', path, 'rate rule must be a table') end
        for key in pairs(rawRule) do
            if key ~= 'capacity' and key ~= 'refillPerSecond' and key ~= 'cost' then
                return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'rate rule field is not allowlisted')
            end
        end
        local capacity = rawRule.capacity == nil and (fallback and fallback.capacity or 20) or tonumber(rawRule.capacity)
        local refill = rawRule.refillPerSecond == nil and (fallback and fallback.refillPerSecond or 2) or tonumber(rawRule.refillPerSecond)
        local cost = rawRule.cost == nil and (fallback and fallback.cost or 1) or tonumber(rawRule.cost)
        if not finite(capacity) or capacity < 1 or capacity > 10000 or capacity ~= math.floor(capacity) then
            return fail('INVALID_CONFIG', path .. '.capacity', 'rate capacity is outside safe bounds')
        end
        if not finite(refill) or refill <= 0 or refill > 1000 then
            return fail('INVALID_CONFIG', path .. '.refillPerSecond', 'rate refill is outside safe bounds')
        end
        if not finite(cost) or cost <= 0 or cost > capacity then
            return fail('INVALID_CONFIG', path .. '.cost', 'rate cost is outside safe bounds')
        end
        return { capacity = capacity, refillPerSecond = refill, cost = cost }
    end
    local defaultRule, defaultError = rule(rate.default, 'security.rateLimit.default', { capacity = 20, refillPerSecond = 2, cost = 1 })
    if not defaultRule then return nil, defaultError end
    local actionRules = rate.actions == nil and {} or rate.actions
    if type(actionRules) ~= 'table' then return fail('INVALID_CONFIG', 'security.rateLimit.actions', 'rate action rules must be a table') end
    local normalizedActions, actionCount = {}, 0
    for action, rawRule in pairs(actionRules) do
        actionCount = actionCount + 1
        if actionCount > 128 or not token(action, 64) then
            return fail('INVALID_CONFIG', 'security.rateLimit.actions.' .. tostring(action), 'rate action name is invalid')
        end
        local normalizedRule, ruleError = rule(rawRule, 'security.rateLimit.actions.' .. tostring(action), defaultRule)
        if not normalizedRule then return nil, ruleError end
        normalizedActions[action] = normalizedRule
    end
    local actionTokenConfig = raw.actionTokens == nil and {} or raw.actionTokens
    if type(actionTokenConfig) ~= 'table' then return fail('INVALID_CONFIG', 'security.actionTokens', 'action token configuration must be a table') end
    for key in pairs(actionTokenConfig) do
        if key ~= 'enabled' and key ~= 'enforce' and key ~= 'developmentOptOut' and key ~= 'ttlSeconds' and key ~= 'maxActive' and key ~= 'maxTokenLength' then
            return fail('INVALID_CONFIG', 'security.actionTokens.' .. tostring(key), 'action token field is not allowlisted')
        end
    end
    local tokenEnabled, tokenEnabledError = booleanValue(actionTokenConfig.enabled, 'security.actionTokens.enabled', true)
    if tokenEnabled == nil then return nil, tokenEnabledError end
    local enforce, enforceError = booleanValue(actionTokenConfig.enforce, 'security.actionTokens.enforce', true)
    if enforce == nil then return nil, enforceError end
    local developmentOptOut, developmentOptOutError = booleanValue(actionTokenConfig.developmentOptOut,
        'security.actionTokens.developmentOptOut', false)
    if developmentOptOut == nil then return nil, developmentOptOutError end
    local ttl = actionTokenConfig.ttlSeconds == nil and 90 or tonumber(actionTokenConfig.ttlSeconds)
    if not finite(ttl) or ttl < 1 or ttl > 3600 or ttl ~= math.floor(ttl) then
        return fail('INVALID_CONFIG', 'security.actionTokens.ttlSeconds', 'action token TTL is outside safe bounds')
    end
    local maxActive = actionTokenConfig.maxActive == nil and 4096 or tonumber(actionTokenConfig.maxActive)
    if not finite(maxActive) or maxActive < 1 or maxActive > 100000 or maxActive ~= math.floor(maxActive) then
        return fail('INVALID_CONFIG', 'security.actionTokens.maxActive', 'action token capacity is outside safe bounds')
    end
    local maxTokenLength = actionTokenConfig.maxTokenLength == nil and 192 or tonumber(actionTokenConfig.maxTokenLength)
    if not finite(maxTokenLength) or maxTokenLength < 64 or maxTokenLength > 512 or maxTokenLength ~= math.floor(maxTokenLength) then
        return fail('INVALID_CONFIG', 'security.actionTokens.maxTokenLength', 'action token length is outside safe bounds')
    end
    return {
        enabled = enabled, persistentCounters = persistent, maxBuckets = maxBuckets,
        rateLimit = { enabled = rateEnabled, default = defaultRule, actions = normalizedActions },
        actionTokens = {
            enabled = tokenEnabled, enforce = enforce, developmentOptOut = developmentOptOut, ttlSeconds = ttl,
            maxActive = maxActive, maxTokenLength = maxTokenLength
        }
    }
end

local function boundedNumber(raw, name, fallback, minimum, maximum, whole)
    local key = name:match('%.([^%.]+)$') or name
    local value = raw[key]
    value = value == nil and fallback or tonumber(value)
    if not finite(value) or value < minimum or value > maximum or (whole and value ~= math.floor(value)) then
        local _, errorResult = fail('INVALID_CONFIG', name, 'value is outside safe bounds')
        return nil, errorResult
    end
    return value
end

local function validateHeatConfig(raw)
    if raw == nil then raw = NightShift.HeatConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'heat', 'heat configuration must be a table') end
    local allowed = {
        enabled=true, playerEnabled=true, min=true, max=true, playerIncrement=true,
        districtIncrement=true, decayIntervalSeconds=true, playerDecay=true,
        districtDecay=true, maxEventKeys=true, eventIncrements=true, decay=true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'heat.' .. tostring(key), 'heat field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'heat.enabled', true)
    if enabled == nil then return nil, enabledError end
    local playerEnabled, playerError = booleanValue(raw.playerEnabled, 'heat.playerEnabled', true)
    if playerEnabled == nil then return nil, playerError end
    local minimum, minimumError = boundedNumber(raw, 'heat.min', 0, 0, 100)
    if minimum == nil then return nil, minimumError end
    local maximum, maximumError = boundedNumber(raw, 'heat.max', 100, 0, 100)
    if maximum == nil then return nil, maximumError end
    if maximum <= minimum then return fail('INVALID_CONFIG', 'heat.max', 'maximum must be above minimum') end
    local legacyDecay = raw.decay
    local playerIncrement, incrementError = boundedNumber(raw, 'heat.playerIncrement', 5, 0, 100)
    if playerIncrement == nil then return nil, incrementError end
    local districtIncrement, districtError = boundedNumber(raw, 'heat.districtIncrement', 5, 0, 100)
    if districtIncrement == nil then return nil, districtError end
    local interval, intervalError = boundedNumber(raw, 'heat.decayIntervalSeconds', 300, 1, 86400, true)
    if interval == nil then return nil, intervalError end
    local playerDecay, playerDecayError = boundedNumber(raw, 'heat.playerDecay', legacyDecay == nil and 2 or legacyDecay, 0, 100)
    if playerDecay == nil then return nil, playerDecayError end
    local districtDecay, districtDecayError = boundedNumber(raw, 'heat.districtDecay', legacyDecay == nil and 3 or legacyDecay, 0, 100)
    if districtDecay == nil then return nil, districtDecayError end
    local maxEventKeys, maxKeysError = boundedNumber(raw, 'heat.maxEventKeys', 2048, 1, 100000, true)
    if maxEventKeys == nil then return nil, maxKeysError end
    local increments = raw.eventIncrements == nil and {} or raw.eventIncrements
    if type(increments) ~= 'table' then return fail('INVALID_CONFIG', 'heat.eventIncrements', 'event increments must be a table') end
    local normalizedIncrements = {}
    for eventType, values in pairs(increments) do
        if not token(eventType, 96) or type(values) ~= 'table' then
            return fail('INVALID_CONFIG', 'heat.eventIncrements.' .. tostring(eventType), 'event increment entry is invalid')
        end
        local playerAmount, playerAmountError = boundedNumber(values, 'player', nil, 0, 100)
        if values.player ~= nil and playerAmount == nil then return nil, playerAmountError end
        local districtAmount, districtAmountError = boundedNumber(values, 'district', nil, 0, 100)
        if values.district ~= nil and districtAmount == nil then return nil, districtAmountError end
        normalizedIncrements[tostring(eventType)] = { player = playerAmount, district = districtAmount }
    end
    return {
        enabled = enabled, playerEnabled = playerEnabled, min = minimum, max = maximum,
        playerIncrement = playerIncrement, districtIncrement = districtIncrement,
        decayIntervalSeconds = interval, playerDecay = playerDecay, districtDecay = districtDecay,
        maxEventKeys = maxEventKeys, eventIncrements = normalizedIncrements,
        decay = legacyDecay == nil and districtDecay or legacyDecay
    }
end

local function validateViceConfig(raw)
    if raw == nil then raw = NightShift.ViceConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'vice', 'vice configuration must be a table') end
    local allowed = {
        enabled=true, riskThreshold=true, dispatchThreshold=true,
        districtPressureWeight=true, archetypeWeight=true, bookingWeight=true, dispatch=true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'vice.' .. tostring(key), 'vice field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'vice.enabled', false)
    if enabled == nil then return nil, enabledError end
    local risk, riskError = boundedNumber(raw, 'vice.riskThreshold', 60, 0, 100)
    if risk == nil then return nil, riskError end
    local dispatchThreshold, thresholdError = boundedNumber(raw, 'vice.dispatchThreshold', 80, 0, 100)
    if dispatchThreshold == nil then return nil, thresholdError end
    local pressure, pressureError = boundedNumber(raw, 'vice.districtPressureWeight', 0.5, 0, 1)
    if pressure == nil then return nil, pressureError end
    local archetype, archetypeError = boundedNumber(raw, 'vice.archetypeWeight', 0.3, 0, 1)
    if archetype == nil then return nil, archetypeError end
    local booking, bookingError = boundedNumber(raw, 'vice.bookingWeight', 0.2, 0, 1)
    if booking == nil then return nil, bookingError end
    local dispatch = raw.dispatch == nil and {} or raw.dispatch
    if type(dispatch) ~= 'table' then return fail('INVALID_CONFIG', 'vice.dispatch', 'dispatch configuration must be a table') end
    for key in pairs(dispatch) do
        if key ~= 'enabled' and key ~= 'requireThreshold' then
            return fail('INVALID_CONFIG', 'vice.dispatch.' .. tostring(key), 'vice dispatch field is not allowlisted')
        end
    end
    local dispatchEnabled, dispatchError = booleanValue(dispatch.enabled, 'vice.dispatch.enabled', false)
    if dispatchEnabled == nil then return nil, dispatchError end
    local requireThreshold, requireError = booleanValue(dispatch.requireThreshold, 'vice.dispatch.requireThreshold', true)
    if requireThreshold == nil then return nil, requireError end
    return {
        enabled = enabled, riskThreshold = risk, dispatchThreshold = dispatchThreshold,
        districtPressureWeight = pressure, archetypeWeight = archetype, bookingWeight = booking,
        dispatch = { enabled = dispatchEnabled, requireThreshold = requireThreshold }
    }
end

local function validateDemandHeatFeedbackConfig(raw)
    if raw == nil then raw = NightShift.DemandHeatFeedbackConfig or {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'demandHeatFeedback', 'feedback configuration must be a table') end
    local allowed = {
        enabled=true, streetPressureThreshold=true, streetOpportunityPenalty=true,
        privateAvailabilityModifier=true, pricingDemandWeight=true, pricingHeatWeight=true,
        pricingOversupplyPenalty=true, minMultiplier=true, maxMultiplier=true
    }
    for key in pairs(raw) do
        if not allowed[key] then return fail('INVALID_CONFIG', 'demandHeatFeedback.' .. tostring(key), 'feedback field is not allowlisted') end
    end
    local enabled, enabledError = booleanValue(raw.enabled, 'demandHeatFeedback.enabled', true)
    if enabled == nil then return nil, enabledError end
    local threshold, thresholdError = boundedNumber(raw, 'demandHeatFeedback.streetPressureThreshold', 70, 0, 100)
    if threshold == nil then return nil, thresholdError end
    local street, streetError = boundedNumber(raw, 'demandHeatFeedback.streetOpportunityPenalty', 0.6, 0, 1)
    if street == nil then return nil, streetError end
    local private, privateError = boundedNumber(raw, 'demandHeatFeedback.privateAvailabilityModifier', 0.35, 0, 1)
    if private == nil then return nil, privateError end
    local demand, demandError = boundedNumber(raw, 'demandHeatFeedback.pricingDemandWeight', 0.2, 0, 1)
    if demand == nil then return nil, demandError end
    local heat, heatError = boundedNumber(raw, 'demandHeatFeedback.pricingHeatWeight', 0.15, 0, 1)
    if heat == nil then return nil, heatError end
    local oversupply, oversupplyError = boundedNumber(raw, 'demandHeatFeedback.pricingOversupplyPenalty', 0.3, 0, 1)
    if oversupply == nil then return nil, oversupplyError end
    local minimum, minimumError = boundedNumber(raw, 'demandHeatFeedback.minMultiplier', 0.25, 0.05, 1)
    if minimum == nil then return nil, minimumError end
    local maximum, maximumError = boundedNumber(raw, 'demandHeatFeedback.maxMultiplier', 1.75, 1, 5)
    if maximum == nil then return nil, maximumError end
    if minimum > maximum then return fail('INVALID_CONFIG', 'demandHeatFeedback.maxMultiplier', 'maximum must not be below minimum') end
    return {
        enabled = enabled, streetPressureThreshold = threshold,
        streetOpportunityPenalty = street, privateAvailabilityModifier = private,
        pricingDemandWeight = demand, pricingHeatWeight = heat,
        pricingOversupplyPenalty = oversupply, minMultiplier = minimum, maxMultiplier = maximum
    }
end

function V.validateConfig(input, options)
    options=options or {}; if input==nil then input=NightShift.DefaultConfig end; if type(input)~='table' then return fail('INVALID_CONFIG','config','configuration must be a table') end
    local out=copy(input); local environment=rawget(input,'environment'); environment=environment==nil and 'development' or tostring(environment):lower(); if environment=='prod' then environment='production' end; if environment~='development' and environment~='production' and environment~='staging' and environment~='test' then return fail('INVALID_CONFIG','environment','environment is invalid') end; out.environment=environment; local raw=rawget(input,'provider'); if raw==nil then raw=rawget(input,'providerSelection') end; local provider=raw==nil and {} or raw
    if type(provider)=='string' then provider={mode='explicit',name=provider} end; if type(provider)~='table' then return fail('INVALID_CONFIG','provider','provider selection must be a table') end
    local mode=rawget(provider,'mode'); mode=mode==nil and 'auto' or mode; if not NightShift.ProviderModes[mode] then return fail('INVALID_CONFIG','provider.mode','provider mode must be auto or explicit') end
    local registry=options.registry or NightShift.ProviderRegistry; if type(registry)~='table' then return fail('INVALID_CONFIG','provider','provider registry is invalid') end
    local selected,capabilities
    if mode=='explicit' then selected=rawget(provider,'name'); if selected==nil then selected=rawget(provider,'provider') end; if not text(selected) or type(registry[selected])~='table' then return fail('UNKNOWN_PROVIDER','provider.name','provider is not allowlisted') end; capabilities=copy(registry[selected].capabilities or {})
    else
        local resolver=options.resolveProvider or options.providerResolver; if type(resolver)~='function' then return fail('PROVIDER_UNAVAILABLE','provider','auto provider detection is unavailable') end
        local ok,result=pcall(resolver,copy(registry)); if not ok or type(result)~='table' then return fail('PROVIDER_UNAVAILABLE','provider','no supported provider was detected') end
        selected=result.name; if not text(selected) or type(registry[selected])~='table' or result.supported~=true or result.available~=true or type(result.capabilities)~='table' then return fail('PROVIDER_UNAVAILABLE','provider','detected provider has no supported capability') end
        local supported=false; for _,v in pairs(result.capabilities) do if v==true then supported=true; break end end; if not supported then return fail('PROVIDER_UNAVAILABLE','provider','detected provider has no supported capability') end; capabilities=copy(result.capabilities)
    end
    out.provider={mode=mode,name=selected,capabilities=capabilities}
    local features=copy(NightShift.FeatureDefaults); local rf=rawget(input,'features'); if rf~=nil then if type(rf)~='table' then return fail('INVALID_CONFIG','features','features must be a table') end; for k,v in pairs(rf) do if type(features[k])~='boolean' or type(v)~='boolean' then return fail('INVALID_CONFIG','features.'..tostring(k),'feature flags must be boolean') end; features[k]=v end end; out.features=features
    local rp=rawget(input,'servicePackages'); if rp==nil then rp=rawget(input,'packages') end; local packages,ps=ids(rp==nil and {} or rp,'servicePackages','service package'); if not packages then return nil,ps end
    for i,pkg in ipairs(packages) do local price=rawget(pkg,'price'); if price==nil then price=rawget(pkg,'priceMinor') end; if not integer(price) then return fail('INVALID_PRICE','servicePackages['..i..'].price','price must be a positive integer in minor units') end; pkg.price=price; if not positive(pkg.duration) then return fail('INVALID_DURATION','servicePackages['..i..'].duration','duration must be positive') end; local refs=rawget(pkg,'locationIds'); if refs==nil then refs=rawget(pkg,'location_ids') end; if refs==nil then refs=rawget(pkg,'locations') end; refs=refs==nil and {} or refs; local rok,re=array(refs,'servicePackages['..i..'].locationIds','location references'); if not rok then return nil,re end; local rs={}; for j,id in ipairs(refs) do if not text(id) or rs[id] then return fail('INVALID_LOCATION_REFERENCE','servicePackages['..i..'].locationIds['..j..']','location reference must be unique and non-empty') end; rs[id]=true end; pkg.locationIds=copy(refs); if pkg.provider~=nil and (not text(pkg.provider) or not registry[pkg.provider]) then return fail('UNKNOWN_PROVIDER','servicePackages['..i..'].provider','provider reference is not allowlisted') end end; out.servicePackages=packages
    local locations,ls=validateLocations(rawget(input,'locations')); if not locations then return nil,ls end; out.locations=locations; for i,pkg in ipairs(packages) do for j,id in ipairs(pkg.locationIds) do if not ls[id] then return fail('INVALID_LOCATION_REFERENCE','servicePackages['..i..'].locationIds['..j..']','location reference is not allowlisted') end end end
    local catalog, catalogError = validateServiceCatalog(rawget(input, 'serviceCatalog'), locations); if not catalog then return nil, catalogError end; out.serviceCatalog = catalog
    local pricing, pricingError = validatePricing(rawget(input, 'pricing')); if not pricing then return nil, pricingError end; out.pricing = pricing
    local cancellation, cancellationError = validateCancellation(rawget(input, 'cancellation')); if not cancellation then return nil, cancellationError end; out.cancellation = cancellation
    local profiles,pr=ids(input.npcProfiles==nil and {} or input.npcProfiles,'npcProfiles','NPC profile'); if not profiles then return nil,pr end; local allowed={id=true,availability=true,traits=true,tags=true,displayName=true}; for i,p in ipairs(profiles) do for k,v in pairs(p) do if not allowed[k] then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile field is not abstract/allowlisted') end; if (k=='availability' or k=='displayName') and (not text(v) or #v>80) then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile scalar is invalid') end; if k=='traits' or k=='tags' then local ok,e=array(v,'npcProfiles['..i..'].'..tostring(k),'NPC profile list'); if not ok then return nil,e end; for j,item in ipairs(v) do if not text(item) or #item>40 then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k)..'['..j..']','NPC profile list value is invalid') end end end end end; out.npcProfiles=profiles
    local npcStreaming, npcStreamingError = validateNpcStreamingConfig(rawget(input, 'npcStreaming'), environment, features.physicalNpc); if not npcStreaming then return nil, npcStreamingError end; out.npcStreaming = npcStreaming
    local demand, demandError = validateDemandConfig(rawget(input, 'demand')); if not demand then return nil, demandError end
    local heat, heatError = validateHeatConfig(rawget(input, 'heat')); if not heat then return nil, heatError end
    local vice, viceError = validateViceConfig(rawget(input, 'vice')); if not vice then return nil, viceError end
    local feedback, feedbackError = validateDemandHeatFeedbackConfig(rawget(input, 'demandHeatFeedback')); if not feedback then return nil, feedbackError end
    local reputation, reputationError = validateReputationConfig(rawget(input, 'reputation')); if not reputation then return nil, reputationError end
    local scheduling, schedulingError = validateSchedulingConfig(rawget(input, 'scheduling')); if not scheduling then return nil, schedulingError end
    local recovery, recoveryError = validateRecoveryConfig(rawget(input, 'recovery')); if not recovery then return nil, recoveryError end
    local security, securityError = validateSecurityConfig(rawget(input, 'security')); if not security then return nil, securityError end
    out.demand, out.heat, out.vice, out.demandHeatFeedback = demand, heat, vice, feedback
    out.reputation, out.scheduling, out.recovery, out.security = reputation, scheduling, recovery, security
    return out
end
V.copy=copy; NightShift.Config=NightShift.Config or {validate=V.validateConfig}
