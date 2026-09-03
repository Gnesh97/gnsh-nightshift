NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Profile = NightShift.Domain.NpcProfile
local Enums = NightShift.Enums

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    local metatable = getmetatable(value)
    if metatable ~= nil then setmetatable(output, metatable) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.NPC_WORKER_INVALID, message, details)
end

local function workerError(code, message, details)
    return Result.err(code, message, details)
end

local function normalizeKey(value)
    return type(value) == 'string' and value:match('%S') and value or nil
end

local function normalizeWorker(value)
    if type(value) ~= 'table' or not token(value.workerKey, 160) then return nil, invalid('NPC worker key is invalid') end
    local state = type(value.state) == 'string' and value.state:upper() or 'AVAILABLE'
    if not Enums.NpcWorkerStates[state] then return nil, invalid('NPC worker state is invalid') end
    local profile, profileError = Profile.new(value.profile)
    if not profile then return nil, profileError end
    if profile.role ~= 'WORKER' then return nil, invalid('NPC worker requires a WORKER profile') end
    return {
        id = value.id,
        workerKey = value.workerKey,
        profileId = value.profileId or profile.id,
        state = state,
        bookingId = value.bookingId,
        reservationKey = value.reservationKey,
        holdUntil = value.holdUntil,
        expiresAt = value.expiresAt or profile.expiresAt,
        activeDistrict = value.activeDistrict or profile.activeDistrict,
        profileType = profile.profileType,
        alias = profile.alias,
        priceClass = profile.priceClass,
        rating = profile.rating,
        currentLocationId = value.currentLocationId,
        version = tonumber(value.version) or 1,
        createdAt = value.createdAt,
        updatedAt = value.updatedAt,
        profile = profile
    }
end

local function reservationKey(workerKey, bookingId)
    return ('npc-worker:%s:%s'):format(workerKey, tostring(bookingId)):sub(1, 200)
end

local function parsePage(options, maximum)
    options = options or {}
    if type(options) ~= 'table' then return nil, nil, invalid('NPC worker list options are invalid') end
    local limit = options.limit == nil and 50 or tonumber(options.limit)
    local offset = options.offset == nil and 0 or tonumber(options.offset)
    if not limit or limit < 1 or limit > (maximum or 100) or limit ~= math.floor(limit) then return nil, nil, invalid('NPC worker list limit is invalid') end
    if not offset or offset < 0 or offset ~= math.floor(offset) then return nil, nil, invalid('NPC worker list offset is invalid') end
    return limit, offset
end

local function validateFilters(options)
    if options.district ~= nil and not token(tostring(options.district), 64) then return false, 'district' end
    if options.travelMode ~= nil then
        local mode = type(options.travelMode) == 'string' and options.travelMode:upper() or nil
        if not mode or not Enums.NpcTravelModes[mode] then return false, 'travelMode' end
    end
    for _, key in ipairs({ 'priceClass', 'maxPriceClass' }) do
        if options[key] ~= nil then
            local value = tonumber(options[key])
            if not value or value ~= math.floor(value) or value < 1 or value > 5 then return false, key end
        end
    end
    if options.minRating ~= nil then
        local value = tonumber(options.minRating)
        if not value or not finite(value) or value < 0 or value > 5 then return false, 'minRating' end
    end
    return true
end

local function releaseLock(locks, bookingId, workerKey, ttl)
    if locks and bookingId then
        pcall(locks.release, locks, tostring(bookingId), { { type = 'NPC', id = workerKey, ttlSeconds = ttl } })
    end
end

local function holdActive(value, at)
    if value == nil then return true end
    local numeric = tonumber(value)
    if numeric then return numeric > at end
    return type(value) == 'string' and value:match('%S') ~= nil
end

