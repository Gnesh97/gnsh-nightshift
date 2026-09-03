NightShift = NightShift or {}
NightShift.PhoneAdapters = NightShift.PhoneAdapters or {}

local Phone = NightShift.OptionalProviders and NightShift.OptionalProviders.Phone

local function started(options)
    if type(options.resource) ~= 'string' or options.resource == '' then return true end
    if type(options.resourceState) == 'function' then
        local ok, state = pcall(options.resourceState, options.resource)
        return ok and state == 'started'
    end
    if type(GetResourceState) == 'function' then
        local ok, state = pcall(GetResourceState, options.resource)
        return ok and state == 'started'
    end
    return false
end

local function callback(options, aliases)
    for _, key in ipairs(aliases or {}) do
        if type(options[key]) == 'function' then return options[key] end
    end
    return nil
end

local function factory(name, aliases)
    return function(options)
        options = options or {}
        local available = options.available ~= false and started(options)
        local adapterOptions = {
            available = available,
            registerApp = callback(options, aliases.registerApp),
            pushNotification = callback(options, aliases.pushNotification),
            openApp = callback(options, aliases.openApp)
        }
        local adapter = Phone.new(adapterOptions)
        adapter.name = name
        adapter._capabilities.provider = name
        adapter._capabilities.resource = options.resource
        adapter._capabilities.external = options.resource ~= nil
        return adapter
    end
end

local function register(name, aliases)
    local created = factory(name, aliases)
    NightShift.PhoneAdapters[name] = {
        name = name,
        new = created,
        register = created
    }
    return NightShift.PhoneAdapters[name]
end

NightShift.PhoneAdapters._factory = factory
NightShift.PhoneAdapters._register = register
