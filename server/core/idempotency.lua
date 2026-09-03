NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Clock = NightShift.Clock

local Store = {}
Store.__index = Store

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 128)
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.IDEMPOTENCY_INVALID, message, details)
end

local function unavailable(message, details)
    return Result.err(Codes.IDEMPOTENCY_UNAVAILABLE, message, details)
end

local function errorCode(value)
    if type(value) ~= 'table' then return nil end
    local source = value.error or value
    return type(source) == 'table' and source.code or nil
end

local function stable(value, depth, seen, budget)
    depth = depth or 0
    seen = seen or {}
    budget = budget or { remaining = 2048 }
    if budget.remaining <= 0 then return nil, 'payload is too large' end
    budget.remaining = budget.remaining - 1
    local kind = type(value)
    if value == nil then return 'nil' end
    if kind == 'boolean' then return value and 'bool:1' or 'bool:0' end
    if kind == 'string' then
        if #value > 4096 then return nil, 'payload string is too long' end
        return 'str:' .. #value .. ':' .. value
    end
    if kind == 'number' then
        if not finite(value) then return nil, 'payload number is invalid' end
        return ('num:%.17g'):format(value)
    end
    if kind ~= 'table' then return nil, 'payload type is not supported' end
    if depth >= 6 then return nil, 'payload nesting is too deep' end
    if seen[value] then return nil, 'payload contains a cycle' end
    seen[value] = true
    local fields = {}
    for key, item in pairs(value) do
        local keyValue, keyError = stable(key, depth + 1, seen, budget)
        if not keyValue then seen[value] = nil; return nil, keyError end
        local itemValue, itemError = stable(item, depth + 1, seen, budget)
        if not itemValue then seen[value] = nil; return nil, itemError end
        fields[#fields + 1] = { key = keyValue, value = itemValue }
    end
    table.sort(fields, function(left, right) return left.key < right.key end)
    local output = { 'table:' .. #fields .. '{' }
    for _, field in ipairs(fields) do output[#output + 1] = field.key .. '=' .. field.value .. ';' end
    output[#output + 1] = '}'
    seen[value] = nil
    return table.concat(output)
end

local function fingerprint(value)
    local serialized, serializationError = stable(value)
    if not serialized then return nil, serializationError end
    local hash = 2166136261
    for index = 1, #serialized do
        hash = ((hash ~ string.byte(serialized, index)) * 16777619) & 0xffffffff
    end
    return ('%08x'):format(hash)
end

local function entryKey(scope, key)
    return scope .. '\0' .. key
end

local function nowValue(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function epochValue(value)
    if finite(tonumber(value)) then return tonumber(value) end
    if type(value) ~= 'string' then return nil end
    local year, month, day, hour, minute, second = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)')
    if not year then return nil end
    local ok, epoch = pcall(os.time, {
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false
    })
    return ok and finite(epoch) and epoch or nil
end

local function normalizeScope(value)
    if not text(value, 96) or value:match('^[%w%._:%-]+$') == nil then return nil end
    return value
end

local function normalizeKey(value)
    if not text(value, 160) or value:match('^[%w%._:%-/]+$') == nil then return nil end
    return value
end

function Store.new(options)
    options = options or {}
    local ttl = tonumber(options.ttlSeconds)
    if ttl == nil then ttl = 300 end
    local maximum = tonumber(options.maxEntries)
    if maximum == nil then maximum = 2048 end
    if not finite(ttl) or ttl < 1 or ttl > 86400 then return nil, invalid('idempotency TTL is invalid') end
    if not maximum or maximum < 32 or maximum > 100000 or math.floor(maximum) ~= maximum then
        return nil, invalid('idempotency maximum entries is invalid') end
    local clock = options.clock or (Clock and Clock.new and Clock.new() or nil)
    return setmetatable({
        _clock = clock,
        _repository = options.repository or options.idempotencyRepository,
        _ttl = math.floor(ttl),
        _maxEntries = maximum,
        _entries = {},
        _entryCount = 0,
        _sequence = 0,
        _closed = false
    }, Store)
end

function Store:_validate(scope, key, payload)
    local normalizedScope = normalizeScope(scope)
    local normalizedKey = normalizeKey(key)
    if not normalizedScope then return nil, nil, invalid('idempotency scope is invalid', { field = 'scope' }) end
    if not normalizedKey then return nil, nil, invalid('idempotency key is invalid', { field = 'key' }) end
    local digest, digestError = fingerprint(payload)
    if not digest then return nil, nil, invalid(digestError or 'idempotency payload is invalid', { field = 'payload' }) end
    return normalizedScope, normalizedKey, digest
end

function Store:_remember(key, entry)
    if self._entries[key] == nil then self._entryCount = self._entryCount + 1 end
    self._sequence = self._sequence + 1
    entry.sequence = self._sequence
    self._entries[key] = entry
    while self._entryCount > self._maxEntries do
        local oldestKey, oldestSequence
        for candidateKey, candidate in pairs(self._entries) do
            if oldestSequence == nil or candidate.sequence < oldestSequence then
                oldestKey, oldestSequence = candidateKey, candidate.sequence
            end
        end
        if oldestKey == nil then break end
        self._entries[oldestKey] = nil
        self._entryCount = self._entryCount - 1
    end
end

function Store:_load(scope, key)
    local memory = self._entries[entryKey(scope, key)]
    if memory then return copy(memory) end
    if not self._repository or type(self._repository.findByKey) ~= 'function' then return nil end
    local found = self._repository:findByKey(scope, key)
    if type(found) ~= 'table' or found.ok ~= true then
        if errorCode(found) == Codes.REPOSITORY_NOT_FOUND then return nil end
        return nil, unavailable('idempotency repository lookup failed', { cause = errorCode(found) })
    end
    local value = found.value
    if type(value) ~= 'table' then return nil, unavailable('idempotency repository row is invalid') end
    if not text(value.fingerprint, 32) or not text(value.status, 32) then
        return nil, unavailable('idempotency repository row is invalid') end
    local entry = copy(value)
    entry.scope, entry.key = scope, key
    local expiresAt = epochValue(entry.expiresAt)
    if expiresAt then entry.expiresAt = expiresAt end
    if expiresAt and expiresAt <= nowValue(self._clock) then
        return nil
    end
    self:_remember(entryKey(scope, key), entry)
    return copy(entry)
end

function Store:_persistCreate(entry)
    if not self._repository or type(self._repository.create) ~= 'function' then return true end
    local created = self._repository:create(copy(entry))
    if type(created) == 'table' and created.ok == true then
        entry.id = created.value and (created.value.id or created.value.insertId) or entry.id
        entry.version = entry.version or 1
        return true
    end
    local existing
    local lookupError
    if self._repository and type(self._repository.findByKey) == 'function' then
        local found = self._repository:findByKey(entry.scope, entry.key)
        if type(found) == 'table' and found.ok == true and type(found.value) == 'table' then
            existing = copy(found.value)
        elseif type(found) == 'table' and errorCode(found) ~= Codes.REPOSITORY_NOT_FOUND then
            lookupError = unavailable('idempotency repository lookup failed', { cause = errorCode(found) })
        end
    end
    if existing then
        existing.scope, existing.key = entry.scope, entry.key
        self:_remember(entryKey(entry.scope, entry.key), existing)
        return false, existing
    end
    return nil, lookupError or unavailable('idempotency claim could not be persisted', { cause = errorCode(created) })
end

function Store:claim(scope, key, payload)
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'idempotency store is stopped') end
    local normalizedScope, normalizedKey, digestOrError = self:_validate(scope, key, payload)
    if not normalizedScope then return digestOrError end
    local digest = digestOrError
    local composite = entryKey(normalizedScope, normalizedKey)
    local now = nowValue(self._clock)
    local existing, loadError = self:_load(normalizedScope, normalizedKey)
    if loadError then return loadError end
    if existing and existing.expiresAt and epochValue(existing.expiresAt) and epochValue(existing.expiresAt) <= now then
        self._entries[composite] = nil
        self._entryCount = math.max(0, self._entryCount - 1)
        existing = nil
    end
    if existing then
        if existing.fingerprint ~= digest then
            return Result.err(Codes.IDEMPOTENCY_CONFLICT, 'idempotency key was already used with a different payload', {
                scope = normalizedScope, key = normalizedKey
            })
        end
        if tostring(existing.status):upper() == 'PENDING' then
            return Result.err(Codes.IDEMPOTENCY_IN_PROGRESS, 'idempotency operation is still in progress', {
                scope = normalizedScope, key = normalizedKey
            })
        end
        return Result.ok({
            scope = normalizedScope, key = normalizedKey, status = existing.status,
            replayed = true, value = copy(existing.value)
        }, { replayed = true, fingerprint = digest })
    end
    local entry = {
        scope = normalizedScope, key = normalizedKey, fingerprint = digest,
        status = 'PENDING', value = nil, createdAt = now, updatedAt = now,
        expiresAt = now + self._ttl, version = 1
    }
    self:_remember(composite, entry)
    local persisted, race = self:_persistCreate(entry)
    if persisted == false and race then
        if race.fingerprint ~= digest then
            return Result.err(Codes.IDEMPOTENCY_CONFLICT, 'idempotency key was already used with a different payload', {
                scope = normalizedScope, key = normalizedKey
            })
        end
        if tostring(race.status):upper() == 'PENDING' then
            return Result.err(Codes.IDEMPOTENCY_IN_PROGRESS, 'idempotency operation is still in progress', {
                scope = normalizedScope, key = normalizedKey
            })
        end
        return Result.ok({ scope = normalizedScope, key = normalizedKey, status = race.status, replayed = true, value = copy(race.value) }, {
            replayed = true, fingerprint = digest
        })
    end
    if persisted == nil then
        self._entries[composite] = nil
        self._entryCount = math.max(0, self._entryCount - 1)
        return race
    end
    return Result.ok({ scope = normalizedScope, key = normalizedKey, status = 'PENDING', replayed = false }, {
        replayed = false, fingerprint = digest, expiresAt = entry.expiresAt
    })
end

function Store:complete(scope, key, payload, value)
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'idempotency store is stopped') end
    local normalizedScope, normalizedKey, digestOrError = self:_validate(scope, key, payload)
    if not normalizedScope then return digestOrError end
    local digest = digestOrError
    local composite = entryKey(normalizedScope, normalizedKey)
    local entry, loadError = self:_load(normalizedScope, normalizedKey)
    if loadError then return loadError end
    if not entry then return Result.err(Codes.IDEMPOTENCY_INVALID, 'idempotency claim must exist before completion') end
    if entry.fingerprint ~= digest then return Result.err(Codes.IDEMPOTENCY_CONFLICT, 'idempotency payload does not match the claim') end
    if entry.expiresAt and epochValue(entry.expiresAt) and epochValue(entry.expiresAt) <= nowValue(self._clock) then
        self._entries[composite] = nil
        self._entryCount = math.max(0, self._entryCount - 1)
        return Result.err(Codes.IDEMPOTENCY_EXPIRED, 'idempotency claim has expired') end
    if tostring(entry.status):upper() ~= 'PENDING' then
        return Result.ok({ scope = normalizedScope, key = normalizedKey, status = entry.status, replayed = true, value = copy(entry.value) }, {
            replayed = true, fingerprint = digest
        })
    end
    local now = nowValue(self._clock)
    local changes = { status = 'COMPLETED', value = copy(value), updatedAt = now }
    if self._repository and type(self._repository.updateExpectedVersion) == 'function' and entry.id then
        local persisted = self._repository:updateExpectedVersion(entry.id, tonumber(entry.version) or 1, changes)
        if type(persisted) ~= 'table' or persisted.ok ~= true then
            return unavailable('idempotency completion could not be persisted', { cause = errorCode(persisted) }) end
        changes.version = persisted.value and persisted.value.version or (tonumber(entry.version) or 1) + 1
    end
    local completed = copy(entry)
    completed.status, completed.value, completed.updatedAt = changes.status, changes.value, changes.updatedAt
    completed.version = changes.version or completed.version
    self:_remember(composite, completed)
    return Result.ok({ scope = normalizedScope, key = normalizedKey, status = 'COMPLETED', replayed = false, value = copy(value) }, {
        replayed = false, fingerprint = digest
    })
end

function Store:get(scope, key)
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'idempotency store is stopped') end
    local normalizedScope = normalizeScope(scope)
    local normalizedKey = normalizeKey(key)
    if not normalizedScope or not normalizedKey then return invalid('idempotency scope or key is invalid') end
    local composite = entryKey(normalizedScope, normalizedKey)
    local entry, loadError = self:_load(normalizedScope, normalizedKey)
    if loadError then return loadError end
    if not entry then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'idempotency entry was not found') end
    if entry.expiresAt and epochValue(entry.expiresAt) and epochValue(entry.expiresAt) <= nowValue(self._clock) then
        self._entries[composite] = nil
        self._entryCount = math.max(0, self._entryCount - 1)
        return Result.err(Codes.IDEMPOTENCY_EXPIRED, 'idempotency entry has expired') end
    return Result.ok({ scope = normalizedScope, key = normalizedKey, status = entry.status, value = copy(entry.value) })