function Service.new(options)
    options = options or {}
    local generator = options.generator or options.profileGenerator
    local repository = options.repository or options.npcProfileRepository
    local locks = options.locks
    if locks == nil and NightShift.Reservations and type(NightShift.Reservations.new) == 'function' then
        locks = NightShift.Reservations.new({ clock = options.clock, defaultTtl = options.defaultTtl or 300 })
    end
    if locks ~= nil and (type(locks) ~= 'table' or type(locks.reserve) ~= 'function' or type(locks.release) ~= 'function') then
        return nil, invalid('NPC worker reservation lock manager is invalid')
    end
    local defaultTtl = tonumber(options.defaultTtl or 300)
    if not defaultTtl or defaultTtl < 1 or defaultTtl > 86400 or defaultTtl ~= math.floor(defaultTtl) then return nil, invalid('NPC worker reservation TTL is invalid') end
    return setmetatable({
        _generator = generator,
        _repository = repository,
        _locks = locks,
        _clock = options.clock,
        _defaultTtl = defaultTtl,
        _workers = {},
        _nextId = 1
    }, Service)
end

function Service:register(profile, options)
    options = options or {}
    local normalized, profileError = Profile.new(profile)
    if not normalized then return profileError end
    if normalized.role ~= 'WORKER' then return invalid('only WORKER profiles can be registered as NPC workers') end
    local workerKey = normalizeKey(options.workerKey or options.worker_key or ('npc-worker:' .. normalized.profileKey))
    if not token(workerKey, 160) then return invalid('NPC worker key is invalid') end
    local existing = self._workers[workerKey]
    if existing then return Result.ok(copy(existing), { idempotent = true }) end
    local profileId = normalized.id
    if self._repository and type(self._repository.findProfileByKey) == 'function' and type(self._repository.createProfile) == 'function' then
        local persisted = self._repository:findProfileByKey(normalized.profileKey)
        if type(persisted) == 'table' and persisted.ok then
            normalized = persisted.value
            profileId = normalized.id
        elseif type(persisted) == 'table' and persisted.error and persisted.error.code ~= Codes.REPOSITORY_NOT_FOUND then
            return persisted
        else
            local created = self._repository:createProfile(normalized)
            if type(created) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC profile persistence returned an invalid result') end
            if not created.ok then return created end
            profileId = created.value and (created.value.insertId or created.value.id) or profileId
        end
    end
    if profileId == nil then profileId = self._nextId; self._nextId = self._nextId + 1 end
    local expiresAt = options.expiresAt or options.expires_at or normalized.expiresAt
    local worker, workerErrorResult = normalizeWorker({
        id = options.id or profileId,
        workerKey = workerKey,
        profileId = profileId,
        state = options.state or 'AVAILABLE',
        expiresAt = expiresAt,
        activeDistrict = options.activeDistrict or options.active_district or normalized.activeDistrict,
        currentLocationId = options.currentLocationId or options.current_location_id,
        profile = normalized
    })
    if not worker then return workerErrorResult end
    if worker.profile.profileType == 'SEMI_PERSISTENT' and type(worker.expiresAt) == 'number' and worker.expiresAt <= now(self._clock) then
        worker.state = 'EXPIRED'
    end
    if self._repository and type(self._repository.createWorker) == 'function' then
        local created = self._repository:createWorker(worker)
        if type(created) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker persistence returned an invalid result') end
        if not created.ok then return created end
        worker.id = created.value and (created.value.insertId or created.value.id) or worker.id
    end
    self._workers[workerKey] = worker
    return Result.ok(copy(worker), { created = true })
end

