NightShift = NightShift or {}
NightShift.Motel = NightShift.Motel or {}
local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}
local function text(value, max)
    if type(value) ~= 'string' then return nil end
    local result = value:match('^%s*(.-)%s*$')
    if result == '' then return nil end
    return result:sub(1, max or 160)
end
local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end
local function validSource(value)
    if value == nil then return true end
    value = tonumber(value); return value and value >= 1 and value == math.floor(value)
end
local function positive(value)
    value = tonumber(value); return value and value > 0 and value == math.floor(value)
end
local function invalid(message) return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', message) end
local function skipped(name, operation, reason)
    return Result.ok({ skipped = true, reason = reason or 'provider-unavailable', provider = name, operation = operation })
end
local aliases = {
    listAvailable = { 'listAvailable', 'getAvailableRooms' }, validate = { 'validate', 'validateRoom' },
    reserve = { 'reserve', 'reserveRoom' }, occupy = { 'occupy' },
    release = { 'release', 'releaseRoom' }, resolveWorldTarget = { 'resolveWorldTarget', 'resolveMeetingTarget' }
}
local function handler(provider, name)
    for _, candidate in ipairs(aliases[name] or { name }) do
        if type(provider[candidate]) == 'function' then return provider[candidate] end
    end
end
local Registry = {}; Registry.__index = Registry
function Registry.new(options)
    options = type(options) == 'table' and options or {}
    local self = setmetatable({ _providers = {}, _default = text(options.defaultProvider, 64), _logger = options.logger }, Registry)
    if type(options.providers) == 'table' then for name, provider in pairs(options.providers) do self:register(name, provider) end end
    return self
end
function Registry:register(name, provider, metadata)
    name = text(name, 64)
    if not name or type(provider) ~= 'table' then return invalid('motel provider registration requires a name and provider') end
    if self._providers[name] then
        return Result.err(Codes.PROVIDER_CONFLICT or 'PROVIDER_CONFLICT', 'motel provider is already registered', { provider = name })
    end
    self._providers[name] = { name = name, provider = provider, metadata = copy(type(metadata) == 'table' and metadata or {}) }
    if not self._default then self._default = name end
    return Result.ok(self:_describe(self._providers[name]))
end
function Registry:unregister(name)
    name = text(name, 64); if not name then return invalid('motel provider name is required') end
    local removed = self._providers[name] ~= nil; self._providers[name] = nil
    if self._default == name then self._default = nil; for candidate in pairs(self._providers) do self._default = candidate; break end end
    return Result.ok({ removed = removed, provider = name })
end
function Registry:_describe(entry)
    local provider, capabilities = entry.provider, {}
    if type(provider.getCapabilities) == 'function' then
        local ok, value = pcall(provider.getCapabilities, provider)
        if ok and type(value) == 'table' then capabilities = copy(value) end
    end
    for _, name in ipairs({ 'listAvailable', 'validate', 'reserve', 'occupy', 'release', 'resolveWorldTarget' }) do
        if capabilities[name] == nil then capabilities[name] = handler(provider, name) ~= nil end
    end
    local available = provider.available == true
    if type(provider.isAvailable) == 'function' then local ok, value = pcall(provider.isAvailable, provider); available = ok and value == true
    elseif provider.available == nil then available = handler(provider, 'listAvailable') ~= nil end
    return { name = entry.name, available = available, capabilities = capabilities, metadata = copy(entry.metadata) }
end
function Registry:list()
    local result = {}; for _, entry in pairs(self._providers) do result[#result + 1] = self:_describe(entry) end
    table.sort(result, function(a, b) return a.name < b.name end); return Result.ok(result)
end
function Registry:resolve(name)
    name = text(name, 64) or self._default; local entry = name and self._providers[name]
    if not entry then return skipped(name, nil) end
    local description = self:_describe(entry)
    if not description.available then return skipped(name, nil) end
    return Result.ok({ provider = entry.provider, name = name, capabilities = description.capabilities, metadata = copy(entry.metadata) })
end
function Registry:_invoke(name, operationName, ...)
    local resolved = self:resolve(name); if not resolved.ok or resolved.value.skipped then return resolved end
    local provider, fn = resolved.value.provider, handler(resolved.value.provider, operationName)
    if not fn then return skipped(resolved.value.name, operationName, 'capability-unavailable') end
    local args = { ... }; for index, value in ipairs(args) do args[index] = copy(value) end
    local ok, response = pcall(fn, provider, table.unpack(args))
    if not ok then
        if self._logger and type(self._logger.warn) == 'function' then pcall(self._logger.warn, self._logger, 'motel', 'motel provider operation failed', { provider = resolved.value.name, operation = operationName }) end
        return Result.err(Codes.PROVIDER_UNAVAILABLE or 'PROVIDER_UNAVAILABLE', 'motel provider operation failed', { provider = resolved.value.name, operation = operationName })
    end
    if type(response) == 'table' and response.ok ~= nil then return response end
    if response == false or response == nil then return Result.err(Codes.PROVIDER_UNAVAILABLE or 'PROVIDER_UNAVAILABLE', 'motel provider operation was rejected', { provider = resolved.value.name, operation = operationName }) end
    return Result.ok(type(response) == 'table' and response or { result = response, operation = operationName, provider = resolved.value.name })
end
function Registry:listAvailable(source, context, providerName)
    if not validSource(source) or (context ~= nil and type(context) ~= 'table') then return invalid('motel availability requires a valid source and context') end
    return self:_invoke(providerName, 'listAvailable', source, type(context) == 'table' and context or {})
end
function Registry:validate(source, locationRef, context, providerName)
    if not validSource(source) or not text(locationRef) or (context ~= nil and type(context) ~= 'table') then return invalid('motel validation requires a valid source, location, and context') end
    return self:_invoke(providerName, 'validate', source, text(locationRef), type(context) == 'table' and context or {})
end
function Registry:reserve(locationRef, bookingId, ttlSeconds, providerName)
    if not text(locationRef) or not text(bookingId) or not positive(ttlSeconds) then return invalid('motel reservation requires location, booking, and positive TTL') end
    return self:_invoke(providerName, 'reserve', text(locationRef), text(bookingId), tonumber(ttlSeconds))
end
function Registry:occupy(locationRef, bookingId, providerName)
    if not text(locationRef) or not text(bookingId) then return invalid('motel occupancy requires location and booking') end
    return self:_invoke(providerName, 'occupy', text(locationRef), text(bookingId))
end
function Registry:release(locationRef, bookingId, providerName)
    if not text(locationRef) or not text(bookingId) then return invalid('motel release requires location and booking') end
    return self:_invoke(providerName, 'release', text(locationRef), text(bookingId))
end
function Registry:resolveWorldTarget(locationRef, context, providerName)
    if not text(locationRef) or (context ~= nil and type(context) ~= 'table') then return invalid('motel world target requires a location and context') end
    return self:_invoke(providerName, 'resolveWorldTarget', text(locationRef), type(context) == 'table' and context or {})
end
Registry.getAvailableRooms = Registry.listAvailable; Registry.validateRoom = Registry.validate
Registry.reserveRoom = Registry.reserve; Registry.releaseRoom = Registry.release
NightShift.Motel.ProviderRegistry = Registry
