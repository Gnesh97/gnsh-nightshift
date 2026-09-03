NightShift = NightShift or {}
NightShift.Jobs = NightShift.Jobs or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Job = {}
Job.__index = Job

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item) end
    return output
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.SCHEDULING_INVALID, message, details)
end

local function configValue(config, name, fallback, minimum, maximum)
    local value = config[name]
    value = value == nil and fallback or integer(value, minimum, maximum)
    if value == nil then return nil, invalid(('scheduling %s is invalid'):format(name)) end
    return value
end

local function nowValue(clock, supplied)
    if supplied ~= nil then
        supplied = tonumber(supplied)
        if supplied and supplied == supplied and supplied ~= math.huge and supplied ~= -math.huge and supplied >= 0 then return math.floor(supplied) end
        return nil
    end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and value and value == value and value ~= math.huge and value ~= -math.huge and value >= 0 then return math.floor(value) end
    end
    return os.time()
end

local function resultValue(result, message)
    if type(result) ~= 'table' then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'no-show service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok ~= true then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'no-show result envelope is invalid') end
    local value = result.value
    if type(value) ~= 'table' then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'no-show result rows are invalid') end
    return value
end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = Codes.SCHEDULING_OPERATION_FAILED, message = 'hook returned an invalid result' }
end

function Job.new(options)
    options = options or {}
    local repository = options.repository or options.bookingRepository
    if type(repository) ~= 'table' or type(repository.findDueArrived) ~= 'function' then
        return nil, Result.err(Codes.SCHEDULING_NOT_READY, 'no-show job requires a due booking repository')
    end
    local bookingService = options.bookingService
    if type(bookingService) ~= 'table' or type(bookingService.expire) ~= 'function' then
        return nil, Result.err(Codes.SCHEDULING_NOT_READY, 'no-show job requires booking expiration service')
    end
    local config = options.config or NightShift.SchedulingConfig or {}
    if type(config) ~= 'table' then return nil, invalid('scheduling configuration must be a table') end
    local enabled = config.enabled
    if enabled == nil then enabled = true end
    if type(enabled) ~= 'boolean' then return nil, invalid('scheduling enabled flag must be boolean') end
    local tick, tickError = configValue(config, 'tickSeconds', 15, 1, 86400)
    if not tick then return nil, tickError end
    local batch, batchError = configValue(config, 'batchSize', 50, 1, 100)
    if not batch then return nil, batchError end
    local grace, graceError = configValue(config, 'noShowGraceSeconds', 300, 0, 604800)
    if not grace then return nil, graceError end
    return setmetatable({
        _repository = repository,
        _bookingService = bookingService,
        _refund = options.refundService or options.refund,
        _deposit = options.depositService or options.deposit,
        _reputation = options.reputationService or options.reputation,
        _incident = options.incidentService or options.incident,
        _eventBus = options.eventBus,
        _clock = options.clock or NightShift.Clock and NightShift.Clock.new and NightShift.Clock.new() or nil,
        _enabled = enabled,
        _tickSeconds = tick,
        _batchSize = batch,
        _graceSeconds = grace,
        _systemActor = copy(options.systemActor or { type = 'SYSTEM', ref = 'nightshift:no-show' }),
        _reasonResolver = options.reasonResolver,
        _refundActorResolver = options.refundActorResolver,
        _processed = {},
        _running = false,
        _lastRun = nil
    }, Job)
end

function Job:_reason(booking)
    if type(self._reasonResolver) == 'function' then
        local ok, value = pcall(self._reasonResolver, copy(booking))
        if ok then
            if type(value) == 'table' and type(value.reason) == 'string' then
                return value.code or (value.reason == 'worker-no-show' and Codes.WORKER_NO_SHOW or Codes.CLIENT_NO_SHOW), value.reason
            end
            if type(value) == 'string' and value:match('%S') then
                return value == 'worker-no-show' and Codes.WORKER_NO_SHOW or Codes.CLIENT_NO_SHOW, value
            end
        end
    end
    if tostring(booking and booking.workerType or ''):upper() == 'PLAYER' and tostring(booking and booking.clientType or ''):upper() ~= 'PLAYER' then
        return Codes.WORKER_NO_SHOW, 'worker-no-show'
    end
    return Codes.CLIENT_NO_SHOW, 'client-no-show'
end