end

function Store:purge(now, limit)
    if self._closed then return Result.err(Codes.LIFECYCLE_STOPPED, 'idempotency store is stopped') end
    now = tonumber(now) or nowValue(self._clock)
    if not finite(now) then return invalid('idempotency purge timestamp is invalid') end
    limit = tonumber(limit) or 200
    if limit < 1 or limit > 1000 or math.floor(limit) ~= limit then return invalid('idempotency purge limit is invalid') end
    local removed = 0
    for composite, entry in pairs(self._entries) do
        if removed >= limit then break end
        if entry.expiresAt and epochValue(entry.expiresAt) and epochValue(entry.expiresAt) <= now then
            self._entries[composite] = nil
            self._entryCount = math.max(0, self._entryCount - 1)
            removed = removed + 1
        end
    end
    if self._repository and type(self._repository.deleteExpired) == 'function' then
        local persisted = self._repository:deleteExpired(now, limit)
        if type(persisted) ~= 'table' or persisted.ok ~= true then
            return unavailable('idempotency purge could not be persisted', { cause = errorCode(persisted) }) end
        removed = math.max(removed, tonumber(persisted.value and persisted.value.deleted) or 0)
    end
    return Result.ok({ removed = removed, now = now })
end

function Store:close()
    self._entries = {}
    self._entryCount = 0
    self._closed = true
    return true
end

NightShift.IdempotencyStore = Store
NightShift.Core = NightShift.Core or {}
NightShift.Core.Idempotency = Store
