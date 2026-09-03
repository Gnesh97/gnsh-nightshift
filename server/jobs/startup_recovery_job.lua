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

local function invalid(message)
    return Result.err(Codes.RECOVERY_INVALID, message)
end

local function isProduction(environment)
    environment = type(environment) == 'string' and environment:lower() or ''
    return environment == 'production' or environment == 'prod'
end

function Job.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('startup recovery options must be a table') end
    local recovery = options.recoveryService or options.recovery
    if type(recovery) ~= 'table' or type(recovery.runOnce) ~= 'function' then
        return nil, Result.err(Codes.RECOVERY_NOT_READY, 'startup recovery job requires a recovery service')
    end
    local config = options.config or NightShift.RecoveryConfig or {}
    if type(config) ~= 'table' then return nil, invalid('startup recovery configuration must be a table') end
    local enabled = config.enabled
    if enabled == nil then enabled = true end
    if type(enabled) ~= 'boolean' then return nil, invalid('startup recovery enabled flag must be boolean') end
    local production = isProduction(options.environment)
    return setmetatable({
        _recovery = recovery, _clock = options.clock, _enabled = enabled,
        _required = config.required == true or production, _production = production,
        _apply = config.apply == true and production,
        _ran = false, _lastRun = nil
    }, Job)
end

function Job:runOnce(suppliedNow, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('startup recovery run options must be a table') end
    if self._ran then return Result.ok(copy(self._lastRun or { scanned = 0, pages = 0 }), { idempotent = true }) end
    if not self._enabled then
        self._ran = true
        self._lastRun = { skipped = true, scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0 }
        return Result.ok(copy(self._lastRun), { disabled = true })
    end
    if self._production and not self._apply then
        return Result.err(Codes.RECOVERY_REQUIRED,
            'production startup recovery requires recovery.apply=true before READY')
    end
    -- Development startup remains observational unless an operator explicitly
    -- requests apply=true. Production startup uses the configured apply
    -- policy so READY is never published with unreconciled resources.
    local runOptions = copy(options)
    runOptions.apply = self._apply
    runOptions.dryRun = not self._apply
    local result = self._recovery:runOnce(suppliedNow, runOptions)
    if type(result) ~= 'table' then return Result.err(Codes.RECOVERY_OPERATION_FAILED, 'startup recovery returned an invalid result') end
    if result.ok ~= true then
        if self._required then return result end
        self._ran = true
        self._lastRun = { failed = 1, scanned = 0, pages = 0, pending = 0, recovered = 0, preserved = 0 }
        return Result.ok(copy(self._lastRun), { deferred = true, cause = result.error and result.error.code })
    end
    self._lastRun = copy(result.value or {})
    if (self._required or self._production) and
        (tonumber(self._lastRun.failed or 0) > 0 or tonumber(self._lastRun.pending or 0) > 0) then
        self._ran = false
        return Result.err(Codes.RECOVERY_REQUIRED, 'startup recovery reported unresolved failures', { summary = copy(self._lastRun) })
    end
    self._ran = true
    return Result.ok(copy(self._lastRun), result.metadata)
end

function Job:start(options)
    options = options or {}
    return self:runOnce(nil, options)
end

function Job:stop()
    return Result.ok({ running = false }, { idempotent = true })
end

function Job:status()
    return Result.ok({ enabled = self._enabled, required = self._required, production = self._production,
        apply = self._apply, ran = self._ran, lastRun = copy(self._lastRun) })
end

NightShift.StartupRecoveryJob = Job
NightShift.Jobs.StartupRecovery = Job
