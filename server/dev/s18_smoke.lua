NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s18SmokeCommandsLoaded == true then return end

local function stageResult(name)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    return type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
end

local function stageValue(name, key)
    local stage = stageResult(name)
    if type(stage) ~= 'table' then return nil end
    return stage[key] or stage.value and stage.value[key] or stage
end

local function environment()
    local config = stageValue('config', 'config') or NightShift.DefaultConfig
    return type(config) == 'table' and tostring(config.environment or ''):lower() or nil
end

local function booleanConvar(name)
    if type(getConvar) ~= 'function' then return nil end
    local ok, value = pcall(getConvar, name, '')
    if not ok then return nil end
    value = tostring(value):lower()
    if value == 'true' or value == '1' then return true end
    if value == 'false' or value == '0' then return false end
    return nil
end

local enabled = environment() == 'development'
local configured = booleanConvar('nightshift_s18_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s17_smoke_commands') == true then enabled = true end
if not enabled then return end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S18 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local errorResult = errorValue(result)
        print(('[gnsh-nightshift] S18 %s failed: code=%s message=%s'):format(label, tostring(errorResult.code or 'UNKNOWN'), tostring(errorResult.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'schedule' then
        print(('[gnsh-nightshift] S18 schedule ok: booking=%s status=%s scheduledAt=%s version=%s'):format(
            tostring(value.id or 'n/a'), tostring(value.status or 'n/a'), tostring(value.scheduledAt or 'n/a'), tostring(value.version or 'n/a')))
        return
    end
    if label == 'jobs' then
        local started = value.started or {}
        print(('[gnsh-nightshift] S18 jobs ok: scheduler=%s noShow=%s'):format(tostring(started.scheduledBooking or false), tostring(started.noShow or false)))
        return
    end
    print(('[gnsh-nightshift] S18 %s ok: scanned=%s activated=%s expired=%s idempotent=%s conflicts=%s failed=%s hooks=%s'):format(
        label, tostring(value.scanned or 0), tostring(value.activated or 0), tostring(value.expired or 0),
        tostring(value.idempotent or 0), tostring(value.conflicts or 0), tostring(value.failed or 0), tostring(value.hookFailures or 0)))
end

local function currentServices()
    return stageValue('services', 'services') or {}
end

local function currentJobs()
    return stageValue('jobs', 'jobs') or {}
end

local function requireOperator(source, label)
    -- These are development smoke commands. A SYSTEM actor keeps them useful
    -- from the FXServer console without requiring another server.cfg entry.
    local value = tonumber(source)
    if value == nil or value < 0 then
        if type(print) == 'function' then print(('[gnsh-nightshift] S18 %s must be run from the FXServer console'):format(label)) end
        return nil
    end
    return { type = 'SYSTEM', ref = 'nightshift:s18-smoke' }
end

registerCommand('nightshift_s18_schedule', function(source, args)
    local actor = requireOperator(source, 'schedule')
    if not actor then return end
    local current = currentServices()
    local id, scheduledAt = args and args[1], args and tonumber(args[2])
    local expected = args and args[3] and tonumber(args[3]) or nil
    local booking = current.booking
    report('schedule', booking and id and scheduledAt and booking:schedule(actor, id, scheduledAt, expected) or NightShift.Result.err(NightShift.Errors.Codes.SCHEDULING_INVALID, 'booking ID and future unix timestamp are required'))
end, false)

registerCommand('nightshift_s18_scheduler_run', function(source, args)
    local actor = requireOperator(source, 'scheduler run')
    if not actor then return end
    local jobs = currentJobs()
    local scheduler = jobs.scheduledBooking
    report('scheduler-run', scheduler and scheduler:runOnce(args and args[1] and tonumber(args[1]) or nil) or NightShift.Result.err(NightShift.Errors.Codes.SCHEDULING_NOT_READY, 'scheduled booking job is unavailable'))
end, false)

registerCommand('nightshift_s18_no_show_run', function(source, args)
    local actor = requireOperator(source, 'no-show run')
    if not actor then return end
    local jobs = currentJobs()
    local noShow = jobs.noShow
    report('no-show-run', noShow and noShow:runOnce(args and args[1] and tonumber(args[1]) or nil) or NightShift.Result.err(NightShift.Errors.Codes.SCHEDULING_NOT_READY, 'no-show job is unavailable'))
end, false)

registerCommand('nightshift_s18_jobs', function(source)
    local actor = requireOperator(source, 'jobs')
    if not actor then return end
    local jobs = currentJobs()
    report('jobs', NightShift.Result.ok({
        started = {
            scheduledBooking = jobs.scheduledBooking and jobs.scheduledBooking:isRunning() or false,
            noShow = jobs.noShow and jobs.noShow:isRunning() or false
        }
    }))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S18 smoke commands enabled: /nightshift_s18_schedule [bookingId] [unixTimestamp] [expectedVersion], /nightshift_s18_scheduler_run [unixNow], /nightshift_s18_no_show_run [unixNow], /nightshift_s18_jobs')
end
if type(server) == 'table' then server._s18SmokeCommandsLoaded = true end
