NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Resolver = {}
Resolver.__index = Resolver

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function text(value, max)
    if type(value) ~= 'string' then return nil end
    local result = value:match('^%s*(.-)%s*$')
    if result == '' then return nil end
    return result:sub(1, max or 64)
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    return pcall(fn, ...)
end

local function makeAdapter(factory, options)
    if type(factory) == 'table' then return factory end
    if type(factory) ~= 'function' then return nil end
    local ok, value = pcall(factory, options or {})
    return ok and value or nil
end

local function defaultState(resource)
    local getState = rawget(_G, 'GetResourceState')
    if type(getState) ~= 'function' then return nil end
    local ok, value = pcall(getState, resource)
    return ok and value or nil
end

local function stateStarted(state)
    return state == 'started' or state == 'starting'
end

function Resolver.new(options)
    options = options or {}
    local frameworkFactories = options.frameworkFactories or {}
    local frameworkAdapters = options.frameworkAdapters or {}
    local moneyFactories = options.moneyFactories or {}
    local moneyAdapters = options.moneyAdapters or {}
    local frameworkOptions = options.frameworkOptions or {}
    local moneyOptions = options.moneyOptions or {}
    if next(frameworkFactories) == nil and next(frameworkAdapters) == nil and NightShift.FrameworkAdapters then
        for name, factory in pairs(NightShift.FrameworkAdapters) do frameworkFactories[name] = function() return factory.new(frameworkOptions[name] or {}) end end
    end
    if next(moneyFactories) == nil and next(moneyAdapters) == nil and NightShift.MoneyAdapters then
        for name, factory in pairs(NightShift.MoneyAdapters) do moneyFactories[name] = function() return factory.new(moneyOptions[name] or {}) end end
    end
    return setmetatable({
        registry = options.registry or NightShift.ProviderRegistry or {},
        frameworkFactories = frameworkFactories,
        frameworkAdapters = frameworkAdapters,
        moneyFactories = moneyFactories,
        moneyAdapters = moneyAdapters,
        frameworkOptions = frameworkOptions,
        moneyOptions = moneyOptions,
        optionalProviders = options.optionalProviders or {},
        optionalFactories = options.optionalFactories or {},
        resourceState = options.resourceState or defaultState,
        resourceNames = options.resourceNames or { qbcore = 'qb-core', qbox = 'qbx_core', esx = 'es_extended' },
        dependencies = options.dependencies or {},
        requireResourceState = options.requireResourceState == true,
        logger = options.logger
    }, Resolver)
end

function Resolver:_framework(name)
    if self.frameworkAdapters[name] ~= nil then return self.frameworkAdapters[name] end
    local factory = self.frameworkFactories[name]
    local adapter = makeAdapter(factory, self.frameworkOptions[name])
    if adapter then self.frameworkAdapters[name] = adapter end
    return adapter
end

function Resolver:_money(name)
    if self.moneyAdapters[name] ~= nil then return self.moneyAdapters[name] end
    local factory = self.moneyFactories[name]
    local adapter = makeAdapter(factory, self.moneyOptions[name])
    if adapter then self.moneyAdapters[name] = adapter end
    return adapter
end

function Resolver:_isAvailable(adapter)
    if type(adapter) ~= 'table' then return false end
    if type(adapter.isAvailable) == 'function' then
        local ok, value = pcall(adapter.isAvailable, adapter)
        return ok and value == true
    end
    return adapter.available == true
end

function Resolver:_resourceAvailable(name)
    local resource = self.resourceNames[name]
    if not resource or type(self.resourceState) ~= 'function' then return nil end
    local ok, state = pcall(self.resourceState, resource)
    if not ok then return nil end
    return stateStarted(state), state
end

