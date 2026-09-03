NightShift = NightShift or {}
NightShift.Server = NightShift.Server or {}

local Result = NightShift.Result
local Api = {}
Api.__index = Api

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value)
    return type(value) == 'string' and #value > 0 and #value <= 64 and value:match('^[%w%._%-]+$') ~= nil
end

local function err(code, message, details)
    return Result.err(code, message, details)
end

local function unavailable(id)
    return err('PROVIDER_UNAVAILABLE', 'location provider is unavailable', { provider = id })
end

local required = { 'listAvailable', 'validate', 'resolveWorldTarget' }

function Api.new(options)
    options = type(options) == 'table' and copy(options) or {}
    return setmetatable({
        _providers = {},
        _logger = options.logger,
        _surfaceInstalled = false,
        _locationServices = {}
    }, Api)
end

function Api:_log(level, message, details)
    if type(self._logger) == 'function' then
        pcall(self._logger, level, message, copy(details))
    end
end

function Api:_validateProvider(provider)
    if type(provider) ~= 'table' or not text(provider.id or provider.name) then
        return nil, err('PROVIDER_INVALID', 'location provider id is required')
    end
    local id = provider.id or provider.name
    for _, method in ipairs(required) do
        if type(provider[method]) ~= 'function' then
            return nil, err('PROVIDER_INVALID', 'location provider method is required', { provider = id, method = method })
        end
    end
    if provider.capabilities ~= nil and type(provider.capabilities) ~= 'table' then
        return nil, err('PROVIDER_INVALID', 'location provider capabilities must be a table', { provider = id })
    end
    local capabilities = copy(provider.capabilities or {})
    for _, method in ipairs(required) do
        if capabilities[method] == nil then capabilities[method] = true end
        if capabilities[method] ~= true then
            return nil, err('PROVIDER_INVALID', 'required location provider capability is disabled', { provider = id, capability = method })
        end
    end
    if provider.isAvailable ~= nil and type(provider.isAvailable) ~= 'function' and type(provider.isAvailable) ~= 'boolean' then
        return nil, err('PROVIDER_INVALID', 'location provider availability must be a function or boolean', { provider = id })
    end
    return {
        id = id,
        resource = text(provider.resource) and provider.resource or nil,
        provider = provider,
        capabilities = capabilities
    }
end

function Api:register(provider)
    local record, validationError = self:_validateProvider(provider)
    if not record then return validationError end
    if self._providers[record.id] then
        return err('PROVIDER_CONFLICT', 'location provider is already registered', { provider = record.id })
    end
    self._providers[record.id] = record
    local facades = self:providerMap()
    for _, service in ipairs(self._locationServices) do
        if type(service._providers) == 'table' then service._providers[record.id] = facades[record.id] end
    end
    self:_log('info', 'location provider registered', { provider = record.id, resource = record.resource })
    return Result.ok({ id = record.id, capabilities = copy(record.capabilities), resource = record.resource })
end

function Api:unregister(id)
    if not text(id) then return err('PROVIDER_INVALID', 'location provider id is required') end
    if not self._providers[id] then return err('PROVIDER_NOT_FOUND', 'location provider is not registered', { provider = id }) end
    self._providers[id] = nil
    for _, service in ipairs(self._locationServices) do
        if type(service._providers) == 'table' then service._providers[id] = nil end
    end
    return Result.ok({ id = id, unregistered = true })
end

function Api:list()
    local output = {}
    for id, record in pairs(self._providers) do
        local available = record.provider.isAvailable
        if type(available) == 'function' then
            local ok, value = pcall(available, record.provider)
            available = ok and value == true
        elseif available == nil then
            available = true
        end
        output[#output + 1] = {
            id = id,
            resource = record.resource,
            available = available == true,
            capabilities = copy(record.capabilities)
        }
    end
    table.sort(output, function(left, right) return left.id < right.id end)
    return Result.ok(output)
end

function Api:isAvailable(id)
    local record = self._providers[id]
    if not record then return false end
    local available = record.provider.isAvailable
    if type(available) == 'function' then
        local ok, value = pcall(available, record.provider)
        return ok and value == true
    end
    return available ~= false
end

function Api:resolve(id, method, ...)
    if not text(id) or type(method) ~= 'string' or #method > 48 or not method:match('^[%w_]+$') then
        return err('PROVIDER_INVALID', 'provider and operation are required')
    end
    local record = self._providers[id]
    if not record then return err('PROVIDER_NOT_FOUND', 'location provider is not registered', { provider = id }) end
    if not self:isAvailable(id) then return unavailable(id) end
    if type(record.provider[method]) ~= 'function' or record.capabilities[method] ~= true then
        return err('PROVIDER_CAPABILITY_UNSUPPORTED', 'location provider capability is unavailable', { provider = id, capability = method })
    end
    local arguments = { ... }
    local ok, result, providerError = pcall(record.provider[method], record.provider, table.unpack(copy(arguments)))
    if not ok then
        self:_log('error', 'location provider operation failed', { provider = id, method = method, error = result })
        return err('PROVIDER_OPERATION_FAILED', 'location provider operation failed', { provider = id, method = method })
    end
    if result == nil and providerError ~= nil then
        local providerResult = type(providerError) == 'table' and providerError or nil
        if providerResult and providerResult.ok ~= nil then return copy(providerResult) end
        return err('PROVIDER_OPERATION_FAILED', 'location provider operation failed',
            { provider = id, method = method, cause = tostring(providerError) })
    end
    if type(result) ~= 'table' then return Result.ok(copy(result)) end
    if result.ok ~= nil then return copy(result) end
    return Result.ok(copy(result))
