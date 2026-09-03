NightShift = NightShift or {}
NightShift.Jobs = NightShift.Jobs or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Job = {}
Job.__index = Job

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function nowValue(clock, supplied)
    if supplied ~= nil then return integer(supplied, 0) end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok then return integer(value, 0) end
    end
    return os.time()
end

function Job.new(options)
    options = options or {}
    local service = options.heatService or options.service
    if type(service) ~= 'table' or type(service.decay) ~= 'function' then
        return nil, Result.err(Codes.HEAT_OPERATION_FAILED, 'heat decay job requires a heat service')
    end
    local config = options.config or NightShift.HeatConfig or {}
    if type(config) ~= 'table' then
        return nil, Result.err(Codes.HEAT_INVALID, 'heat decay configuration must be a table')
    end
    local enabled = config.enabled
    if enabled == nil then enabled = true end
    if type(enabled) ~= 'boolean' then
        return nil, Result.err(Codes.HEAT_INVALID, 'heat decay enabled flag must be boolean')
    end
    local interval = config.decayIntervalSeconds == nil and 300
        or integer(config.decayIntervalSeconds, 1, 86400)
    if not interval then
        return nil, Result.err(Codes.HEAT_INVALID, 'heat decay interval must be a positive number of seconds')
    end
    return setmetatable({
        _service = service,
        _clock = options.clock,
        _enabled = enabled,
        _intervalSeconds = interval,
        _running = false,
        _lastRun = nil
    }, Job)
end

function Job:isRunning()
    return self._running == true
end

function Job:runOnce(suppliedNow)
    if not self._enabled then
        return Result.ok({ skipped = true, changed = 0 }, { disabled = true })
    end
    local timestamp = nowValue(self._clock, suppliedNow)
    if timestamp == nil then
        return Result.err(Codes.HEAT_OPERATION_FAILED, 'heat decay clock returned an invalid timestamp')
    end
    local ok, result = pcall(self._service.decay, self._service, timestamp)
    if not ok or type(result) ~= 'table' then
        return Result.err(Codes.HEAT_OPERATION_FAILED, 'heat decay service raised an error')
    end
    if result.ok ~= true then return result end
    local value = type(result.value) == 'table' and result.value or {}
    local summary = {
        at = timestamp,
        changed = tonumber(value.changed) or 0,
        skipped = value.skipped == true
    }
    self._lastRun = summary
    return Result.ok(summary, { intervalSeconds = self._intervalSeconds })
end

function Job:start()
    if self._running then return Result.ok({ running = true }, { idempotent = true }) end
    if not self._enabled then return Result.ok({ running = false, skipped = true }, { disabled = true }) end
    local createThread = rawget(_G, 'CreateThread')
    local wait = rawget(_G, 'Wait')
    if type(createThread) ~= 'function' or type(wait) ~= 'function' then
        return Result.err(Codes.HEAT_OPERATION_FAILED, 'heat decay runtime loop is unavailable')
    end
    self._running = true
    createThread(function()
        while self._running do
            pcall(self.runOnce, self)
            wait(self._intervalSeconds * 1000)
        end
    end)
    return Result.ok({ running = true }, { intervalSeconds = self._intervalSeconds })
end

function Job:stop()
    local wasRunning = self._running
    self._running = false
    return Result.ok({ running = false }, { idempotent = not wasRunning })
end

NightShift.HeatDecayJob = Job
NightShift.Jobs.HeatDecay = Job