function Job:_hook(summary, name, callback)
    if type(callback) ~= 'function' then return true end
    local ok, result = pcall(callback)
    if not ok or type(result) ~= 'table' or result.ok == false then
        summary.hookFailures = summary.hookFailures + 1
        if #summary.errors < 20 then
            local errorResult = ok and errorValue(result) or { code = Codes.SCHEDULING_OPERATION_FAILED, message = tostring(result) }
            summary.errors[#summary.errors + 1] = { hook = name, code = errorResult.code, message = errorResult.message }
        end
        return false
    end
    return true
end

function Job:runOnce(suppliedNow)
    if not self._enabled then return Result.ok({ skipped = true, scanned = 0, expired = 0, idempotent = 0 }, { disabled = true }) end
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('no-show clock returned an invalid timestamp') end
    local fetched = self._repository:findDueArrived(now, {
        graceSeconds = self._graceSeconds,
        limit = self._batchSize
    })
    local bookings, fetchError = resultValue(fetched, 'arrived due query returned an invalid result')
    if not bookings then return fetchError end
    local summary = { scanned = #bookings, expired = 0, idempotent = 0, failed = 0, refunded = 0, deposits = 0, reputation = 0, incidents = 0, hookFailures = 0, errors = {} }
    for _, booking in ipairs(bookings) do
        local id = type(booking) == 'table' and booking.id or nil
        local version = type(booking) == 'table' and integer(booking.version, 1) or nil
        if id == nil or not version then
            summary.failed = summary.failed + 1
            if #summary.errors < 20 then summary.errors[#summary.errors + 1] = { id = id, code = Codes.SCHEDULING_INVALID, message = 'arrived booking identity is invalid' } end
        elseif self._processed[tostring(id)] then
            summary.idempotent = summary.idempotent + 1
        else
            local reasonCode, reason = self:_reason(booking)
            local ok, expiration = pcall(self._bookingService.expire, self._bookingService, self._systemActor, id, version, reason)
            local expired = ok and type(expiration) == 'table' and expiration.ok == true
            if not expired then
                local errorResult = ok and errorValue(expiration) or { code = Codes.SCHEDULING_OPERATION_FAILED, message = 'no-show expiration raised an error' }
                local recovered = false
                if errorResult.code == Codes.VERSION_CONFLICT and type(self._repository.findById) == 'function' then
                    local latest = self._repository:findById(id)
                    local current = type(latest) == 'table' and latest.ok and latest.value or nil
                    recovered = type(current) == 'table' and current.status == 'EXPIRED'
                end
                if recovered then
                    self._processed[tostring(id)] = true
                    summary.idempotent = summary.idempotent + 1
                else
                    summary.failed = summary.failed + 1
                    if #summary.errors < 20 then summary.errors[#summary.errors + 1] = { id = id, code = errorResult.code, message = errorResult.message } end
                end
            else
                local after = copy(booking)
                if type(expiration.value) == 'table' then
                    for key, value in pairs(expiration.value) do after[key] = copy(value) end
                end
                after.status = 'EXPIRED'
                summary.expired = summary.expired + 1
                self._processed[tostring(id)] = true
                local refundActor = self._systemActor
                if type(self._refundActorResolver) == 'function' then
                    local resolvedOk, resolved = pcall(self._refundActorResolver, copy(after), reasonCode)
                    if resolvedOk and type(resolved) == 'table' then refundActor = resolved end
                end
                if self:_hook(summary, 'refund', self._refund and function()
                    local result = self._refund:refund(after, refundActor)
                    if type(result) == 'table' and result.ok then summary.refunded = summary.refunded + 1 end
                    return result
                end) then end
                if self:_hook(summary, 'deposit', self._deposit and function()
                    local result = type(self._deposit.retain) == 'function' and self._deposit:retain(after, refundActor) or Result.ok({ skipped = true })
                    if type(result) == 'table' and result.ok then summary.deposits = summary.deposits + 1 end
                    return result
                end) then end
                if self:_hook(summary, 'reputation', self._reputation and function()
                    local result = type(self._reputation.apply) == 'function' and self._reputation:apply(after, {
                        eventKey = ('no-show:%s'):format(tostring(id)),
                        target = 'EXPIRED',
                        reason = reason,
                        reasonCode = reasonCode,
                        noShow = true
                    }) or Result.ok({ skipped = true })
                    if type(result) == 'table' and result.ok then summary.reputation = summary.reputation + 1 end
                    return result
                end) then end
                if self:_hook(summary, 'incident', self._incident and function()
                    local result = self._incident:report(self._systemActor, {
                        bookingId = id,
                        type = reasonCode == Codes.WORKER_NO_SHOW and 'WORKER_NO_SHOW' or 'CUSTOMER_NO_SHOW',
                        idempotencyKey = ('no-show:%s'):format(tostring(id)),
                        reason = reason,
                        metadata = { reasonCode = reasonCode, source = 'no-show-job' }
                    })
                    if type(result) == 'table' and result.ok then summary.incidents = summary.incidents + 1 end
                    return result
                end) then end
                if self._eventBus and type(self._eventBus.publishCommitted) == 'function' then
                    pcall(self._eventBus.publishCommitted, self._eventBus, 'booking.no_show', {
                        booking = copy(after), reason = reason, reasonCode = reasonCode, noShow = true
                    }, { correlationId = after.correlationId })
                end
            end
        end
    end
    self._lastRun = copy(summary)
    return Result.ok(summary, { now = now, graceSeconds = self._graceSeconds })
end

function Job:start()
    if self._running then return Result.ok({ running = true }, { idempotent = true }) end
    if not self._enabled then return Result.ok({ running = false, skipped = true }, { disabled = true }) end
    local createThread = type(CreateThread) == 'function' and CreateThread or rawget(_G, 'CreateThread')
    local wait = type(Wait) == 'function' and Wait or rawget(_G, 'Wait')
    if type(createThread) ~= 'function' or type(wait) ~= 'function' then return Result.err(Codes.SCHEDULING_NOT_READY, 'no-show runtime loop is unavailable') end
    self._running = true
    createThread(function()
        while self._running do
            pcall(self.runOnce, self)
            wait(self._tickSeconds * 1000)
        end
    end)
    return Result.ok({ running = true })
end

function Job:stop()
    local wasRunning = self._running
    self._running = false
    return Result.ok({ running = false }, { idempotent = not wasRunning })
end

NightShift.NoShowJob = Job
NightShift.Jobs.NoShow = Job
