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
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
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
    if type(result) ~= 'table' then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'scheduling service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok ~= true then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'scheduling result envelope is invalid') end
    local value = result.value
    if type(value) ~= 'table' then return nil, Result.err(Codes.SCHEDULING_OPERATION_FAILED, message or 'scheduling result rows are invalid') end
    return value
end

function Job.new(options)
    options = options or {}
    local repository = options.repository or options.bookingRepository
    if type(repository) ~= 'table' or type(repository.findDueScheduled) ~= 'function' then
        return nil, Result.err(Codes.SCHEDULING_NOT_READY, 'scheduled booking job requires a due booking repository')
    end
    local bookingService = options.bookingService
    if type(bookingService) ~= 'table' or type(bookingService.activateScheduled) ~= 'function' then
        return nil, Result.err(Codes.SCHEDULING_NOT_READY, 'scheduled booking job requires booking activation service')
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
    local lead, leadError = configValue(config, 'reservationLeadTimeSeconds', 300, 0, 604800)
    if not lead then return nil, leadError end
    return setmetatable({
        _repository = repository,
        _bookingService = bookingService,
        _clock = options.clock or NightShift.Clock and NightShift.Clock.new and NightShift.Clock.new() or nil,
        _enabled = enabled,
        _tickSeconds = tick,
        _batchSize = batch,
        _leadSeconds = lead,
        _activationOptions = copy(options.activationOptions or {}),
        _systemActor = copy(options.systemActor or { type = 'SYSTEM', ref = 'nightshift:scheduler' }),
        _running = false,
        _lastRun = nil
    }, Job)
end

function Job:isRunning()
    return self._running == true
end

function Job:runOnce(suppliedNow)
    if not self._enabled then return Result.ok({ skipped = true, scanned = 0, activated = 0, idempotent = 0 }, { disabled = true }) end
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('scheduler clock returned an invalid timestamp') end
    local fetched = self._repository:findDueScheduled(now, {
        leadTimeSeconds = self._leadSeconds,
        limit = self._batchSize
    })
    local bookings, fetchError = resultValue(fetched, 'scheduled due query returned an invalid result')
    if not bookings then return fetchError end
    local summary = { scanned = #bookings, activated = 0, idempotent = 0, conflicts = 0, failed = 0, errors = {} }
    for _, booking in ipairs(bookings) do
        local id = type(booking) == 'table' and booking.id or nil
        local version = type(booking) == 'table' and integer(booking.version, 1) or nil
        if id == nil or not version then
            summary.failed = summary.failed + 1
            if #summary.errors < 20 then summary.errors[#summary.errors + 1] = { id = id, code = Codes.SCHEDULING_INVALID, message = 'scheduled booking identity is invalid' } end
        else
            local ok, activation = pcall(self._bookingService.activateScheduled, self._bookingService, self._systemActor, id, version, copy(self._activationOptions))
            if not ok or type(activation) ~= 'table' then
                summary.failed = summary.failed + 1
                if #summary.errors < 20 then summary.errors[#summary.errors + 1] = { id = id, code = Codes.SCHEDULING_OPERATION_FAILED, message = 'scheduled activation raised an error' } end
            elseif activation.ok then
                if activation.metadata and activation.metadata.idempotent then
                    summary.idempotent = summary.idempotent + 1
                else
                    summary.activated = summary.activated + 1
                end
            else
                local errorValue = activation.error or activation
                local recovered = false
                if errorValue.code == Codes.VERSION_CONFLICT and type(self._repository.findById) == 'function' then
                    local latest = self._repository:findById(id)
                    local current = type(latest) == 'table' and latest.ok and latest.value or nil
                    recovered = type(current) == 'table' and current.status == 'RESERVED'
                end
                if recovered then
                    summary.idempotent = summary.idempotent + 1
                else
                    if errorValue.code == Codes.SCHEDULING_CONFLICT then summary.conflicts = summary.conflicts + 1 end
                    summary.failed = summary.failed + 1
                    if #summary.errors < 20 then summary.errors[#summary.errors + 1] = { id = id, code = errorValue.code, message = errorValue.message } end
                end
            end
        end
    end
    self._lastRun = copy(summary)
    return Result.ok(summary, { now = now, leadTimeSeconds = self._leadSeconds })
end

function Job:start()
    if self._running then return Result.ok({ running = true }, { idempotent = true }) end
    if not self._enabled then return Result.ok({ running = false, skipped = true }, { disabled = true }) end
    local createThread = type(CreateThread) == 'function' and CreateThread or rawget(_G, 'CreateThread')
    local wait = type(Wait) == 'function' and Wait or rawget(_G, 'Wait')
    if type(createThread) ~= 'function' or type(wait) ~= 'function' then
        return Result.err(Codes.SCHEDULING_NOT_READY, 'scheduler runtime loop is unavailable')
    end
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

NightShift.ScheduledBookingJob = Job
NightShift.Jobs.ScheduledBooking = Job
