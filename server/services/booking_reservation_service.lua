NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

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

local function invalid(message, details)
    return Result.err(Codes.RESERVATION_INVALID, message, details)
end

function Service.new(options)
    options = options or {}
    local locks = options.locks or options.manager
    if type(locks) ~= 'table' or type(locks.reserve) ~= 'function' or type(locks.release) ~= 'function' then
        return nil, invalid('booking reservation service requires a lock manager')
    end
    if options.provider ~= nil and type(options.provider) ~= 'table' then return nil, invalid('reservation provider must be a table') end
    return setmetatable({ _locks = locks, _provider = options.provider, _clock = options.clock, _active = {} }, Service)
end

local function providerCall(provider, operation, resource, bookingId)
    if not provider or type(provider[operation]) ~= 'function' then return true end
    local ok, result = pcall(provider[operation], provider, resource, bookingId)
    if not ok or result == false or (type(result) == 'table' and result.ok == false) then
        return nil, Result.err(Codes.RESERVATION_PROVIDER_FAILED, 'reservation provider operation failed', { operation = operation, resource = resource.type .. ':' .. resource.id })
    end
    return true
end

local function resourceKeys(resources)
    local output = {}
    for _, resource in ipairs(resources or {}) do output[#output + 1] = { type = resource.type, id = resource.id } end
    return output
end

local function mergeResources(existing, incoming)
    local output = copy(existing or {})
    local positions = {}
    for index, resource in ipairs(output) do
        if type(resource) == 'table' and resource.type ~= nil and resource.id ~= nil then
            positions[tostring(resource.type):upper() .. ':' .. tostring(resource.id)] = index
        end
    end
    for _, resource in ipairs(incoming or {}) do
        local value = copy(resource)
        local key = tostring(value.type):upper() .. ':' .. tostring(value.id)
        value.type = tostring(value.type):upper()
        value.id = tostring(value.id)
        if positions[key] then
            output[positions[key]] = value
        else
            output[#output + 1] = value
            positions[key] = #output
        end
    end
    return output
end

function Service:reserve(bookingId, resources, context)
    if not text(bookingId, 160) and type(bookingId) ~= 'number' then return invalid('reservation booking ID is invalid') end
    local locked = self._locks:reserve(tostring(bookingId), resources, context)
    if type(locked) ~= 'table' or not locked.ok then return locked end
    local acquired = locked.value and locked.value.acquired or {}
    local providerAcquired = {}
    for _, resource in ipairs(acquired) do
        local ok, providerError = providerCall(self._provider, 'reserve', resource, tostring(bookingId))
        if not ok then
            for index = #providerAcquired, 1, -1 do providerCall(self._provider, 'release', providerAcquired[index], tostring(bookingId)) end
            self._locks:release(tostring(bookingId), resourceKeys(acquired))
            return providerError
        end
        providerAcquired[#providerAcquired + 1] = resource
    end
    self._active[tostring(bookingId)] = mergeResources(self._active[tostring(bookingId)], locked.value and locked.value.resources or resources)
    local value = copy(locked.value)
    value.provider = #providerAcquired > 0
    return Result.ok(value, locked.metadata)
end

function Service:release(bookingId, resources)
    if not text(bookingId, 160) and type(bookingId) ~= 'number' then return invalid('reservation booking ID is invalid') end
    bookingId = tostring(bookingId)
    local targets = resources or self._active[bookingId]
    if targets then
        for index = #targets, 1, -1 do providerCall(self._provider, 'release', targets[index], bookingId) end
    end
    local released = self._locks:release(bookingId, targets)
    if type(released) == 'table' and released.ok then self._active[bookingId] = nil end
    return released
end

function Service:isReserved(kind, id)
    return self._locks:isReserved(kind, id)
end

function Service:releaseBooking(bookingId)
    return self:release(bookingId)
end

function Service:active(bookingId)
    return Result.ok(copy(self._active[tostring(bookingId)] or {}))
end

NightShift.BookingReservationService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.BookingReservation = Service
