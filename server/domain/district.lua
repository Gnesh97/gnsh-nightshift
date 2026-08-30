NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local District = {}
District.__index = District

local days = {
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

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.DISTRICT_INVALID, message, details)
end

local function normalizedDay(value)
    if type(value) == 'string' then
        local upper = value:upper()
        if days[upper] then return days[upper] end
        value = tonumber(value)
    end
    value = tonumber(value)
    if value and value == math.floor(value) and value >= 1 and value <= 7 then return value end
    return nil
end

local function normalizedCurve(raw, kind)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil, invalid(kind .. ' demand curve must be a table') end
    local output = {}
    local array24 = kind == 'time' and #raw == 24
    for key, value in pairs(raw) do
        local normalizedKey
        if kind == 'time' then
            normalizedKey = tonumber(key)
            if array24 then normalizedKey = normalizedKey and normalizedKey - 1 end
            if not normalizedKey or normalizedKey ~= math.floor(normalizedKey) or normalizedKey < 0 or normalizedKey > 23 then
                return nil, invalid('district time curve hour is invalid', { hour = key })
            end
        else
            normalizedKey = normalizedDay(key)
            if not normalizedKey then return nil, invalid('district day curve key is invalid', { day = key }) end
        end
        value = tonumber(value)
        if not finite(value) or value < 0 or value > 5 then
            return nil, invalid('district demand curve multiplier is outside safe bounds', { key = key })
        end
        if output[normalizedKey] ~= nil then return nil, invalid('district demand curve contains duplicate keys', { key = key }) end
        output[normalizedKey] = value
    end
    return output
end

local function normalizedZones(raw)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil, invalid('district discovery zones must be an array') end
    local output, seen, count = {}, {}, 0
    for key, value in pairs(raw) do
        if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then return nil, invalid('district discovery zones must be contiguous') end
        count = count + 1
        value = type(value) == 'string' and value:lower() or nil
        if not token(value, 64) or seen[value] then return nil, invalid('district discovery zone is invalid or duplicated', { index = key }) end
        seen[value] = true
        output[key] = value
    end
    if count ~= #raw then return nil, invalid('district discovery zones must be contiguous') end
    return output
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('district values must be a table') end
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
        available = true, version = true, displayName = true, name = true
    }
    for key in pairs(values) do
        if not allowed[key] then return nil, invalid('district field is not allowlisted', { field = tostring(key) }) end
    end
    local id = values.id or values.districtId or values.district_id or values.key
    if not text(id, 64) then return nil, invalid('district ID is required') end
    id = id:lower()
    if not token(id, 64) then return nil, invalid('district ID is invalid') end
    local baseline = values.baselineDemand
    if baseline == nil then baseline = values.baseline end
    if baseline == nil then baseline = values.baseline_demand end
    if baseline == nil then baseline = values.demandBaseline end
    baseline = baseline == nil and 50 or tonumber(baseline)
    if not finite(baseline) or baseline < 0 or baseline > 100 then return nil, invalid('district baseline must be between zero and one hundred') end
    local priceModifier = values.priceModifier or values.price_modifier
    priceModifier = priceModifier == nil and 1 or tonumber(priceModifier)
    if not finite(priceModifier) or priceModifier <= 0 or priceModifier > 10 then return nil, invalid('district price modifier is outside safe bounds') end
    local riskModifier = values.riskModifier or values.risk_modifier
    riskModifier = riskModifier == nil and 0 or tonumber(riskModifier)
    if not finite(riskModifier) or riskModifier < 0 or riskModifier > 100 then return nil, invalid('district risk modifier is outside safe bounds') end
    local heatModifier = values.heatModifier or values.heat_modifier
    heatModifier = heatModifier == nil and 0 or tonumber(heatModifier)
    if not finite(heatModifier) or heatModifier < 0 or heatModifier > 100 then return nil, invalid('district heat modifier is outside safe bounds') end
    local zones = values.allowedZones or values.allowedStreetZones or values.allowed_street_zones
        or values.streetDiscoveryZones or values.street_discovery_zones
    local allowedZones, zonesError = normalizedZones(zones)
    if not allowedZones then return nil, zonesError end
    local timeCurve, timeError = normalizedCurve(values.timeCurve or values.time_curve or values.timeDemand or values.time_demand, 'time')
    if not timeCurve then return nil, timeError end
    local dayCurve, dayError = normalizedCurve(values.dayCurve or values.day_curve or values.dayDemand or values.day_demand, 'day')
    if not dayCurve then return nil, dayError end
    local maximum = values.maxActiveCustomers or values.max_active_customers
        or values.maxActiveLogicalCustomers or values.max_active_logical_customers
    maximum = maximum == nil and 10 or tonumber(maximum)
    if not finite(maximum) or maximum < 1 or maximum > 100000 or maximum ~= math.floor(maximum) then return nil, invalid('district active customer capacity is invalid') end
    local available = values.available
    if available == nil then available = true end
    if type(available) ~= 'boolean' then return nil, invalid('district availability must be boolean') end
    local version = values.version == nil and 1 or tonumber(values.version)
    if not finite(version) or version < 1 or version ~= math.floor(version) then return nil, invalid('district version is invalid') end
    local displayName = values.displayName or values.name or id
    if not text(displayName, 80) then return nil, invalid('district display name is invalid') end
    return {
        id = id, key = id, displayName = displayName,
        baseline = baseline, baselineDemand = baseline,
        priceModifier = priceModifier, riskModifier = riskModifier, heatModifier = heatModifier,
        allowedZones = allowedZones, streetDiscoveryZones = copy(allowedZones),
        timeCurve = timeCurve, dayCurve = dayCurve,
        maxActiveCustomers = maximum, maxActiveLogicalCustomers = maximum,
        available = available, version = version
    }
end

function District.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(normalized, District)
end

function District.validate(values)
    local normalized, errorResult = District.new(values)
    if not normalized then return errorResult end
    return Result.ok(normalized)
end

function District.copy(value)
    if type(value) ~= 'table' then return nil end
    return setmetatable(copy(value), District)
end

function District:copy()
    return setmetatable(copy(self), District)
end

function District:timeMultiplier(hour)
    hour = tonumber(hour)
    if not hour or hour ~= math.floor(hour) or hour < 0 or hour > 23 then return 1 end
    return self.timeCurve[hour] or 1
end

function District:dayMultiplier(day)
    local normalized = normalizedDay(day)
    return normalized and (self.dayCurve[normalized] or 1) or 1
end

function District:isZoneAllowed(zone)
    if zone == nil or zone == '' then return #self.allowedZones == 0 end
    if #self.allowedZones == 0 then return true end
    zone = tostring(zone):lower()
    for _, value in ipairs(self.allowedZones) do
        if value == zone then return true end
    end
    return false
end

District.allowsZone = District.isZoneAllowed

function District:toConfig()
    return copy(self)
end

NightShift.Domain.District = District
NightShift.District = District
