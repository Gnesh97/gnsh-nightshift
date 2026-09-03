NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s24SmokeCommandsLoaded == true then return end

local function stageValue(name, key)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
    if type(stage) ~= 'table' then return nil end
    return stage[key] or (type(stage.value) == 'table' and stage.value[key]) or stage
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

local function enabled()
    local config = stageValue('config', 'config') or NightShift.DefaultConfig or {}
    local active = type(config) == 'table' and tostring(config.environment or ''):lower() == 'development'
    local configured = booleanConvar('nightshift_s24_smoke_commands')
    return configured == nil and active or configured == true
end

if not enabled() then return end

local function services()
    return stageValue('services', 'services') or {}
end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result)
        or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S24 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local err = errorValue(result)
        print(('[gnsh-nightshift] S24 %s failed: code=%s message=%s'):format(
            label, tostring(err.code or 'UNKNOWN'), tostring(err.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'audit' then
        print(('[gnsh-nightshift] S24 audit ok: action=%s status=%s target=%s'):format(
            tostring(value.action or 'n/a'), tostring(value.resultStatus or 'n/a'),
            tostring(value.targetRef or value.target and value.target.ref or 'n/a')))
        return
    end
    if label == 'audit-list' then
        print(('[gnsh-nightshift] S24 audit-list ok: count=%s'):format(tostring(#value)))
        for _, event in ipairs(value) do
            print(('  id=%s action=%s status=%s target=%s'):format(
                tostring(event.id or 'n/a'), tostring(event.action or 'n/a'),
                tostring(event.resultStatus or 'n/a'), tostring(event.targetRef or 'n/a')))
        end
        return
    end
    if label == 'analytics' then
        print(('[gnsh-nightshift] S24 analytics ok: totalBookings=%s conversion=%s settlementFailures=%s travelFailures=%s'):format(
            tostring(value.totalBookings or 0), tostring(value.conversion or 'n/a'),
            tostring(value.settlementFailures or 0), tostring(value.travelFailures or 0)))
        for district, count in pairs(type(value.demandByDistrict) == 'table' and value.demandByDistrict or {}) do
            print(('  demand district=%s count=%s'):format(tostring(district), tostring(count)))
        end
        return
    end
    local active = value.activeBookings or {}
    local failed = value.failedSettlements or {}
    local travel = active.stuckTravelPlans or {}
    local database = value.database or {}
    print(('[gnsh-nightshift] S24 diagnostics ok: readiness=%s database=%s active=%s failedSettlements=%s stuckTravel=%s expiredReservations=%s audit=%s'):format(
        tostring(value.server and value.server.readiness or 'UNKNOWN'),
        tostring(database.status or 'UNCONFIGURED'), tostring(active.count or 0),
        tostring(failed.count or 0), tostring(travel.count or 0),
        tostring(value.expiredReservations and value.expiredReservations.count or 0),
        tostring(value.auditAvailable == true)))
end

local function sourceValue(source, label, consoleOnly)
    source = tonumber(source)
    if source == nil or source < 0 or source ~= math.floor(source) then
        if type(print) == 'function' then
            print(('[gnsh-nightshift] S24 %s must be run from the FXServer console or an in-game player'):format(label))
        end
        return nil
    end
    if consoleOnly and source ~= 0 then
        if type(print) == 'function' then print(('[gnsh-nightshift] S24 %s is console-only'):format(label)) end
        return nil
    end
    return source
end

registerCommand('nightshift_s24_audit', function(source, args)
    source = sourceValue(source, 'audit', false)
    if source == nil then return end
    local current = services()
    local audit = current.audit
    if type(audit) ~= 'table' or type(audit.record) ~= 'function' then
        report('audit', NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_DB_UNAVAILABLE, 'audit service is unavailable'))
        return
    end
    local status = tostring(args and args[1] or 'OK'):upper()
    if status ~= 'OK' and status ~= 'ERROR' and status ~= 'UNKNOWN' then status = 'OK' end
    local eventResult = status == 'OK'
        and NightShift.Result.ok({ smoke = true })
        or NightShift.Result.err('S24_SMOKE_RESULT', 'development smoke result')
    report('audit', audit:record({
        actor = source > 0 and { source = source, actorType = 'PLAYER' } or nil,
        action = tostring(args and args[2] or 's24.smoke'),
        target = { type = 'SMOKE', ref = tostring(args and args[3] or 'development') },
        result = eventResult, resultStatus = status,
        reason = 'development smoke command', metadata = { smoke = true }
    }))
end, false)

registerCommand('nightshift_s24_audit_list', function(source, args)
    source = sourceValue(source, 'audit-list', true)
    if source == nil then return end
    local audit = services().audit
    local limit = tonumber(args and args[1]) or 20
    report('audit-list', audit and type(audit.list) == 'function'
        and audit:list({ limit = limit, offset = 0 })
        or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_DB_UNAVAILABLE, 'audit service is unavailable'))
end, false)

registerCommand('nightshift_s24_analytics', function(source)
    source = sourceValue(source, 'analytics', true)
    if source == nil then return end
    local analytics = services().analytics
    report('analytics', analytics and type(analytics.summary) == 'function'
        and analytics:summary({})
        or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_DB_UNAVAILABLE, 'analytics service is unavailable'))
end, false)

registerCommand('nightshift_s24_diagnostics', function(source)
    source = sourceValue(source, 'diagnostics', false)
    if source == nil then return end
    local diagnostics = services().diagnostics
    report('diagnostics', diagnostics and type(diagnostics.snapshot) == 'function'
        and diagnostics:snapshot(source, { includeAnalytics = true })
        or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_DB_UNAVAILABLE, 'diagnostics service is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S24 smoke commands enabled: /nightshift_s24_audit [OK|ERROR|UNKNOWN] [action] [target], /nightshift_s24_audit_list [limit] (console), /nightshift_s24_analytics (console), /nightshift_s24_diagnostics')
end
if type(server) == 'table' then server._s24SmokeCommandsLoaded = true end
