NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Base = NightShift.ProviderBase
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local function source(value)
    value = tonumber(value)
    return value and value >= 1 and math.floor(value) == value
end

local function wrap(handler, key)
    if type(handler) ~= 'function' then return nil end
    return function(...)
        local ok, value = pcall(handler, ...)
        if not ok then return false end
        if type(value) == 'table' and value.ok ~= nil then return value end
        if value == true then return { [key] = true } end
        return value
    end
end

local Phone = {}

function Phone.new(options)
    options = options or {}
    local adapter = Base.new('phone', options, {
        optional = true, phone = true, registerApp = true, pushNotification = true, openApp = true
    }, { 'registerApp', 'pushNotification', 'openApp' })
    adapter._handlers.registerApp = wrap(options.registerApp, 'registered')
    adapter._handlers.pushNotification = wrap(options.pushNotification, 'delivered')
    adapter._handlers.openApp = wrap(options.openApp, 'opened')
    adapter.registerApp = function(self, definition)
        if type(definition) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'phone app definition must be a table') end
        return self:invoke('registerApp', nil, definition)
    end
    adapter.pushNotification = function(self, playerSource, payload)
        if not source(playerSource) or type(payload) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'phone notification requires a source and payload') end
        return self:invoke('pushNotification', nil, playerSource, payload)
    end
    adapter.openApp = function(self, playerSource, route, context)
        if not source(playerSource) or type(route) ~= 'string' or route:match('^%s*$') then return Result.err(Codes.PROVIDER_INVALID, 'phone app navigation requires a source and route') end
        return self:invoke('openApp', nil, playerSource, route, type(context) == 'table' and context or {})
    end
    return adapter
end

NightShift.OptionalProviders.Phone = Phone
