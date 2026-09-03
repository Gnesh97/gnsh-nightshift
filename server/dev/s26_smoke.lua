NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s26SmokeCommandsLoaded == true then return end

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
    local ok, value = pcall(getConvar, 'nightshift_s26_smoke_commands', '')
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
        if type(print) == 'function' then print(('[gnsh-nightshift] S26 %s is console-only'):format(label)) end
        return false
    end
    return true
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' or result.ok ~= true then
        local errorValue = type(result) == 'table' and (result.error or result) or {}
        print(('[gnsh-nightshift] S26 %s failed: code=%s message=%s'):format(
            label, tostring(errorValue.code or 'INVALID_RESULT'), tostring(errorValue.message or 'invalid service result')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'status' then
        local last = value.lastRun or {}
        print(('[gnsh-nightshift] S26 recovery status: enabled=%s apply=%s running=%s scanned=%s pending=%s failed=%s'):format(
            tostring(value.enabled == true), tostring(value.apply == true), tostring(value.running == true),
            tostring(last.scanned or 0), tostring(last.pending or 0), tostring(last.failed or 0)))
    else
        print(('[gnsh-nightshift] S26 recovery observation ok: pages=%s scanned=%s preserved=%s pending=%s failed=%s'):format(
            tostring(value.pages or 0), tostring(value.scanned or 0), tostring(value.preserved or 0),
            tostring(value.pending or 0), tostring(value.failed or 0)))
    end
end

registerCommand('nightshift_s26_recovery', function(source)
    if not consoleOnly(source, 'recovery') then return end
    local recovery = services().recovery
    if type(recovery) ~= 'table' or type(recovery.runOnce) ~= 'function' then
        report('recovery', NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_NOT_READY, 'recovery service is unavailable'))
        return
    end
    report('recovery', recovery:runOnce(nil, { dryRun = true, apply = false }))
end, false)

registerCommand('nightshift_s26_recovery_status', function(source)
    if not consoleOnly(source, 'recovery-status') then return end
    local recovery = services().recovery
    if type(recovery) ~= 'table' or type(recovery.status) ~= 'function' then
        report('status', NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_NOT_READY, 'recovery service is unavailable'))
        return
    end
    report('status', recovery:status())
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S26 smoke commands enabled: /nightshift_s26_recovery (read-only), /nightshift_s26_recovery_status (console)')
end
if type(server) == 'table' then server._s26SmokeCommandsLoaded = true end

