NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s27SmokeCommandsLoaded == true then return end

local function stageServices()
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results.services or nil
    return type(stage) == 'table' and (stage.services or stage.value and stage.value.services or stage) or {}
end

local function stageConfig()
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results.config or nil
    return type(stage) == 'table' and (stage.config or stage.value and stage.value.config or stage) or nil
end

local function enabled()
    local config = stageConfig() or NightShift.DefaultConfig or {}
    local active = tostring(config.environment or ''):lower() == 'development'
    if type(getConvar) ~= 'function' then return active end
    local ok, value = pcall(getConvar, 'nightshift_s27_smoke_commands', '')
    if not ok then return active end
    value = tostring(value):lower()
    if value == 'true' or value == '1' then return true end
    if value == 'false' or value == '0' then return false end
    return active
end

if not enabled() then return end

local function consoleOnly(source, label)
    if tonumber(source) ~= 0 then
        if type(print) == 'function' then print(('[gnsh-nightshift] S27 %s is console-only'):format(label)) end
        return false
    end
    return true
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' or result.ok ~= true then
        local value = type(result) == 'table' and (result.error or result) or {}
        print(('[gnsh-nightshift] S27 %s failed: code=%s message=%s'):format(
            label, tostring(value.code or 'INVALID_RESULT'), tostring(value.message or 'invalid service result')))
        return
    end
    local value = result.value or {}
    if label == 'rate-limit' then
        print(('[gnsh-nightshift] S27 rate-limit ok: source=%s action=%s allowed=%s remaining=%s retryAfter=%s'):format(
            tostring(value.source or 'n/a'), tostring(value.action or 'n/a'), tostring(value.allowed == true),
            tostring(value.remaining or 0), tostring(value.retryAfter or 0)))
    elseif label == 'tokens' then
        print(('[gnsh-nightshift] S27 action-token status: enabled=%s enforce=%s active=%s consumed=%s'):format(
            tostring(value.enabled == true), tostring(value.enforce == true), tostring(value.active or 0), tostring(value.consumed or 0)))
    else
        print(('[gnsh-nightshift] S27 rate-limit status: enabled=%s buckets=%s/%s'):format(
            tostring(value.enabled == true), tostring(value.buckets or 0), tostring(value.maxBuckets or 0)))
    end
end

registerCommand('nightshift_s27_security_status', function(source)
    if not consoleOnly(source, 'security-status') then return end
    local services = stageServices()
    local limiter = services.rateLimiter
    local tokens = services.actionTokens
    if type(limiter) ~= 'table' or type(limiter.status) ~= 'function' then
        report('status', NightShift.Result.err(NightShift.Errors.Codes.RATE_LIMIT_UNAVAILABLE, 'rate limiter is unavailable'))
        return
    end
    report('status', limiter:status())
    if type(tokens) == 'table' and type(tokens.status) == 'function' then report('tokens', tokens:status()) end
end, false)

registerCommand('nightshift_s27_rate_limit', function(source, args)
    if not consoleOnly(source, 'rate-limit') then return end
    local services = stageServices()
    local limiter = services.rateLimiter
    if type(limiter) ~= 'table' or type(limiter.allow) ~= 'function' then
        report('rate-limit', NightShift.Result.err(NightShift.Errors.Codes.RATE_LIMIT_UNAVAILABLE, 'rate limiter is unavailable'))
        return
    end
    local playerSource = tonumber(type(args) == 'table' and args[1] or nil) or 0
    local action = type(args) == 'table' and args[2] or 'marketplace:list'
    report('rate-limit', limiter:allow(playerSource, action))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S27 smoke commands enabled: /nightshift_s27_security_status, /nightshift_s27_rate_limit [source] [action]')
end
if type(server) == 'table' then server._s27SmokeCommandsLoaded = true end
