NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Defaults = (NightShift.NpcStreamingConfig or {}).budget or {}

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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) or value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function token(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= maximum and
        value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function source(value)
    return integer(value, 1, 65535)
end

local function invalid(message, details)
    return Result.err(Codes.NPC_STREAMING_BUDGET_INVALID, message, details)
end

local function clockNow(clock, supplied)
    if supplied ~= nil then
        supplied = tonumber(supplied)
        if finite(supplied) then return supplied end
        return nil
    end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and finite(value) then return value end
    elseif type(clock) == 'function' then
        local ok, value = pcall(clock)
        value = tonumber(value)
        if ok and finite(value) then return value end
    end
    return os.time()
end

local function normalizeConfig(input)
    input = type(input) == 'table' and input or {}
    if input.enabled ~= nil and type(input.enabled) ~= 'boolean' then
        return nil, invalid('NPC streaming budget enabled flag is invalid')
    end
    local function configured(name, fallback)
        return input[name] == nil and fallback or input[name]
    end
    local config = {
        enabled = input.enabled ~= false,
        maxActive = integer(configured('maxActive', Defaults.maxActive or 64), 1, 100000),
        maxPerSource = integer(configured('maxPerSource', Defaults.maxPerSource or 8), 1, 100000),
        maxPerDistrict = integer(configured('maxPerDistrict', Defaults.maxPerDistrict or 32), 1, 100000),
        maxTracked = integer(configured('maxTracked', Defaults.maxTracked or 512), 1, 100000),
        leaseSeconds = tonumber(configured('leaseSeconds', Defaults.leaseSeconds or 120))
    }
    if not config.maxActive or not config.maxPerSource or not config.maxPerDistrict or not config.maxTracked then
        return nil, invalid('NPC streaming budget limits must be positive integers')
    end
    if not finite(config.leaseSeconds) or config.leaseSeconds <= 0 or config.leaseSeconds > 86400 then
        return nil, invalid('NPC streaming budget lease duration is invalid')
    end
    if config.maxPerSource > config.maxActive or config.maxPerDistrict > config.maxActive then
        return nil, invalid('NPC streaming budget scope limits cannot exceed maxActive')
    end
    if config.maxTracked < config.maxActive then
        return nil, invalid('NPC streaming budget maxTracked cannot be below maxActive')
    end
    return config
end

local function district(value)
    if value == nil then return 'global' end
    if not token(value, 96) then return nil end
    return value
end

local function leaseKey(playerSource, npcId)
    return tostring(playerSource) .. '|' .. npcId
end

function Service.new(options)
    options = options or {}
    local config, configError = normalizeConfig(options.config or Defaults)
    if not config then return nil, configError end
    if options.isLeaseActive ~= nil and type(options.isLeaseActive) ~= 'function' then
        return nil, invalid('NPC streaming lease activity resolver is invalid')
    end
    return setmetatable({
        _clock = options.clock,
        _config = config,
        _leases = {},
        _sourceCounts = {},
        _districtCounts = {},
        _active = 0,
        _sequence = 0,
        _isLeaseActive = options.isLeaseActive,
        _running = false,
        _lastSweep = nil,
        _lastRenewed = 0,
        _lastReleased = 0
    }, Service)
end

function Service:config()
    return copy(self._config)
end

function Service:_remove(key, lease)
    self._leases[key] = nil
    self._active = math.max(0, self._active - 1)
    self._sourceCounts[lease.source] = math.max(0, (self._sourceCounts[lease.source] or 1) - 1)
    self._districtCounts[lease.district] = math.max(0, (self._districtCounts[lease.district] or 1) - 1)
    if self._sourceCounts[lease.source] == 0 then self._sourceCounts[lease.source] = nil end
    if self._districtCounts[lease.district] == 0 then self._districtCounts[lease.district] = nil end
end

function Service:_purge(now)
    local removed = 0
    for key, lease in pairs(self._leases) do
        if lease.expiresAt <= now then
            self:_remove(key, lease)
            removed = removed + 1
        end
    end
    return removed
end

function Service:request(playerSource, npcId, districtValue, suppliedNow)
    playerSource = source(playerSource)
    if not playerSource then return invalid('NPC streaming source is invalid') end
    if not token(npcId, 160) then return invalid('NPC streaming worker ID is invalid') end
    districtValue = district(districtValue)
    if not districtValue then return invalid('NPC streaming district is invalid') end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    self:_purge(now)
    local key = leaseKey(playerSource, npcId)
    local existing = self._leases[key]
    if existing then
        if existing.district ~= districtValue then
            return Result.err(Codes.NPC_STREAMING_BUDGET_CONFLICT,
                'NPC streaming lease is already assigned to another district', {
                    source = playerSource, npcId = npcId,
                    district = existing.district, requestedDistrict = districtValue
                })
        end
        return Result.ok(copy(existing), { idempotent = true })
    end
    if not self._config.enabled then
        return Result.ok({
            enabled = false, admitted = true, bypassed = true,
            source = playerSource, npcId = npcId, district = districtValue
        }, { bypassed = true })
    end
    if self._active >= self._config.maxTracked then
        return Result.err(Codes.NPC_STREAMING_BUDGET_EXHAUSTED,
            'NPC streaming tracking budget is exhausted', { maxTracked = self._config.maxTracked })
    end
    if self._active >= self._config.maxActive then
        return Result.err(Codes.NPC_STREAMING_BUDGET_EXHAUSTED,
            'NPC streaming active budget is exhausted', { maxActive = self._config.maxActive })
    end
    local sourceCount = self._sourceCounts[playerSource] or 0
    if sourceCount >= self._config.maxPerSource then
        return Result.err(Codes.NPC_STREAMING_SOURCE_BUDGET_EXHAUSTED,
            'NPC streaming source budget is exhausted', {
                source = playerSource, maxPerSource = self._config.maxPerSource
            })
    end
    local districtCount = self._districtCounts[districtValue] or 0
    if districtCount >= self._config.maxPerDistrict then
        return Result.err(Codes.NPC_STREAMING_DISTRICT_BUDGET_EXHAUSTED,
            'NPC streaming district budget is exhausted', {
                district = districtValue, maxPerDistrict = self._config.maxPerDistrict
            })
    end
    self._sequence = self._sequence + 1
    local lease = {
        source = playerSource,
        npcId = npcId,
        district = districtValue,
        leaseToken = ('stream:%d:%d'):format(playerSource, self._sequence),
        issuedAt = now,
        expiresAt = now + self._config.leaseSeconds
    }
    self._leases[key] = lease
    self._active = self._active + 1
    self._sourceCounts[playerSource] = sourceCount + 1
    self._districtCounts[districtValue] = districtCount + 1
    return Result.ok(copy(lease), { created = true })
end

function Service:renew(playerSource, npcId, suppliedNow)
    playerSource = source(playerSource)
    if not playerSource or not token(npcId, 160) then return invalid('NPC streaming lease reference is invalid') end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    self:_purge(now)
    local key = leaseKey(playerSource, npcId)
    local lease = self._leases[key]
    if not lease then
        return Result.err(Codes.NPC_STREAMING_BUDGET_INVALID, 'NPC streaming lease was not found')
    end
    local renewed = copy(lease)
    renewed.issuedAt = now
    renewed.expiresAt = now + self._config.leaseSeconds
    self._leases[key] = renewed
    return Result.ok(copy(renewed), { renewed = true })
end

function Service:_renewActive(now, activityResolver)
    self:_purge(now)
    local renewed, released = 0, 0
    local keys = {}
    for key in pairs(self._leases) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local lease = self._leases[key]
        if lease then
            local keep = true
            if type(activityResolver) == 'function' then
                local ok, result = pcall(activityResolver, copy(lease))
                if type(result) == 'table' then
                    keep = ok and result.ok == true and
                        (result.value == nil or result.value.active ~= false)
                else
                    keep = ok and result == true
                end
            end
            if keep then
                lease.issuedAt = now
                lease.expiresAt = now + self._config.leaseSeconds
                renewed = renewed + 1
            else
                self:_remove(key, lease)
                released = released + 1
            end
        end
    end
    self._lastSweep = now
    self._lastRenewed = renewed
    self._lastReleased = released
    return { renewed = renewed, released = released }
end

function Service:renewActive(suppliedNow, activityResolver)
    if activityResolver ~= nil and type(activityResolver) ~= 'function' then
        return invalid('NPC streaming lease activity resolver is invalid')
    end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    local resolver = activityResolver or self._isLeaseActive
    if type(resolver) ~= 'function' then
        return Result.ok({ renewed = 0, released = 0, skipped = true }, { missingActivityResolver = true })
    end
    return Result.ok(self:_renewActive(now, resolver))
end

function Service:start(options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('NPC streaming budget start options must be a table') end
    if options.isLeaseActive ~= nil and type(options.isLeaseActive) ~= 'function' then
        return invalid('NPC streaming lease activity resolver is invalid')
    end
    if self._running then return Result.ok({ running = true }, { idempotent = true }) end
    if not self._config.enabled then
        return Result.ok({ running = false, skipped = true }, { disabled = true })
    end
    local resolver = options.isLeaseActive or self._isLeaseActive
    if type(resolver) ~= 'function' then
        return Result.ok({ running = false, skipped = true }, { missingActivityResolver = true })
    end
    local createThread = type(CreateThread) == 'function' and CreateThread or rawget(_G, 'CreateThread')
    local wait = type(Wait) == 'function' and Wait or rawget(_G, 'Wait')
    if type(createThread) ~= 'function' or type(wait) ~= 'function' then
        return Result.ok({ running = false, skipped = true }, { runtimeUnavailable = true })
    end
    self._isLeaseActive = resolver
    self._running = true
    local tickSeconds = math.max(1, self._config.leaseSeconds / 2)
    createThread(function()
        while self._running do
            local now = clockNow(self._clock)
            if now then pcall(self._renewActive, self, now, self._isLeaseActive) end
            wait(tickSeconds * 1000)
        end
    end)
    return Result.ok({ running = true }, { intervalSeconds = tickSeconds })
end

function Service:stop()
    if not self._running then return Result.ok({ running = false }, { idempotent = true }) end
    self._running = false
    return Result.ok({ running = false })
end

function Service:release(playerSource, npcId, suppliedNow)
    playerSource = source(playerSource)
    if not playerSource or not token(npcId, 160) then return invalid('NPC streaming lease reference is invalid') end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    self:_purge(now)
    local key = leaseKey(playerSource, npcId)
    local lease = self._leases[key]
    if not lease then
        return Result.ok({ released = false, source = playerSource, npcId = npcId }, { idempotent = true })
    end
    self:_remove(key, lease)
    return Result.ok({ released = true, leaseToken = lease.leaseToken, source = playerSource, npcId = npcId })
end

function Service:releaseByToken(leaseToken, suppliedNow)
    if not token(leaseToken, 192) then return invalid('NPC streaming lease token is invalid') end
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    self:_purge(now)
    for key, lease in pairs(self._leases) do
        if lease.leaseToken == leaseToken then
            self:_remove(key, lease)
            return Result.ok({ released = true, leaseToken = leaseToken })
        end
    end
    return Result.ok({ released = false, leaseToken = leaseToken }, { idempotent = true })
end

function Service:status(suppliedNow)
    local now = clockNow(self._clock, suppliedNow)
    if not now then return invalid('NPC streaming budget clock value is invalid') end
    local expired = self:_purge(now)
    return Result.ok({
        enabled = self._config.enabled,
        active = self._active,
        maxActive = self._config.maxActive,
        maxTracked = self._config.maxTracked,
        maxPerSource = self._config.maxPerSource,
        maxPerDistrict = self._config.maxPerDistrict,
        leaseSeconds = self._config.leaseSeconds,
        running = self._running,
        lastSweep = self._lastSweep,
        lastRenewed = self._lastRenewed,
        lastReleased = self._lastReleased,
        expired = expired,
        sourceCounts = copy(self._sourceCounts),
        districtCounts = copy(self._districtCounts)
    })
end

function Service:reset()
    local removed = self._active
    self._leases, self._sourceCounts, self._districtCounts = {}, {}, {}
    self._active = 0
    return Result.ok({ removed = removed })
end

NightShift.NpcStreamingBudgetService = Service
