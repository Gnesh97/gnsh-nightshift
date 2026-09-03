NightShift = NightShift or {}
NightShift.Phone = NightShift.Phone or {}
local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}
local function text(value) return type(value) == 'string' and value:match('^%s*$') == nil and value or nil end
local function validSource(value)
    value = tonumber(value)
    return value and value >= 1 and value == math.floor(value)
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local Registry = {}
Registry.__index = Registry
function Registry.new(options)
    options = type(options) == 'table' and options or {}
    local self = setmetatable({ _providers = {}, _default = text(options.defaultProvider), _logger = options.logger }, Registry)
    if type(options.providers) == 'table' then for name, provider in pairs(options.providers) do self:register(name, provider) end end
    return self
end
function Registry:register(name, provider, metadata)
    name = text(name)
    if not name or type(provider) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'phone provider registration requires a name and provider') end
    if self._providers[name] then
        return Result.err(Codes.PROVIDER_CONFLICT or 'PROVIDER_CONFLICT', 'phone provider is already registered', { provider = name })
    end
    local entry = { name = name, provider = provider, metadata = copy(type(metadata) == 'table' and metadata or {}) }
    self._providers[name] = entry
    if not self._default then self._default = name end
    return Result.ok(self:_describe(entry))
end
function Registry:unregister(name)
    name = text(name)
    if not name then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'phone provider name is required') end
    local existed = self._providers[name] ~= nil
    self._providers[name] = nil
    if self._default == name then self._default = nil; for candidate in pairs(self._providers) do self._default = candidate; break end end
    return Result.ok({ removed = existed, provider = name })
end
function Registry:_describe(entry)
    local provider, capabilities = entry.provider, {}
    if type(provider.getCapabilities) == 'function' then local ok, value = pcall(provider.getCapabilities, provider); if ok and type(value) == 'table' then capabilities = copy(value) end end
    for _, operation in ipairs({ 'registerApp', 'pushNotification', 'openApp' }) do if capabilities[operation] == nil then capabilities[operation] = type(provider[operation]) == 'function' end end
    local available = provider.available == true
    if type(provider.isAvailable) == 'function' then local ok, value = pcall(provider.isAvailable, provider); available = ok and value == true end
    return { name = entry.name, available = available, capabilities = capabilities, metadata = copy(entry.metadata) }
end
function Registry:list()
    local result = {}
    for _, entry in pairs(self._providers) do result[#result + 1] = self:_describe(entry) end
    table.sort(result, function(left, right) return left.name < right.name end)
    return Result.ok(result)
end
function Registry:resolve(name)
    name = text(name) or self._default
    local entry = name and self._providers[name] or nil
    if not entry then return Result.ok({ skipped = true, reason = 'provider-unavailable', provider = name }) end
    local description = self:_describe(entry)
    if not description.available then return Result.ok({ skipped = true, reason = 'provider-unavailable', provider = name, capabilities = description.capabilities }) end
    return Result.ok({ provider = entry.provider, name = name, capabilities = description.capabilities, metadata = copy(entry.metadata) })
end
function Registry:_invoke(operation, providerName, ...)
    local resolved = self:resolve(providerName)
    if not resolved.ok or resolved.value.skipped then return resolved end
    local provider = resolved.value.provider
    if type(provider[operation]) ~= 'function' then return Result.ok({ skipped = true, reason = 'capability-unavailable', provider = resolved.value.name, operation = operation }) end
    local args = { ... }
    for index, value in ipairs(args) do args[index] = copy(value) end
    local ok, response = pcall(provider[operation], provider, table.unpack(args))
    if not ok then
        if self._logger and type(self._logger.warn) == 'function' then pcall(self._logger.warn, self._logger, 'phone', 'phone provider operation failed', { provider = resolved.value.name, operation = operation }) end
        return Result.ok({ skipped = true, reason = 'provider-error', provider = resolved.value.name, operation = operation })
    end
    if type(response) == 'table' and response.ok ~= nil then return response end
    if response == true then return Result.ok({ provider = resolved.value.name, operation = operation }) end
    return Result.ok(type(response) == 'table' and response or { provider = resolved.value.name, operation = operation })
end
function Registry:registerApp(definition, providerName)
    if type(definition) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'phone app definition must be a table') end
    return self:_invoke('registerApp', providerName, definition)
end
function Registry:pushNotification(playerSource, payload, providerName)
    if not validSource(playerSource) or type(payload) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'phone notification requires a valid source and payload') end
    return self:_invoke('pushNotification', providerName, playerSource, payload)
end
function Registry:openApp(playerSource, route, context, providerName)
    if not validSource(playerSource) or type(route) ~= 'string' or route:match('^%s*$') then return Result.err(Codes.PROVIDER_INVALID or 'PROVIDER_INVALID', 'phone navigation requires a valid source and route') end
    return self:_invoke('openApp', providerName, playerSource, route, type(context) == 'table' and context or {})
end
NightShift.Phone.ProviderRegistry = Registry
