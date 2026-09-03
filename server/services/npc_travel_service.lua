NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Plan = NightShift.Domain.TravelPlan
local Config = NightShift.NpcStreamingConfig or {}

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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.TRAVEL_INVALID, message, details)
end

local function unwrap(value, fallback)
    if type(value) ~= 'table' then return nil, Result.err(fallback or Codes.TRAVEL_INVALID, 'travel resolver returned an invalid result') end
    if value.ok == false then return nil, value end
    if value.ok == true and value.value ~= nil then return value.value end
    if value.success == true and value.value ~= nil then return value.value end
    return value
end

local function callResolver(resolver, ...)
    if type(resolver) == 'table' and type(resolver.resolve) == 'function' then
        local instance = resolver
        return pcall(function(...) return instance:resolve(...) end, ...)
    end
    if type(resolver) == 'function' then return pcall(resolver, ...) end
    return false, nil
end

local function resolvedSnapshot(value)
    if type(value) ~= 'table' then return nil end
    local output = {}
    for _, key in ipairs({ 'locationType', 'locationRef', 'meetingMode', 'resolvedAt' }) do
        if value[key] ~= nil then output[key] = value[key] end
    end
    if type(value.worldTarget) == 'table' then
        output.worldTarget = {}
        for _, key in ipairs({ 'kind', 'x', 'y', 'z', 'heading', 'provider' }) do
            if value.worldTarget[key] ~= nil then output.worldTarget[key] = value.worldTarget[key] end
        end
    end
    if type(value.route) == 'table' then output.route = copy(value.route) end
    return output
end

local function optionTime(value, fallback)
    if type(value) == 'table' then return value.at or value.timestamp or fallback end
    if value ~= nil then return value end
    return fallback
end

local function validateSource(source)
    source = tonumber(source)
    if not source or source < 1 or source ~= math.floor(source) then return nil end
    return source
end

function Service.new(options)
    options = options or {}
    local config = options.config or Config
    if type(config) ~= 'table' then return nil, invalid('NPC travel configuration is invalid') end
    local threshold = tonumber(options.spawnThreshold or config.spawnThreshold or 0.65)
    local defaultEta = tonumber(options.defaultEtaSeconds or config.defaultEtaSeconds or 60)
    if not finite(threshold) or threshold < 0 or threshold > 1 then return nil, invalid('NPC travel spawn threshold is invalid') end
    if not finite(defaultEta) or defaultEta < 1 or defaultEta > 86400 then return nil, invalid('NPC travel default ETA is invalid') end
    return setmetatable({
        _clock = options.clock,
        _config = copy(config),
        _locationService = options.locationService or options.locationResolver,
        _etaEstimator = options.etaEstimator,
        _spawnThreshold = threshold,
        _defaultEta = defaultEta,
        _plans = {},
        _nextGeneration = 1
    }, Service)
end

function Service:create(source, request)
    source = validateSource(source)
    if not source then return invalid('travel source is invalid') end
    if type(request) ~= 'table' then return invalid('travel request must be a table') end
    local allowed = {
        travelKey = true, bookingId = true, workerKey = true, profileKey = true,
        origin = true, destination = true, mode = true, etaSeconds = true,
        startedAt = true, expectedArrivalAt = true, progress = true,
        spawnThreshold = true, state = true, recoveryState = true
    }
    for key in pairs(request) do
        if not allowed[key] then return invalid('travel request field is not allowlisted', { field = tostring(key) }) end
    end
    if not token(request.bookingId, 160) or not token(request.workerKey, 160) or not token(request.profileKey, 160) then
        return invalid('travel request requires booking, worker, and profile references')
    end
    local resolved
    if self._locationService ~= nil then
        local ok, result = callResolver(self._locationService, source, {
            locationType = request.destination and (request.destination.locationType or request.destination.type),
            locationRef = request.destination and (request.destination.locationRef or request.destination.ref),
            meetingMode = request.destination and request.destination.meetingMode
        })
        if not ok then return Result.err(Codes.TRAVEL_INVALID, 'location resolution failed') end
        local value, resolverError = unwrap(result, Codes.TRAVEL_INVALID)
        if not value then return resolverError end
        resolved = resolvedSnapshot(value)
        if not resolved or type(resolved.worldTarget) ~= 'table' then
            return Result.err(Codes.TRAVEL_INVALID, 'location resolver returned no safe destination')
        end
    end
    local eta = tonumber(request.etaSeconds)
    if eta == nil and type(self._etaEstimator) == 'function' then
        local ok, estimate = pcall(self._etaEstimator, source, copy(request), copy(resolved))
        if ok then
            local estimated, estimateError = unwrap(estimate, Codes.TRAVEL_INVALID)
            eta = tonumber(estimated or estimateError and nil)
            if type(estimated) == 'table' then eta = tonumber(estimated.etaSeconds or estimated.eta) end
            if eta == nil and finite(tonumber(estimate)) then eta = tonumber(estimate) end
        end
    end
    eta = eta or self._defaultEta
    local startedAt = request.startedAt or now(self._clock)
    local travelKey = request.travelKey or ('travel:' .. request.bookingId .. ':' .. request.workerKey)
    if #travelKey > 200 then travelKey = travelKey:sub(1, 200) end
    if not token(travelKey, 200) then return invalid('travel key is invalid') end
    local existing = self._plans[travelKey]
    if existing then
        if existing.bookingId ~= request.bookingId or existing.workerKey ~= request.workerKey or existing.profileKey ~= request.profileKey then
            return Result.err(Codes.TRAVEL_CONFLICT, 'travel key is already bound to another booking')
        end
        return Result.ok(copy(existing), { idempotent = true })
    end
    local plan, planError = Plan.new({
        travelKey = travelKey,
        bookingId = request.bookingId,
        workerKey = request.workerKey,
        profileKey = request.profileKey,
        origin = request.origin,
        destination = request.destination,
        resolvedDestination = resolved,
        mode = request.mode,
        etaSeconds = eta,
        startedAt = startedAt,
        expectedArrivalAt = request.expectedArrivalAt or (tonumber(startedAt) + eta),
        progress = request.progress,
        spawnThreshold = request.spawnThreshold == nil and self._spawnThreshold or request.spawnThreshold,
        state = request.state,
        recoveryState = request.recoveryState,
        generation = self._nextGeneration
    })
    if not plan then return planError end
    self._nextGeneration = self._nextGeneration + 1
    self._plans[travelKey] = plan
    return Result.ok(copy(plan), { created = true })