end

-- Expose safe facades for LocationService/LocationReservationService.  The
-- underlying provider objects never leave this API directly, so a caller
-- cannot mutate the registry entry while still receiving the typed provider
-- contract used by the core location services.
function Api:providerMap()
    local output = {}
    for id, record in pairs(self._providers) do
        local providerId = id
        local facade = {
            name = providerId,
            id = providerId,
            isAvailable = function()
                return self:isAvailable(providerId)
            end,
            getCapabilities = function()
                local listed = self:list()
                for _, item in ipairs(listed.value or {}) do
                    if item.id == providerId then return copy(item.capabilities) end
                end
                return {}
            end
        }
        local operations = {
            listAvailable = function(_, source, context)
                return self:resolve(providerId, 'listAvailable', source, context)
            end,
            validate = function(_, source, locationRef, context)
                return self:resolve(providerId, 'validate', source, locationRef, context)
            end,
            resolveWorldTarget = function(_, locationRef, context)
                return self:resolve(providerId, 'resolveWorldTarget', locationRef, context)
            end,
            reserve = function(_, locationRef, bookingId, ttlSeconds)
                return self:resolve(providerId, 'reserve', locationRef, bookingId, ttlSeconds)
            end,
            occupy = function(_, locationRef, bookingId)
                return self:resolve(providerId, 'occupy', locationRef, bookingId)
            end,
            release = function(_, locationRef, bookingId)
                return self:resolve(providerId, 'release', locationRef, bookingId)
            end
        }
        for operation, handler in pairs(operations) do
            if record.capabilities[operation] == true then facade[operation] = handler end
        end
        output[id] = facade
    end
    return output
end

Api.getProviderMap = Api.providerMap

function Api:attachLocationService(service)
    if type(service) ~= 'table' or type(service._providers) ~= 'table' then
        return err('PROVIDER_INVALID', 'location service attachment is invalid')
    end
    for _, existing in ipairs(self._locationServices) do
        if existing == service then return Result.ok({ attached = true, idempotent = true }) end
    end
    self._locationServices[#self._locationServices + 1] = service
    local facades = self:providerMap()
    for id, facade in pairs(facades) do service._providers[id] = facade end
    return Result.ok({ attached = true, providers = #self._locationServices })
end

function Api:installSurface(options)
    if self._surfaceInstalled then return Result.ok({ installed = true, idempotent = true }) end
    options = type(options) == 'table' and options or {}
    local export = type(exports) == 'function' and exports or rawget(_G, 'exports')
    local registerNetEvent = type(RegisterNetEvent) == 'function' and RegisterNetEvent or rawget(_G, 'RegisterNetEvent')
    local addEventHandler = type(AddEventHandler) == 'function' and AddEventHandler or rawget(_G, 'AddEventHandler')
    local triggerEvent = type(TriggerEvent) == 'function' and TriggerEvent or rawget(_G, 'TriggerEvent')
    local installed = false
    if type(export) == 'function' then
        export(options.exportName or 'resolveLocationProvider', function(id, method, ...)
            return self:resolve(id, method, ...)
        end)
        export(options.registerExportName or 'registerLocationProvider', function(provider)
            return self:register(provider)
        end)
        export(options.unregisterExportName or 'unregisterLocationProvider', function(id)
            return self:unregister(id)
        end)
        export(options.listExportName or 'listLocationProviders', function()
            return self:list()
        end)
        installed = true
    end
    if type(registerNetEvent) == 'function' and type(addEventHandler) == 'function' then
        local eventName = options.eventName or 'gnsh-nightshift:location-provider:resolve'
        registerNetEvent(eventName)
        addEventHandler(eventName, function(requestId, id, method, ...)
            local eventSource = rawget(_G, 'source')
            if eventSource ~= nil and tonumber(eventSource) ~= 0 then return end
            local result = self:resolve(id, method, ...)
            if type(triggerEvent) == 'function' then
                triggerEvent((options.resultEvent or 'gnsh-nightshift:location-provider:resolved'), requestId, copy(result))
            end
        end)
        installed = true
    end
    self._surfaceInstalled = installed
    return Result.ok({ installed = installed, export = type(export) == 'function', event = type(registerNetEvent) == 'function' and type(addEventHandler) == 'function' })
end

Api.registerProvider = Api.register
Api.unregisterProvider = Api.unregister
Api.listProviders = Api.list

NightShift.Server.LocationProviderApi = Api
