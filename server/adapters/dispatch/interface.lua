NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Base = NightShift.ProviderBase
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

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

local Dispatch = {}

function Dispatch.new(options)
    options = options or {}
    local adapter = Base.new('dispatch', options, {
        optional = true, dispatch = true, safetyAlert = true, viceAlert = true
    }, { 'emitSafetyAlert', 'emitViceAlert' })
    adapter._handlers.emitSafetyAlert = wrap(options.emitSafetyAlert, 'emitted')
    adapter._handlers.emitViceAlert = wrap(options.emitViceAlert, 'emitted')
    adapter.emitSafetyAlert = function(self, payload)
        if type(payload) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'safety alert payload must be a table') end
        return self:invoke('emitSafetyAlert', { skipped = true, optional = true }, payload)
    end
    adapter.emitViceAlert = function(self, payload)
        if type(payload) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'vice alert payload must be a table') end
        return self:invoke('emitViceAlert', { skipped = true, optional = true }, payload)
    end
    return adapter
end

NightShift.OptionalProviders.Dispatch = Dispatch
