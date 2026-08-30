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

function V.validateConfig(input, options)
    options=options or {}; if input==nil then input=NightShift.DefaultConfig end; if type(input)~='table' then return fail('INVALID_CONFIG','config','configuration must be a table') end
    local out=copy(input); local raw=rawget(input,'provider'); if raw==nil then raw=rawget(input,'providerSelection') end; local provider=raw==nil and {} or raw
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
    local function bounded(v,p,d,max) v=v==nil and d or v; if not finite(v) or v<0 or v>max then return fail('INVALID_CONFIG',p,'value is outside safe bounds') end; return v end
    local function section(name)
        local s=rawget(input,name); if s==nil then s={} end; if type(s)~='table' then return fail('INVALID_CONFIG',name,name..' must be a table') end; local mn,e=bounded(s.min,name..'.min',0,100); if mn==nil then return nil,e end; local mx; mx,e=bounded(s.max,name..'.max',100,100); if mx==nil then return nil,e end; if mx<mn then return fail('INVALID_CONFIG',name..'.max','maximum must not be below minimum') end; local r=copy(s); r.min,r.max=mn,mx; if name=='demand' then r.window,e=bounded(s.window,name..'.window',0,86400); if r.window==nil then return nil,e end else r.decay,e=bounded(s.decay,name..'.decay',0,100); if r.decay==nil then return nil,e end end; return r
    end
    local demand, demandError = validateDemandConfig(rawget(input, 'demand')); if not demand then return nil, demandError end; local heat; heat,demandError=section('heat'); if not heat then return nil,demandError end; out.demand,out.heat=demand,heat; return out
end
V.copy=copy; NightShift.Config=NightShift.Config or {validate=V.validateConfig}