end

Service.plan = Service.create

function Service:get(travelKey)
    if not token(travelKey, 200) then return Result.err(Codes.TRAVEL_INVALID, 'travel key is invalid') end
    local plan = self._plans[travelKey]
    if not plan then return Result.err(Codes.TRAVEL_NOT_FOUND, 'travel plan was not found', { travelKey = travelKey }) end
    return Result.ok(copy(plan))
end

function Service:start(travelKey, at)
    local found = self:get(travelKey)
    if not found.ok then return found end
    local plan = found.value
    if plan.state ~= 'PLANNED' then return found end
    plan.state = 'TRAVELLING'
    plan.updatedAt = optionTime(at, now(self._clock))
    local normalized, err = Plan.new(plan)
    if not normalized then return err end
    self._plans[travelKey] = normalized
    return Result.ok(copy(normalized))
end

function Service:updateProgress(travelKey, progress, atOrOptions)
    local found = self:get(travelKey)
    if not found.ok then return found end
    local advanced = found.value:advance(progress, optionTime(atOrOptions, now(self._clock)))
    if not advanced.ok then return advanced end
    self._plans[travelKey] = advanced.value
    return Result.ok(copy(advanced.value))
end

function Service:markRecovery(travelKey, recoveryState, atOrOptions)
    local found = self:get(travelKey)
    if not found.ok then return found end
    local recovered = found.value:markRecovery(recoveryState, optionTime(atOrOptions, now(self._clock)))
    if not recovered.ok then return recovered end
    self._plans[travelKey] = recovered.value
    return Result.ok(copy(recovered.value))
end

function Service:shouldSpawn(travelKey)
    local found = self:get(travelKey)
    if not found.ok then return found end
    return Result.ok({ ready = found.value:isSpawnReady(), travel = copy(found.value) })
end

function Service:markArrival(travelKey, atOrOptions)
    local found = self:get(travelKey)
    if not found.ok then return found end
    local arrived = found.value:markArrival(optionTime(atOrOptions, now(self._clock)))
    if not arrived.ok then return arrived end
    self._plans[travelKey] = arrived.value
    return Result.ok(copy(arrived.value))
end

function Service:markReturning(travelKey, atOrOptions)
    return self:markRecovery(travelKey, 'RETURNING', atOrOptions)
end

function Service:cancel(travelKey, at)
    if not token(travelKey, 200) then return Result.err(Codes.TRAVEL_INVALID, 'travel key is invalid') end
    local found = self:get(travelKey)
    if not found.ok then return found end
    local plan = found.value
    if plan.state == 'CANCELLED' then return Result.ok(copy(plan), { idempotent = true }) end
    if plan.state == 'COMPLETED' or plan.state == 'EXPIRED' then
        return Result.err(Codes.TRAVEL_CONFLICT, 'terminal travel plan cannot be cancelled')
    end
    local cancelled = copy(plan)
    cancelled.state = 'CANCELLED'
    cancelled.updatedAt = optionTime(at, now(self._clock))
    local normalized, err = Plan.new(cancelled)
    if not normalized then return err end
    self._plans[travelKey] = nil
    return Result.ok(copy(normalized), { cancelled = true })
end

function Service:list()
    local output = {}
    for _, plan in pairs(self._plans) do output[#output + 1] = copy(plan) end
    table.sort(output, function(left, right) return left.travelKey < right.travelKey end)
    return Result.ok(output)
end

NightShift.NpcTravelService = Service
