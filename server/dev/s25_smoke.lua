NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s25SmokeCommandsLoaded == true then return end

local function stageValue(name, key)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
    if type(stage) ~= 'table' then return nil end
    return stage[key] or (type(stage.value) == 'table' and stage.value[key]) or stage
end

local function enabled()
    local config = stageValue('config', 'config') or NightShift.DefaultConfig or {}
    local active = type(config) == 'table' and tostring(config.environment or ''):lower() == 'development'
    if type(getConvar) ~= 'function' then return active end
    local ok, value = pcall(getConvar, 'nightshift_s25_smoke_commands', '')
    if not ok then return active end
    value = tostring(value):lower()
    if value == 'true' or value == '1' then return true end
    if value == 'false' or value == '0' then return false end
    return active
end

if not enabled() then return end

local function services()
    return stageValue('services', 'services') or {}
end

local function consoleOnly(source, label)
    if tonumber(source) ~= 0 then
        if type(print) == 'function' then print(('[gnsh-nightshift] S25 %s is console-only'):format(label)) end
        return false
    end
    return true
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' or result.ok ~= true then
        local source = type(result) == 'table' and (result.error or result) or {}
        print(('[gnsh-nightshift] S25 %s failed: code=%s message=%s'):format(
            label, tostring(source.code or 'INVALID_RESULT'), tostring(source.message or 'invalid service result')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'idempotency' then
        print(('[gnsh-nightshift] S25 idempotency ok: scope=%s key=%s status=%s replayed=%s'):format(
            tostring(value.scope or 'smoke'), tostring(value.key or 'n/a'),
            tostring(value.status or 'n/a'), tostring(value.replayed == true)))
    elseif label == 'events' then
        print(('[gnsh-nightshift] S25 events ok: aliases=%s attached=%s'):format(
            tostring(value.aliases or 0), tostring(value.attached == true)))
    else
        local serverValue = value.server or {}
        local database = value.database or {}
        print(('[gnsh-nightshift] S25 health ok: readiness=%s database=%s active=%s'):format(
            tostring(serverValue.readiness or 'UNKNOWN'), tostring(database.status or 'UNCONFIGURED'),
            tostring(value.activeBookings and value.activeBookings.count or 0)))
    end
end

registerCommand('nightshift_s25_idempotency', function(source, args)
    if not consoleOnly(source, 'idempotency') then return end
    local store = services().idempotency
    if type(store) ~= 'table' or type(store.claim) ~= 'function' then
        report('idempotency', NightShift.Result.err(NightShift.Errors.Codes.IDEMPOTENCY_UNAVAILABLE, 'idempotency service is unavailable'))
        return
    end
    local key = tostring(args and args[1] or ('smoke-' .. os.time()))
    local payload = { command = 's25', value = tostring(args and args[2] or 'ok') }
    local claimed = store:claim('smoke', key, payload)
    if type(claimed) == 'table' and claimed.ok == true and claimed.value and claimed.value.replayed ~= true
        and type(store.complete) == 'function' then
        claimed = store:complete('smoke', key, payload, { accepted = true })
    end
    report('idempotency', claimed)
end, false)

registerCommand('nightshift_s25_events', function(source)
    if not consoleOnly(source, 'events') then return end
    local surface = services().domainEvents
    if type(surface) ~= 'table' or type(surface.list) ~= 'function' then
        report('events', NightShift.Result.err(NightShift.Errors.Codes.EVENT_UNAVAILABLE, 'domain event surface is unavailable'))
        return
    end
    local aliases = surface:list()
    local count = 0
    for _ in pairs(aliases) do count = count + 1 end
    report('events', NightShift.Result.ok({ aliases = count, attached = true }))
end, false)

registerCommand('nightshift_s25_health', function(source)
    if not consoleOnly(source, 'health') then return end
    local diagnostics = services().diagnostics
    report('health', diagnostics and type(diagnostics.snapshot) == 'function'
        and diagnostics:snapshot(0, { includeAnalytics = true })
        or NightShift.Result.err(NightShift.Errors.Codes.API_UNAVAILABLE, 'diagnostics service is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S25 smoke commands enabled: /nightshift_s25_idempotency [key] [value], /nightshift_s25_events (console), /nightshift_s25_health (console)')
end
if type(server) == 'table' then server._s25SmokeCommandsLoaded = true end