function Service:ensurePool(options)
    options = options or {}
    local target = tonumber(options.count or options.targetSize or 0)
    if target == 0 and self._generator and self._generator._config and self._generator._config.workerPool then
        target = tonumber(self._generator._config.workerPool.targetSize) or 0
    end
    if target == 0 then target = 1 end
    if target < 1 or target > 1000 or target ~= math.floor(target) then return invalid('NPC worker pool size is invalid') end
    local configuredMax = self._generator and self._generator._config and self._generator._config.workerPool and tonumber(self._generator._config.workerPool.maxSize)
    if configuredMax and target > configuredMax then return invalid('NPC worker pool exceeds configured maximum', { maxSize = configuredMax }) end
    if not self._generator or type(self._generator.generate) ~= 'function' then return invalid('NPC worker pool requires a profile generator') end
    local values = {}
    for index = 1, target do
        local seed = tostring(options.seed or 'pool') .. ':' .. tostring(index)
        local workerKey = 'npc-worker:' .. seed
        local existing = self:get(workerKey)
        if type(existing) == 'table' and existing.ok then
            values[index] = existing.value
            goto continue
        end
        local generated = self._generator:generate({ role = 'WORKER', seed = seed, profileKey = 'npc-worker:' .. seed })
        if type(generated) ~= 'table' or not generated.ok then return generated end
        local registered = self:register(generated.value, { workerKey = workerKey })
        if type(registered) ~= 'table' or not registered.ok then return registered end
        values[index] = registered.value
        ::continue::
    end
    return Result.ok(values, { count = #values })
end

function Service:get(workerKey)
    if not token(workerKey, 160) then return invalid('NPC worker key is invalid') end
    local expiry = self:expire()
    if type(expiry) == 'table' and not expiry.ok then return expiry end
    -- Prefer the immutable in-process snapshot once a worker has been
    -- materialized. This keeps repeated ensurePool calls idempotent even when
    -- a lightweight adapter cannot echo newly-created rows immediately;
    -- a fresh process still falls through to the repository lookup below.
    local cached = self._workers[workerKey]
    if cached then return Result.ok(copy(cached)) end
    if self._repository and type(self._repository.findWorkerByKey) == 'function' then
        local result = self._repository:findWorkerByKey(workerKey)
        if type(result) == 'table' and result.ok then
            local normalized, errorResult = normalizeWorker(result.value)
            if not normalized then return errorResult end
            self._workers[workerKey] = normalized
            return Result.ok(copy(normalized))
        end
        if type(result) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker lookup returned an invalid result') end
        if result.error and result.error.code ~= Codes.REPOSITORY_NOT_FOUND then return result end
        self._workers[workerKey] = nil
    end
    return workerError(Codes.NPC_WORKER_NOT_FOUND, 'NPC worker was not found', { workerKey = workerKey })
end

function Service:getByProfileId(profileId)
    profileId = tonumber(profileId)
    if not profileId or profileId < 1 or profileId ~= math.floor(profileId) then
        return invalid('NPC worker profile ID is invalid')
    end
    if self._repository and type(self._repository.findWorkerByProfileId) == 'function' then
        local result = self._repository:findWorkerByProfileId(profileId)
        if type(result) == 'table' and result.ok then
            local normalized, errorResult = normalizeWorker(result.value)
            if not normalized then return errorResult end
            self._workers[normalized.workerKey] = normalized
            return Result.ok(copy(normalized))
        end
        if type(result) == 'table' and result.error and result.error.code ~= Codes.REPOSITORY_NOT_FOUND then return result end
    end
    for _, worker in pairs(self._workers) do
        if tonumber(worker.profileId or worker.profile and worker.profile.id) == profileId then return Result.ok(copy(worker)) end
    end
    return workerError(Codes.NPC_WORKER_NOT_FOUND, 'NPC worker was not found', { profileId = profileId })
end

function Service:listAvailable(options)
    local limit, offset, pageError = parsePage(options, 100)
    if not limit then return pageError end
    options = options or {}
    local valid, invalidKey = validateFilters(options)
    if not valid then return invalid('NPC worker filter is invalid', { field = invalidKey }) end
    local expiry = self:expire()
    if type(expiry) == 'table' and not expiry.ok then return expiry end
    if self._repository and type(self._repository.listWorkers) == 'function' then
        local result = self._repository:listWorkers(options)
        if type(result) ~= 'table' or not result.ok then
            return result or workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker list is unavailable')
        end
        local items = {}
        for _, value in ipairs(result.value or {}) do
            local normalized, errorResult = normalizeWorker(value)
            if not normalized then return errorResult end
            self._workers[normalized.workerKey] = normalized
            if normalized.state == 'AVAILABLE' then items[#items + 1] = normalized end
        end
        local metadata = result.metadata or {}
        local total = tonumber(metadata.total) or #items
        return Result.ok({ items = copy(items), total = total, limit = limit, offset = offset }, {
            total = total, limit = limit, offset = offset
        })
    end
    local candidates = {}
    for _, worker in pairs(self._workers) do
        if worker.state == 'AVAILABLE' and not (worker.profile.profileType == 'SEMI_PERSISTENT' and type(worker.expiresAt) == 'number' and worker.expiresAt <= now(self._clock)) then
            local district = options.district and tostring(options.district):lower()
            local districtMatches = district == nil or worker.activeDistrict == district or worker.profile.homeDistrict == district
            local priceMatches = options.priceClass == nil or tonumber(options.priceClass) == worker.profile.priceClass
            local maxPriceMatches = options.maxPriceClass == nil or worker.profile.priceClass <= tonumber(options.maxPriceClass)
            local ratingMatches = options.minRating == nil or worker.profile.rating >= tonumber(options.minRating)
            local travelMatches = options.travelMode == nil or tostring(options.travelMode):upper() == worker.profile.travelMode
            if districtMatches and priceMatches and maxPriceMatches and ratingMatches and travelMatches then
                candidates[#candidates + 1] = worker
            end
        end
    end
    table.sort(candidates, function(left, right) return left.workerKey < right.workerKey end)
    local total, items = #candidates, {}
    for index = offset + 1, math.min(offset + limit, total) do items[#items + 1] = copy(candidates[index]) end
    return Result.ok({ items = items, total = total, limit = limit, offset = offset }, { total = total, limit = limit, offset = offset })
end

function Service:reserve(workerKey, bookingId, options)
    options = options or {}
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) then return invalid('NPC worker reservation identity is invalid') end
    local currentResult = self:get(workerKey)
    if not currentResult.ok then return currentResult end
    local worker = currentResult.value
    local at = now(self._clock)
    if worker.state == 'RESERVED' and tostring(worker.bookingId) == tostring(bookingId) and holdActive(worker.holdUntil, at) then
        return Result.ok(copy(worker), { idempotent = true })
    end
    if worker.state ~= 'AVAILABLE' then return workerError(Codes.NPC_WORKER_CONFLICT, 'NPC worker is already reserved', { workerKey = workerKey }) end
    local ttl = tonumber(options.ttlSeconds or options.ttl or self._defaultTtl)
    if not ttl or ttl < 1 or ttl > 86400 or ttl ~= math.floor(ttl) then return invalid('NPC worker reservation TTL is invalid') end
    local key = reservationKey(workerKey, bookingId)
    local holdUntil = options.holdUntil or (at + ttl)
    if not finite(tonumber(holdUntil)) then return invalid('NPC worker reservation expiry is invalid') end
    if self._locks then
        local locked = self._locks:reserve(tostring(bookingId), { { type = 'NPC', id = workerKey, ttlSeconds = ttl } }, { now = at })
        if type(locked) ~= 'table' or not locked.ok then
            return workerError(Codes.NPC_WORKER_CONFLICT, 'NPC worker lock could not be acquired', { workerKey = workerKey })
        end
    end
    if self._repository and type(self._repository.reserveWorkerAtomic) == 'function' then
        local persisted = self._repository:reserveWorkerAtomic(workerKey, bookingId, key, holdUntil, worker.version)
        if type(persisted) ~= 'table' then
            releaseLock(self._locks, bookingId, workerKey, ttl)
            return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker reservation returned an invalid result')
        end
        if not persisted.ok then
            releaseLock(self._locks, bookingId, workerKey, ttl)
            return persisted
        end
    end
    worker.state, worker.bookingId, worker.reservationKey, worker.holdUntil = 'RESERVED', tostring(bookingId), key, holdUntil
    worker.version = (tonumber(worker.version) or 1) + 1
    self._workers[workerKey] = worker
    return Result.ok(copy(worker), { idempotent = false })
end

function Service:occupy(workerKey, bookingId)
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) then return invalid('NPC worker occupancy identity is invalid') end
    local result = self:get(workerKey)
    if not result.ok then return result end
    local worker = result.value
    if worker.state ~= 'RESERVED' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker is not reserved', { workerKey = workerKey }) end
    if tostring(worker.bookingId) ~= tostring(bookingId) then return workerError(Codes.NPC_WORKER_OWNER_MISMATCH, 'NPC worker reservation belongs to another booking', { workerKey = workerKey }) end
    if self._repository and type(self._repository.occupyWorkerAtomic) == 'function' then
        local persisted = self._repository:occupyWorkerAtomic(workerKey, bookingId, worker.version)
        if type(persisted) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker occupancy returned an invalid result') end
        if not persisted.ok then return persisted end
    end
    worker.state, worker.version = 'OCCUPIED', (tonumber(worker.version) or 1) + 1
    self._workers[workerKey] = worker
    return Result.ok(copy(worker))
end

function Service:release(workerKey, bookingId)
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) then return invalid('NPC worker release identity is invalid') end
    local result = self:get(workerKey)
    if not result.ok then return result end
    local worker = result.value
    if tostring(worker.bookingId) ~= tostring(bookingId) then return workerError(Codes.NPC_WORKER_OWNER_MISMATCH, 'NPC worker reservation belongs to another booking', { workerKey = workerKey }) end
    if worker.state ~= 'RESERVED' and worker.state ~= 'OCCUPIED' then return Result.ok(copy(worker), { idempotent = true }) end
    if self._repository and type(self._repository.releaseWorkerAtomic) == 'function' then
        local persisted = self._repository:releaseWorkerAtomic(workerKey, bookingId, worker.version)
        if type(persisted) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker release returned an invalid result') end
        if not persisted.ok then return persisted end
    end
    releaseLock(self._locks, bookingId, workerKey, self._defaultTtl)
    worker.state, worker.bookingId, worker.reservationKey, worker.holdUntil = 'AVAILABLE', nil, nil, nil
    worker.version = (tonumber(worker.version) or 1) + 1
    self._workers[workerKey] = worker
    return Result.ok(copy(worker), { idempotent = false })
end

function Service:expire(at)
    at = tonumber(at) or now(self._clock)
    local expired, released = 0, 0
    for workerKey, worker in pairs(self._workers) do
        if worker.state == 'RESERVED' and type(worker.holdUntil) == 'number' and worker.holdUntil <= at then
            releaseLock(self._locks, worker.bookingId, workerKey, self._defaultTtl)
            worker.state, worker.bookingId, worker.reservationKey, worker.holdUntil = 'AVAILABLE', nil, nil, nil
            worker.version = (tonumber(worker.version) or 1) + 1
            released = released + 1
        end
        if worker.profile.profileType == 'SEMI_PERSISTENT' and type(worker.expiresAt) == 'number' and worker.expiresAt <= at then
            releaseLock(self._locks, worker.bookingId, workerKey, self._defaultTtl)
            worker.state, worker.bookingId, worker.reservationKey, worker.holdUntil = 'EXPIRED', nil, nil, nil
            worker.version = (tonumber(worker.version) or 1) + 1
            expired = expired + 1
        end
    end
    local persisted = 0
    if self._repository and type(self._repository.expireWorkers) == 'function' then
        local result = self._repository:expireWorkers()
        if type(result) ~= 'table' then return workerError(Codes.NPC_WORKER_UNAVAILABLE, 'NPC worker expiry returned an invalid result') end
        if not result.ok then return result end
        persisted = tonumber(result.value and result.value.expired) or 0
    end
    return Result.ok({ expired = math.max(expired, persisted), released = released })
end

Service.reserveWorker = Service.reserve
Service.releaseWorker = Service.release
Service.occupyWorker = Service.occupy
NightShift.NpcWorkerService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.NpcWorker = Service
