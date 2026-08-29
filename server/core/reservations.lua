NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Reservations = {}
Reservations.__index = Reservations

local order = { NPC = 1, WORKER = 1, LOCATION = 2, ROOM = 2, VEHICLE = 2, DEPOSIT = 3 }

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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.RESERVATION_INVALID, message, details)
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function normalizeResource(resource, defaultTtl)
    if type(resource) ~= 'table' then return nil, invalid('reservation resource must be a table') end
    local kind = type(resource.type) == 'string' and resource.type:upper() or nil
    if not kind or not order[kind] then return nil, invalid('reservation resource type is invalid') end
    if not text(resource.id, 160) and not finite(tonumber(resource.id)) then return nil, invalid('reservation resource ID is invalid') end
    local ttl = tonumber(resource.ttlSeconds or resource.ttl or defaultTtl)
    if not ttl or ttl < 1 or ttl > 86400 or math.floor(ttl) ~= ttl then return nil, invalid('reservation TTL is invalid') end
    return { type = kind, id = tostring(resource.id), ttlSeconds = ttl, metadata = copy(resource.metadata) }
end

function Reservations.new(options)
    options = options or {}
    local defaultTtl = tonumber(options.defaultTtl or 300)
    if not defaultTtl or defaultTtl < 1 or defaultTtl > 86400 or math.floor(defaultTtl) ~= defaultTtl then return nil, invalid('default reservation TTL is invalid') end
    return setmetatable({ _clock = options.clock, _defaultTtl = defaultTtl, _locks = {} }, Reservations)
end

function Reservations:purgeExpired(at)
    at = tonumber(at) or now(self._clock)
    local removed = 0
    for kind, resources in pairs(self._locks) do
        for id, lock in pairs(resources) do
            if lock.expiresAt <= at then resources[id] = nil; removed = removed + 1 end
        end
        if next(resources) == nil then self._locks[kind] = nil end
    end
    return removed
end

function Reservations:reserve(bookingId, resources, options)
    if not text(bookingId, 160) and not finite(tonumber(bookingId)) then return invalid('reservation booking ID is invalid') end
    bookingId = tostring(bookingId)
    if type(resources) ~= 'table' or #resources == 0 then return invalid('reservation resources must be a non-empty array') end
    options = options or {}
    local normalized = {}
    local seen = {}
    for index, resource in ipairs(resources) do
        local value, resourceError = normalizeResource(resource, options.defaultTtl or self._defaultTtl)
        if not value then return resourceError end
        local key = value.type .. ':' .. value.id
        if seen[key] then return invalid('reservation resource is duplicated', { resource = key }) end
        seen[key] = true
        normalized[index] = value
    end
    table.sort(normalized, function(left, right)
        if order[left.type] ~= order[right.type] then return order[left.type] < order[right.type] end
        return left.id < right.id
    end)
    local at = tonumber(options.now) or now(self._clock)
    self:purgeExpired(at)
    local acquired = {}
    local idempotent = true
    for _, resource in ipairs(normalized) do
        local bucket = self._locks[resource.type] or {}
        self._locks[resource.type] = bucket
        local lock = bucket[resource.id]
        if lock ~= nil and lock.bookingId ~= bookingId then
            for _, rollback in ipairs(acquired) do self._locks[rollback.type][rollback.id] = nil end
            return Result.err(Codes.RESERVATION_CONFLICT, 'reservation resource is already held', { type = resource.type, id = resource.id, bookingId = lock.bookingId })
        end
        if lock == nil then
            local created = {
                bookingId = bookingId,
                type = resource.type,
                id = resource.id,
                expiresAt = at + resource.ttlSeconds,
                metadata = copy(resource.metadata)
            }
            bucket[resource.id] = created
            acquired[#acquired + 1] = resource
            idempotent = false
        elseif lock.expiresAt < at + resource.ttlSeconds then
            bucket[resource.id] = copy(lock)
            bucket[resource.id].expiresAt = at + resource.ttlSeconds
        end
    end
    local locks, acquiredResources = {}, {}
    for _, resource in ipairs(normalized) do locks[#locks + 1] = copy(self._locks[resource.type][resource.id]) end
    for _, resource in ipairs(acquired) do acquiredResources[#acquiredResources + 1] = copy(self._locks[resource.type][resource.id]) end
    return Result.ok({ bookingId = bookingId, resources = locks, acquired = acquiredResources, idempotent = idempotent, expiresAt = locks[1] and locks[1].expiresAt })
end

function Reservations:release(bookingId, resources)
    if not text(bookingId, 160) and not finite(tonumber(bookingId)) then return invalid('reservation booking ID is invalid') end
    bookingId = tostring(bookingId)
    local targets = resources
    if targets == nil then
        targets = {}
        for kind, bucket in pairs(self._locks) do
            for id, lock in pairs(bucket) do
                if lock.bookingId == bookingId then targets[#targets + 1] = { type = kind, id = id } end
            end
        end
    elseif type(targets) ~= 'table' then
        return invalid('reservation resources must be an array')
    end
    local normalized = {}
    for _, resource in ipairs(targets) do
        local value, resourceError = normalizeResource(resource, self._defaultTtl)
        if not value then return resourceError end
        normalized[#normalized + 1] = value
    end
    local released = 0
    for _, resource in ipairs(normalized) do
        local bucket = self._locks[resource.type]
        local lock = bucket and bucket[resource.id]
        if lock and lock.bookingId ~= bookingId then
            return Result.err(Codes.RESERVATION_OWNER_MISMATCH, 'reservation belongs to another booking', { type = resource.type, id = resource.id })
        end
        if lock then bucket[resource.id] = nil; released = released + 1 end
    end
    self:purgeExpired(now(self._clock))
    return Result.ok({ bookingId = bookingId, released = released, idempotent = released == 0 })
end

function Reservations:releaseBooking(bookingId)
    return self:release(bookingId)
end

function Reservations:isReserved(kind, id)
    kind = type(kind) == 'string' and kind:upper() or kind
    id = tostring(id)
    if not order[kind] or not text(id, 160) then return invalid('reservation resource identity is invalid') end
    self:purgeExpired(now(self._clock))
    local lock = self._locks[kind] and self._locks[kind][id]
    return Result.ok({ reserved = lock ~= nil, bookingId = lock and lock.bookingId, expiresAt = lock and lock.expiresAt })
end

function Reservations:snapshot()
    self:purgeExpired(now(self._clock))
    local output = {}
    for kind, bucket in pairs(self._locks) do
        output[kind] = {}
        for id, lock in pairs(bucket) do output[kind][id] = copy(lock) end
    end
    return Result.ok(output)
end

Reservations.resourceOrder = copy(order)
NightShift.Reservations = Reservations
NightShift.Core = NightShift.Core or {}
NightShift.Core.Reservations = Reservations
