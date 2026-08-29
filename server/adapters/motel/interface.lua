NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Base = NightShift.ProviderBase
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local function text(value)
    return type(value) == 'string' and value:match('%S') and value:sub(1, 160) or nil
end

local function positive(value)
    value = tonumber(value)
    return value and value > 0 and value == math.floor(value)
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

local Motel = {}

function Motel.new(options)
    options = options or {}
    local adapter = Base.new('motel', options, {
        optional = true, motel = true, listAvailable = true, validate = true,
        reserve = true, occupy = true, release = true, resolveWorldTarget = true
    }, { 'listAvailable', 'validate', 'reserve', 'occupy', 'release', 'resolveWorldTarget' })
    adapter._handlers.listAvailable = options.listAvailable
    adapter._handlers.validate = wrap(options.validate, 'valid')
    adapter._handlers.reserve = wrap(options.reserve, 'reserved')
    adapter._handlers.occupy = wrap(options.occupy, 'occupied')
    adapter._handlers.release = wrap(options.release, 'released')
    adapter._handlers.resolveWorldTarget = options.resolveWorldTarget
    adapter.listAvailable = function(self, playerSource, context)
        if playerSource ~= nil and (not tonumber(playerSource) or tonumber(playerSource) < 1) then return Result.err(Codes.PROVIDER_INVALID, 'motel availability source is invalid') end
        return self:invoke('listAvailable', nil, playerSource, type(context) == 'table' and context or {})
    end
    adapter.validate = function(self, playerSource, locationRef, context)
        if playerSource ~= nil and (not tonumber(playerSource) or tonumber(playerSource) < 1) then return Result.err(Codes.PROVIDER_INVALID, 'motel validation source is invalid') end
        if not text(locationRef) then return Result.err(Codes.PROVIDER_INVALID, 'motel location reference is required') end
        return self:invoke('validate', nil, playerSource, locationRef, type(context) == 'table' and context or {})
    end
    adapter.reserve = function(self, locationRef, bookingId, ttlSeconds)
        if not text(locationRef) or not text(bookingId) or not positive(ttlSeconds) then return Result.err(Codes.PROVIDER_INVALID, 'motel reservation requires location, booking, and positive TTL') end
        return self:invoke('reserve', nil, locationRef, bookingId, ttlSeconds)
    end
    adapter.occupy = function(self, locationRef, bookingId)
        if not text(locationRef) or not text(bookingId) then return Result.err(Codes.PROVIDER_INVALID, 'motel occupancy requires location and booking') end
        return self:invoke('occupy', nil, locationRef, bookingId)
    end
    adapter.release = function(self, locationRef, bookingId)
        if not text(locationRef) or not text(bookingId) then return Result.err(Codes.PROVIDER_INVALID, 'motel release requires location and booking') end
        return self:invoke('release', nil, locationRef, bookingId)
    end
    adapter.resolveWorldTarget = function(self, locationRef, context)
        if not text(locationRef) then return Result.err(Codes.PROVIDER_INVALID, 'motel world target reference is required') end
        return self:invoke('resolveWorldTarget', nil, locationRef, type(context) == 'table' and context or {})
    end
    return adapter
end

NightShift.OptionalProviders.Motel = Motel
