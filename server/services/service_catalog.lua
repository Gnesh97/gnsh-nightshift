NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Catalog = {}
Catalog.__index = Catalog

local DEFAULT_MODES = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }

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

local function token(value, maxLength)
    return text(value, maxLength) and value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') ~= nil
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.SERVICE_CATALOG_INVALID, message, details)
end

local function notFound(id)
    return Result.err(Codes.SERVICE_PACKAGE_NOT_FOUND, 'service package was not found', { id = id })
end

local function array(value, field)
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be an array') end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or math.floor(key) ~= key then return nil, invalid(field .. ' must be contiguous') end
        count = count + 1
    end
    for index = 1, count do if rawget(value, index) == nil then return nil, invalid(field .. ' must be contiguous') end end
    return count
end

local function normalizeList(value, field, default)
    if value == nil then value = default end
    local count, errorResult = array(value, field)
    if not count then return nil, errorResult end
    local output, seen = {}, {}
    for index = 1, count do
        local item = value[index]
        if not text(item, 96) or not token(item, 96) then return nil, invalid(field .. ' contains an invalid value', { index = index }) end
        item = item:upper()
        if not seen[item] then
            seen[item] = true
            output[#output + 1] = item
        end
    end
    return output
end

local function normalizePackage(raw, index, defaultCurrency)
    if type(raw) ~= 'table' then return nil, invalid('service package must be a table', { index = index }) end
    local id = raw.id or raw.key or raw.name
    if not text(id, 96) or not token(id, 96) then return nil, invalid('service package ID is invalid', { index = index, field = 'id' }) end
    id = id:lower()
    local price = raw.basePriceMinor
    if price == nil then price = raw.basePrice end
    if price == nil then price = raw.priceMinor end
    if price == nil then price = raw.price end
    price = integer(price, 1, 100000000000)
    if not price then return nil, Result.err(Codes.INVALID_PRICE, 'service package base price is invalid', { index = index }) end
    local duration = raw.durationMinutes
    if duration == nil then duration = raw.duration end
    duration = integer(duration, 1, 10080)
    if not duration then return nil, Result.err(Codes.INVALID_DURATION, 'service package duration is invalid', { index = index }) end
    local currency = raw.currency or defaultCurrency or 'USD'
    currency = type(currency) == 'string' and currency:upper() or nil
    if not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('service package currency is invalid', { index = index }) end
    local minimum = raw.minClientReputation
    if minimum == nil then minimum = raw.minReputation end
    if minimum == nil then minimum = raw.reputationRequired end
    minimum = integer(minimum or 0, 0, 1000000)
    if not minimum then return nil, invalid('service package reputation requirement is invalid', { index = index }) end
    local modes, modeError = normalizeList(raw.meetingModes or raw.modes, 'servicePackages[' .. index .. '].meetingModes', DEFAULT_MODES)
    if not modes then return nil, modeError end
    local locations, locationError = normalizeList(raw.locationIds or raw.locations, 'servicePackages[' .. index .. '].locationIds', {})
    if not locations then return nil, locationError end
    local categories, categoryError = normalizeList(raw.locationCategories or raw.categories, 'servicePackages[' .. index .. '].locationCategories', {})
    if not categories then return nil, categoryError end
    return {
        id = id,
        priceMinor = price,
        basePriceMinor = price,
        durationMinutes = duration,
        currency = currency,
        minClientReputation = minimum,
        meetingModes = modes,
        locationIds = locations,
        locationCategories = categories
    }
end

local function normalizeConfig(source)
    source = source or NightShift.ServiceCatalogConfig or {}
    if type(source) == 'table' and source.servicePackages ~= nil and source.packages == nil then
        source = { enabled = source.enabled, currency = source.currency, packages = source.servicePackages }
    end
    if type(source) ~= 'table' then return nil, invalid('service catalog configuration must be a table') end
    local enabled = source.enabled == nil and true or source.enabled
    if type(enabled) ~= 'boolean' then return nil, invalid('service catalog enabled flag must be boolean') end
    local currency = source.currency or 'USD'
    currency = type(currency) == 'string' and currency:upper() or nil
    if not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('service catalog currency is invalid') end
    local rawPackages = source.packages
    if rawPackages == nil then rawPackages = source.servicePackages end
    if rawPackages == nil and NightShift.DefaultConfig then rawPackages = NightShift.DefaultConfig.servicePackages end
    local count, arrayError = array(rawPackages or {}, 'servicePackages')
    if not count then return nil, arrayError end
    if count == 0 and enabled then return nil, invalid('service catalog requires at least one package') end
    local packages, byId = {}, {}
    for index = 1, count do
        local package, packageError = normalizePackage(rawPackages[index], index, currency)
        if not package then return nil, packageError end
        if byId[package.id] then return nil, Result.err(Codes.DUPLICATE_ID, 'duplicate service package ID', { id = package.id }) end
        byId[package.id] = package
        packages[index] = package
    end
    return { enabled = enabled, currency = currency, packages = packages, byId = byId }
end

function Catalog.new(options)
    options = options or {}
    local source = options.config or options.services or NightShift.ServiceCatalogConfig
    local normalized, errorResult = normalizeConfig(source)
    if not normalized then return nil, errorResult end
    if options.enabled ~= nil then
        if type(options.enabled) ~= 'boolean' then return nil, invalid('service catalog enabled flag must be boolean') end
        normalized.enabled = options.enabled
    end
    return setmetatable({ _config = normalized, _enabled = normalized.enabled }, Catalog)
end

function Catalog:isEnabled()
    return self._enabled == true
end

function Catalog:configuration()
    return copy(self._config)
end

function Catalog:get(id)
    if not self:isEnabled() then return Result.err(Codes.SERVICE_CATALOG_INVALID, 'service catalog is disabled') end
    if not text(id, 96) or not token(id, 96) then return notFound(id) end
    local package = self._config.byId[id:lower()]
    if not package then return notFound(id) end
    return Result.ok(copy(package))
end

function Catalog:list()
    if not self:isEnabled() then return Result.err(Codes.SERVICE_CATALOG_INVALID, 'service catalog is disabled') end
    return Result.ok(copy(self._config.packages))
end

function Catalog:resolve(id, context)
    local found = self:get(id)
    if not found.ok then return found end
    context = context or {}
    if type(context) ~= 'table' then return invalid('service package context must be a table') end
    local package = found.value
    local meetingMode = context.meetingMode or context.mode
    if meetingMode ~= nil then
        if not token(meetingMode, 32) then return Result.err(Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'meeting mode is invalid') end
        meetingMode = meetingMode:upper()
        local allowed = false
        for _, mode in ipairs(package.meetingModes) do if mode == meetingMode then allowed = true break end end
        if not allowed then return Result.err(Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'service package does not support the meeting mode', { id = package.id, meetingMode = meetingMode }) end
    end
    local location = context.locationId or context.locationRef
    if type(context.location) == 'table' then location = location or context.location.id or context.location.ref end
    if location ~= nil and #package.locationIds > 0 then
        if not text(location, 160) then return Result.err(Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'location reference is invalid') end
        local allowed = false
        for _, locationId in ipairs(package.locationIds) do if locationId == location or locationId == tostring(location):upper() then allowed = true break end end
        if not allowed then return Result.err(Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'service package is not available at the location', { id = package.id, location = location }) end
    end
    local category = context.locationCategory or context.category
    if category ~= nil and #package.locationCategories > 0 then
        category = tostring(category):upper()
        local allowed = false
        for _, value in ipairs(package.locationCategories) do if value == category then allowed = true break end end
        if not allowed then return Result.err(Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'service package is not available for the location category', { id = package.id, category = category }) end
    end
    if package.minClientReputation > 0 then
        local reputation = tonumber(context.clientReputation or context.reputation)
        if not reputation or reputation < package.minClientReputation then
            return Result.err(Codes.SERVICE_PACKAGE_REQUIREMENT_FAILED, 'client reputation requirement is not met', { id = package.id, required = package.minClientReputation }) end
    end
    return Result.ok(package)
end

function Catalog:toBookingPackage(package)
    package = type(package) == 'table' and package or {}
    return {
        id = package.id,
        priceMinor = package.priceMinor or package.basePriceMinor,
        durationMinutes = package.durationMinutes or package.duration,
        currency = package.currency or self._config.currency
    }
end

Catalog.find = Catalog.get
Catalog.lookup = Catalog.get
Catalog.getPackage = Catalog.get
Catalog.resolvePackage = Catalog.resolve
Catalog.validate = Catalog.resolve

function Catalog:resolver(id, input)
    return self:resolve(id, input)
end

NightShift.ServiceCatalog = Catalog
NightShift.Services.ServiceCatalog = Catalog
