NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Result = NightShift.Result
local Codes = (NightShift.Errors and NightShift.Errors.Codes) or {}
local meetingModes = NightShift.Enums and NightShift.Enums.MeetingModes or {}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function text(value)
    if type(value) ~= 'string' then return nil end
    local result = value:match('^%s*(.-)%s*$')
    return result ~= '' and #result <= 160 and result or nil
end

local function token(value)
    value = text(value)
    return value and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil and value or nil
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeTarget(raw)
    if type(raw) ~= 'table' then return nil end
    local target = copy(raw)
    local kind = tostring(target.kind or target.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil end
    target.kind = kind
    if kind == 'coords' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local limit = axis == 'z' and 10000 or 100000
            if not finite(target[axis]) or math.abs(tonumber(target[axis])) > limit then return nil end
            target[axis] = tonumber(target[axis])
        end
        if target.heading ~= nil then
            if not finite(target.heading) or math.abs(tonumber(target.heading)) > 360 then return nil end
            target.heading = tonumber(target.heading)
        end
    else
        if not token(target.provider) then return nil end
        target.provider = token(target.provider)
    end
    return target
end

local function integer(value, minimum)
    value = tonumber(value)
    return value and value == math.floor(value) and value >= (minimum or 0) and value
end

local function errorResult(code, message, details)
    return Result.err(Codes[code] or code, message, details)
end

local function normalizeModes(raw)
    local modes = raw.allowedMeetingModes or raw.meetingModes
    if type(modes) ~= 'table' then return nil end
    local result, seen = {}, {}
    for _, mode in ipairs(modes) do
        mode = text(mode) and text(mode):upper() or nil
        if not mode or not meetingModes[mode] or seen[mode] then return nil end
        seen[mode] = true
        result[#result + 1] = mode
    end
    return #result > 0 and result or nil
end

local function normalizeLocation(raw, index)
    if type(raw) ~= 'table' then return nil, 'location #' .. index .. ' must be a table' end
    local ref = token(raw.id or raw.locationRef)
    if not ref then return nil, 'config location reference is required' end
    local target = normalizeTarget(raw.worldTarget)
    if not target then return nil, 'config location target is required' end
    local modes = normalizeModes(raw)
    if not modes then return nil, 'config location meeting modes are required' end
    local capacity = raw.capacity
    if capacity ~= nil and not integer(capacity, 1) then return nil, 'config location capacity must be a positive integer' end
    if raw.fees ~= nil and type(raw.fees) ~= 'table' then return nil, 'config location fees must be a table' end
    local fees = copy(raw.fees or {})
    for key, fee in pairs(fees) do
        if not token(key) or not integer(fee, 0) then return nil, 'config location fees must be non-negative integers' end
    end
    if raw.accessRequirements ~= nil and type(raw.accessRequirements) ~= 'table' then
        return nil, 'config location access requirements must be a table'
    end
    if raw.blockedTags ~= nil and type(raw.blockedTags) ~= 'table' then
        return nil, 'config location blocked tags must be a table'
    end
    return {
        id = ref, locationRef = ref, type = 'CONFIG_LOCATION', locationType = 'CONFIG_LOCATION',
        provider = 'config', category = text(raw.category) or 'configured', worldTarget = target,
        accessRequirements = copy(raw.accessRequirements or { public = true }),
        meetingModes = modes, allowedMeetingModes = copy(modes),
        capacity = capacity, fees = fees, openingHours = copy(raw.openingHours),
        available = raw.available ~= false, reservable = raw.reservable ~= false,
        blockedTags = copy(raw.blockedTags or {})
    }
end

local Provider = {}
Provider.__index = Provider

function Provider.new(options)
    options = type(options) == 'table' and options or {}
    local configured = options.locations
    if configured == nil then configured = NightShift.LocationConfig or {} end
    if type(configured) ~= 'table' then return nil, errorResult('LOCATION_INVALID', 'config locations must be a table') end
    local self = setmetatable({
        name = 'config',
        _clock = options.clock,
        _accessCheck = options.accessCheck,
        _locations = {}, _order = {}, _holds = {}
    }, Provider)
    for index, raw in ipairs(configured) do
        local rawType = type(raw) == 'table' and tostring(raw.locationType or raw.type or 'CONFIG_LOCATION'):upper() or ''
        if rawType == 'CONFIGURED' then rawType = 'CONFIG_LOCATION' end
        if rawType == 'CONFIG_LOCATION' then
            local location, message = normalizeLocation(raw, index)
            if not location then return nil, errorResult('LOCATION_INVALID', message) end
            if self._locations[location.locationRef] then return nil, errorResult('LOCATION_INVALID', 'duplicate config location reference', { locationRef = location.locationRef }) end
            self._locations[location.locationRef] = location
            self._order[#self._order + 1] = location.locationRef
        end
    end
    return self
end

function Provider:isAvailable() return true end

function Provider:getCapabilities()
    return { provider = self.name, available = true, optional = true, configLocations = true,
        listAvailable = true, validate = true, reserve = true, occupy = true, release = true,
        resolveWorldTarget = true, fees = true, openingHours = true, capacity = true }
end

function Provider:_now(context)
    if type(context) == 'table' and tonumber(context.now) then return tonumber(context.now) end
    if type(self._clock) == 'table' and type(self._clock.now) == 'function' then
        local ok, value = pcall(self._clock.now, self._clock)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return os.time()
end

function Provider:_isOpen(location, timestamp, context)
    local hours = location.openingHours
    if hours == nil then return true end
    if type(hours) ~= 'table' then return false end
    local date = os.date('*t', timestamp)
    local day = hours[date.wday] or hours[({'sunday','monday','tuesday','wednesday','thursday','friday','saturday'})[date.wday]]
    if day == nil then return false end
    if day == true then return true end
    local minute = date.hour * 60 + date.min
    local function inRange(range)
        if type(range) ~= 'table' then return false end
        local opening = integer(range.open or range[1], 0)
        local closing = integer(range.close or range[2], 0)
        if not opening or not closing then return false end
        if opening == closing then return true end
        return opening < closing and minute >= opening and minute < closing
            or minute >= opening or minute < closing
    end
    if day.open ~= nil or day.close ~= nil then return inRange(day) end
    for _, range in ipairs(day) do if inRange(range) then return true end end
    return false
end

function Provider:_location(ref)
    return self._locations[text(ref)]
end

function Provider:_allowed(source, location, context)
    if type(self._accessCheck) == 'function' then
        local ok, allowed = pcall(self._accessCheck, source, copy(location), type(context) == 'table' and copy(context) or {})
        if not ok then return false end
        if type(allowed) == 'table' and allowed.ok ~= nil then
            return allowed.ok == true and (allowed.value == nil or allowed.value == true
                or type(allowed.value) == 'table' and allowed.value.allowed == true)
        end
        return allowed == true
    end
    return location.accessRequirements.public ~= false
end

function Provider:_expire(ref, now)
    local holds = self._holds[ref]
    if not holds then return end
    for booking, hold in pairs(holds) do
        if hold.expiresAt and hold.expiresAt <= now then holds[booking] = nil end
    end
end

function Provider:_count(ref)
    local count = 0
    for _ in pairs(self._holds[ref] or {}) do count = count + 1 end
    return count
end

function Provider:listAvailable(source, context)
    context = type(context) == 'table' and context or {}
    local result = {}
    for _, ref in ipairs(self._order) do
        local location = self._locations[ref]
        self:_expire(ref, self:_now(context))
        local mode = text(context.meetingMode)
        local modeAllowed = not mode
        for _, candidate in ipairs(location.meetingModes) do if candidate == mode then modeAllowed = true end end
        if location.available and modeAllowed and self:_isOpen(location, self:_now(context), context) and self:_allowed(source, location, context) then
            local entry = copy(location)
            entry.reserved = self:_count(ref)
            entry.remaining = location.capacity and math.max(0, location.capacity - entry.reserved) or nil
            result[#result + 1] = entry
        end
    end
    return Result.ok(result)
end

function Provider:validate(source, locationRef, context)
    context = type(context) == 'table' and context or {}
    local location = self:_location(locationRef)
    if not location then return errorResult('LOCATION_NOT_FOUND', 'config location is not registered', { locationRef = locationRef }) end
    local mode = text(context.meetingMode)
    if mode then
        local supported = false
        for _, candidate in ipairs(location.meetingModes) do if candidate == mode then supported = true end end
        if not supported then return errorResult('LOCATION_INCOMPATIBLE', 'config location does not support meeting mode', { locationRef = locationRef, meetingMode = mode }) end
    end
    if not location.available or not self:_isOpen(location, self:_now(context), context) then return errorResult('LOCATION_UNAVAILABLE', 'config location is closed or unavailable', { locationRef = locationRef }) end
    if not self:_allowed(source, location, context) then return errorResult('LOCATION_ACCESS_DENIED', 'config location access denied', { locationRef = locationRef }) end
    local result = copy(location)
    result.reserved = self:_count(location.locationRef)
    result.remaining = location.capacity and math.max(0, location.capacity - result.reserved) or nil
    return Result.ok({ valid = true, location = result, fees = copy(location.fees) })
end

function Provider:reserve(locationRef, bookingId, ttlSeconds)
    local location = self:_location(locationRef)
    if not location then return errorResult('LOCATION_NOT_FOUND', 'config location is not registered', { locationRef = locationRef }) end
    if location.reservable == false then return errorResult('LOCATION_UNAVAILABLE', 'config location is not reservable') end
    local booking = text(bookingId)
    local ttl = integer(ttlSeconds, 1)
    if not booking or not ttl then return errorResult('PROVIDER_INVALID', 'config reservation requires booking and positive TTL') end
    local now = self:_now()
    self:_expire(location.locationRef, now)
    self._holds[location.locationRef] = self._holds[location.locationRef] or {}
    local existing = self._holds[location.locationRef][booking]
    if existing then return Result.ok({ reserved = true, idempotent = true, locationRef = location.locationRef, bookingId = booking, holdUntil = existing.expiresAt }) end
    if location.capacity and self:_count(location.locationRef) >= location.capacity then return errorResult('LOCATION_UNAVAILABLE', 'config location capacity is full', { locationRef = location.locationRef }) end
    local hold = { locationRef = location.locationRef, bookingId = booking, expiresAt = now + ttl }
    self._holds[location.locationRef][booking] = hold
    return Result.ok({ reserved = true, locationRef = location.locationRef, bookingId = booking, holdUntil = hold.expiresAt })
end

function Provider:occupy(locationRef, bookingId)
    local location = self:_location(locationRef)
    local booking = text(bookingId)
    local hold = location and self._holds[location.locationRef] and self._holds[location.locationRef][booking]
    if not hold then return errorResult('LOCATION_NOT_FOUND', 'config reservation was not found') end
    hold.occupied = true
    return Result.ok({ occupied = true, locationRef = location.locationRef, bookingId = booking })
end

function Provider:release(locationRef, bookingId)
    local ref, booking = text(locationRef), text(bookingId)
    local holds = ref and self._holds[ref]
    if not holds or not holds[booking] then return Result.ok({ released = false, idempotent = true, locationRef = ref, bookingId = booking }) end
    holds[booking] = nil
    return Result.ok({ released = true, locationRef = ref, bookingId = booking })
end

function Provider:resolveWorldTarget(locationRef, context)
    local location = self:_location(locationRef)
    if not location then return errorResult('LOCATION_NOT_FOUND', 'config location is not registered', { locationRef = locationRef }) end
    return Result.ok({ worldTarget = copy(location.worldTarget), locationRef = location.locationRef, context = copy(context or {}) })
end

NightShift.OptionalProviders.ConfigLocations = Provider
NightShift.OptionalProviders.ConfigLocation = Provider
