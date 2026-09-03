NightShift = NightShift or {}
NightShift.Housing = NightShift.Housing or {}

local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}

local function text(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or nil
end

local function copy(value)
    if type(value) ~= 'table' then return value end
    local output = {}
    for key, item in pairs(value) do output[copy(key)] = copy(item) end
    return output
end

local Registry = {}
Registry.__index = Registry

function Registry.new(options)
    options = type(options) == 'table' and options or {}
    local self = setmetatable({
        _providers = {},
        _default = text(options.defaultProvider),
        _logger = options.logger
    }, Registry)
    if type(options.providers) == 'table' then
        for name, provider in pairs(options.providers) do self:register(name, provider) end
    end
    return self
end

function Registry:register(name, provider, metadata)
    name = text(name)
    if not name or type(provider) ~= 'table' then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing provider registration requires a name and provider')
    end
    if self._providers[name] then
        return Result.err(Codes.PROVIDER_CONFLICT or 'PROVIDER_CONFLICT', 'housing provider is already registered', { provider = name })
    end
    local entry = { name = name, provider = provider, metadata = copy(type(metadata) == 'table' and metadata or {}) }
    self._providers[name] = entry
    if not self._default then self._default = name end
    return Result.ok(self:_describe(entry))
end

function Registry:unregister(name)
    name = text(name)
    if not name then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing provider name is required') end
    local existed = self._providers[name] ~= nil
    self._providers[name] = nil
    if self._default == name then
        self._default = nil
        for candidate in pairs(self._providers) do self._default = candidate; break end
    end
    return Result.ok({ removed = existed, provider = name })
end

function Registry:_describe(entry)
    local provider, capabilities = entry.provider, {}
    if type(provider.getCapabilities) == 'function' then
        local ok, value = pcall(provider.getCapabilities, provider)
        if ok and type(value) == 'table' then capabilities = copy(value) end
    end
    for _, operation in ipairs({
        'listAccessible', 'listAvailable', 'validateAccess', 'validate',
        'reserve', 'occupy', 'release', 'resolveMeetingTarget',
        'resolveWorldTarget', 'isInteriorReady'
    }) do
        if capabilities[operation] == nil then capabilities[operation] = type(provider[operation]) == 'function' end
    end
    local available = provider.available == true
    if type(provider.isAvailable) == 'function' then
        local ok, value = pcall(provider.isAvailable, provider)
        available = ok and value == true
    elseif provider.available == nil then
        available = type(provider.listAccessible) == 'function'
            or type(provider.listAvailable) == 'function'
    end
    return { name = entry.name, available = available, capabilities = capabilities, metadata = copy(entry.metadata) }
end

function Registry:list()
    local output = {}
    for _, entry in pairs(self._providers) do output[#output + 1] = self:_describe(entry) end
    table.sort(output, function(left, right) return left.name < right.name end)
    return Result.ok(output)
end

function Registry:resolve(name)
    name = text(name) or self._default
    local entry = name and self._providers[name] or nil
    if not entry then return Result.ok({ skipped = true, reason = 'provider-unavailable', provider = name }) end
    local description = self:_describe(entry)
    if not description.available then
        return Result.ok({ skipped = true, reason = 'provider-unavailable', provider = name, capabilities = description.capabilities })
    end
    return Result.ok({ provider = entry.provider, name = name, capabilities = description.capabilities, metadata = copy(entry.metadata) })
end

function Registry:_invoke(operation, providerName, ...)
    local resolved = self:resolve(providerName)
    if not resolved.ok or resolved.value.skipped then return resolved end
    local provider = resolved.value.provider
    if type(provider[operation]) ~= 'function' then
        return Result.ok({ skipped = true, reason = 'capability-unavailable', provider = resolved.value.name, operation = operation })
    end
    local args = { ... }
    for index, value in ipairs(args) do args[index] = copy(value) end
    local ok, response = pcall(provider[operation], provider, table.unpack(args))
    if not ok then
        if self._logger and type(self._logger.warn) == 'function' then
            pcall(self._logger.warn, self._logger, 'housing', 'housing provider operation failed', {
                provider = resolved.value.name, operation = operation
            })
        end
        return Result.err(Codes.PROVIDER_UNAVAILABLE or 'PROVIDER_UNAVAILABLE',
            'housing provider operation failed',
            { provider = resolved.value.name, operation = operation })
    end
    if type(response) == 'table' and response.ok ~= nil then return response end
    if response == false and operation == 'isInteriorReady' then
        return Result.ok({ ready = false, provider = resolved.value.name })
    end
    if response == true then
        if operation == 'isInteriorReady' then return Result.ok({ ready = true, provider = resolved.value.name }) end
        local stateKeys = { reserve = 'reserved', occupy = 'occupied', release = 'released', validate = 'valid', validateAccess = 'valid' }
        if stateKeys[operation] then return Result.ok({ [stateKeys[operation]] = true, provider = resolved.value.name }) end
        return Result.ok({ provider = resolved.value.name, operation = operation })
    end
    return Result.ok(type(response) == 'table' and response or { provider = resolved.value.name, operation = operation, result = response })
end

function Registry:listAccessible(playerSource, context, providerName)
    if playerSource ~= nil and (not tonumber(playerSource) or tonumber(playerSource) < 1) then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing availability source is invalid')
    end
    local resolved = self:resolve(providerName)
    if not resolved.ok or resolved.value.skipped then return resolved end
    local provider = resolved.value.provider
    local operation = type(provider.listAccessible) == 'function' and 'listAccessible' or 'listAvailable'
    return self:_invoke(operation, providerName, playerSource, type(context) == 'table' and context or {})
end

function Registry:validateAccess(playerSource, propertyRef, phase, context, providerName)
    if playerSource ~= nil and (not tonumber(playerSource) or tonumber(playerSource) < 1) then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing access source is invalid')
    end
    propertyRef, phase = text(propertyRef), text(phase) or 'booking'
    if not propertyRef then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing property reference is required') end
    if phase ~= 'booking' and phase ~= 'arrival' then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing access phase must be booking or arrival')
    end
    local resolved = self:resolve(providerName)
    if not resolved.ok or resolved.value.skipped then return resolved end
    local provider = resolved.value.provider
    if type(provider.validateAccess) == 'function' then
        return self:_invoke('validateAccess', providerName, playerSource, propertyRef, phase, type(context) == 'table' and context or {})
    end
    local details = copy(type(context) == 'table' and context or {})
    details.phase = phase
    return self:_invoke('validate', providerName, playerSource, propertyRef, details)
end

function Registry:resolveMeetingTarget(propertyRef, context, providerName)
    propertyRef = text(propertyRef)
    if not propertyRef then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing meeting property reference is required') end
    local resolved = self:resolve(providerName)
    if not resolved.ok or resolved.value.skipped then return resolved end
    local provider = resolved.value.provider
    local operation = type(provider.resolveMeetingTarget) == 'function' and 'resolveMeetingTarget' or 'resolveWorldTarget'
    return self:_invoke(operation, providerName, propertyRef, type(context) == 'table' and context or {})
end

function Registry:isInteriorReady(propertyRef, context, providerName)
    propertyRef = text(propertyRef)
    if not propertyRef then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'housing interior property reference is required') end
    return self:_invoke('isInteriorReady', providerName, propertyRef, type(context) == 'table' and context or {})
end

function Registry:reserve(propertyRef, bookingId, ttlSeconds, providerName)
    propertyRef, bookingId = text(propertyRef), text(bookingId)
    local ttl = tonumber(ttlSeconds)
    if not propertyRef or not bookingId or not ttl or ttl < 1 or ttl ~= math.floor(ttl) then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID',
            'housing reservation requires property, booking, and positive TTL')
    end
    return self:_invoke('reserve', providerName, propertyRef, bookingId, ttl)
end

function Registry:occupy(propertyRef, bookingId, providerName)
    propertyRef, bookingId = text(propertyRef), text(bookingId)
    if not propertyRef or not bookingId then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID',
            'housing occupancy requires property and booking')
    end
    return self:_invoke('occupy', providerName, propertyRef, bookingId)
end

function Registry:release(propertyRef, bookingId, providerName)
    propertyRef, bookingId = text(propertyRef), text(bookingId)
    if not propertyRef or not bookingId then
        return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID',
            'housing release requires property and booking')
    end
    return self:_invoke('release', providerName, propertyRef, bookingId)
end

NightShift.Housing.ProviderRegistry = Registry