function Resolver:detect()
    local candidates = {}
    for _, name in ipairs({ 'qbcore', 'qbox', 'esx' }) do
        local adapter = self:_framework(name)
        local resourceAvailable, state = self:_resourceAvailable(name)
        local detected = resourceAvailable
        if detected == nil then detected = self:_isAvailable(adapter) end
        if detected and self:_isAvailable(adapter) then
            candidates[#candidates + 1] = { name = name, adapter = adapter, state = state, capabilities = type(adapter.getCapabilities) == 'function' and adapter:getCapabilities() or {} }
        end
    end
    if #candidates == 0 then
        local standalone = self:_framework('standalone')
        if standalone and self:_isAvailable(standalone) then
            candidates[#candidates + 1] = { name = 'standalone', adapter = standalone, state = nil, capabilities = type(standalone.getCapabilities) == 'function' and standalone:getCapabilities() or {} }
        end
    end
    return candidates
end

function Resolver:detectProvider()
    local candidates = self:detect()
    if #candidates ~= 1 then return false end
    local candidate = candidates[1]
    return { name = candidate.name, supported = true, available = true, capabilities = copy(candidate.capabilities) }
end

function Resolver:_validateDependency(name, adapter)
    local required = self.dependencies[name]
    if type(required) ~= 'table' then
        local resource = self.resourceNames[name]
        required = resource and { resource } or {}
    end
    if #required == 0 or type(self.resourceState) ~= 'function' then return true end
    for _, resource in ipairs(required) do
        local ok, state = pcall(self.resourceState, resource)
        if ok and state ~= nil and not stateStarted(state) then
            return Result.err(Codes.PROVIDER_DEPENDENCY_MISSING, 'provider dependency is not started', { provider = name, resource = resource, state = state })
        end
    end
    if self.requireResourceState and not self:_isAvailable(adapter) then
        return Result.err(Codes.PROVIDER_UNAVAILABLE, 'configured provider is unavailable', { provider = name })
    end
    return true
end

local function optionalFactory(factory, options)
    if type(factory) == 'table' and type(factory.new) == 'function' then return factory.new(options or {}) end
    if type(factory) == 'function' then
        local ok, value = pcall(factory, options or {})
        return ok and value or nil
    end
    return nil
end

function Resolver:_optional()
    local factories = self.optionalFactories
    local builtins = NightShift.OptionalProviders or {}
    local names = { 'Phone', 'Housing', 'Motel', 'Dispatch', 'Appearance', 'Evidence', 'Target', 'Notify' }
    local result, missing = {}, {}
    for _, name in ipairs(names) do
        local key = name:sub(1, 1):lower() .. name:sub(2)
        local provider = self.optionalProviders[key]
        if provider == nil then provider = optionalFactory(factories[key], {}) end
        if provider == nil then provider = optionalFactory(builtins[name], {}) end
        if provider ~= nil then result[key] = provider else missing[#missing + 1] = key end
    end
    return result, missing
end

function Resolver:resolve(config, context)
    context = type(context) == 'table' and context or {}
    config = type(config) == 'table' and config or {}
    local selection = config.provider or config.providerSelection or {}
    if type(selection) == 'string' then selection = { mode = 'explicit', name = selection } end
    if type(selection) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'provider selection must be a table') end
    local mode = rawget(selection, 'mode')
    if mode == nil then mode = 'auto' end
    local selectedValue = rawget(selection, 'name')
    if selectedValue == nil then selectedValue = rawget(selection, 'provider') end
    local selected = text(selectedValue)
    local candidates = self:detect()
    local candidateNames = {}
    for _, item in ipairs(candidates) do candidateNames[#candidateNames + 1] = item.name end
    if mode == 'explicit' then
        if not selected or not self.registry[selected] then return Result.err(Codes.UNKNOWN_PROVIDER, 'provider is not allowlisted', { provider = selected }) end
    elseif mode == 'auto' then
        if #candidates ~= 1 then
            if #candidates > 1 then return Result.err(Codes.PROVIDER_AMBIGUOUS, 'multiple framework providers are available', { candidates = candidateNames }) end
            return Result.err(Codes.PROVIDER_UNAVAILABLE, 'no supported provider was detected', { candidates = candidateNames })
        end
        selected = candidates[1].name
    else
        return Result.err(Codes.PROVIDER_INVALID, 'provider mode must be auto or explicit', { mode = mode })
    end
    local framework = self:_framework(selected)
    if not framework or (not self:_isAvailable(framework) and selected ~= 'standalone') then
        return Result.err(Codes.PROVIDER_UNAVAILABLE, 'configured framework provider is unavailable', { provider = selected })
    end
    local dependency = self:_validateDependency(selected, framework)
    if dependency ~= true then return dependency end
    if NightShift.FrameworkInterface and not NightShift.FrameworkInterface.isValid(framework) then
        return Result.err(Codes.PROVIDER_INVALID, 'configured framework adapter violates the interface', { provider = selected })
    end
    local money = self:_money(selected)
    if not money and selected ~= 'standalone' then return Result.err(Codes.PROVIDER_DEPENDENCY_MISSING, 'money adapter is not configured', { provider = selected }) end
    local features = config.features or {}
    if features.deposits == true and (not money or type(money.isAvailable) == 'function' and not money:isAvailable()) then
        return Result.err(Codes.PROVIDER_DEPENDENCY_MISSING, 'deposits require an available money adapter', { provider = selected })
    end
    local optional, missingOptional = self:_optional()
    local capabilitySummary = {
        framework = type(framework.getCapabilities) == 'function' and framework:getCapabilities() or {},
        money = money and type(money.getCapabilities) == 'function' and money:getCapabilities() or {},
        optional = {}
    }
    for name, provider in pairs(optional) do
        capabilitySummary.optional[name] = type(provider.getCapabilities) == 'function' and provider:getCapabilities() or {}
    end
    local diagnostics = {
        selected = selected,
        mode = mode,
        candidates = candidateNames,
        missingOptional = missingOptional,
        dependenciesValidated = true
    }
    if self.logger and type(self.logger.info) == 'function' then pcall(self.logger.info, self.logger, 'providers', 'providers resolved', diagnostics) end
    return Result.ok({
        framework = framework,
        money = money,
        optional = optional,
        providers = optional,
        capabilities = capabilitySummary,
        diagnostics = diagnostics
    })
end

function Resolver.detectForConfig(options)
    local resolver = Resolver.new(options)
    return resolver:detectProvider()
end

NightShift.ProviderResolver = Resolver
