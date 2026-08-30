NightShift = NightShift or {}

-- Development-only runtime smoke commands. They register automatically for
-- the development environment; other environments must explicitly opt in with
-- nightshift_s10_smoke_commands=true.
-- FiveM natives are exposed through the script global lookup, not reliably as
-- raw entries in _G. Keep the raw fallback for isolated test/embedded hosts.
local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then
    if type(print) == 'function' then
        print('[gnsh-nightshift] S10 smoke commands unavailable: RegisterCommand native is not exposed')
    end
    return
end
local server = NightShift.Server
if type(server) == 'table' and server._s10SmokeCommandsLoaded == true then return end

local function stageResult(name)
    local server = NightShift.Server
    local instance = type(server) == 'table' and server.instance or nil
    local results = type(instance) == 'table' and instance.results or nil
    return type(results) == 'table' and results[name] or nil
end

local function runtimeEnvironment()
    local stage = stageResult('config')
    local config = type(stage) == 'table' and (stage.config or stage.value and stage.value.config) or nil
    if type(config) ~= 'table' then config = NightShift.DefaultConfig end
    return type(config) == 'table' and type(config.environment) == 'string' and config.environment:lower() or nil
end

local enabled = runtimeEnvironment() == 'development'
if type(getConvar) == 'function' then
    local ok, value = pcall(getConvar, 'nightshift_s10_smoke_commands', '')
    if ok then
        value = tostring(value):lower()
        if value == 'true' or value == '1' then
            enabled = true
        elseif value == 'false' or value == '0' then
            enabled = false
        end
    end
end
if not enabled then return end

local function services()
    local stage = stageResult('services')
    if type(stage) ~= 'table' then return nil end
    return stage.services or stage.value and stage.value.services or stage
end

local function sourceId(source)
    source = tonumber(source)
    if not source or source < 1 or source ~= math.floor(source) or source > 65535 then return nil end
    return source
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S10 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local errorValue = result.error
        if type(errorValue) ~= 'table' then errorValue = result end
        print(('[gnsh-nightshift] S10 %s failed: code=%s message=%s'):format(label, tostring(errorValue.code or result.code or 'UNKNOWN'), tostring(errorValue.message or result.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    print(('[gnsh-nightshift] S10 %s ok: state=%s source=%s district=%s zone=%s opportunity=%s score=%s band=%s'):format(
        label,
        tostring(value.state or 'n/a'),
        tostring(value.source or 'n/a'),
        tostring(value.district or 'n/a'),
        tostring(value.zone or 'n/a'),
        tostring(value.opportunityKey or 'n/a'),
        tostring(value.demandScore or 'n/a'),
        tostring(value.demandBand or 'n/a')
    ))
end

local function requirePlayer(source, label)
    local id = sourceId(source)
    if id then return id end
    if type(print) == 'function' then print(('[gnsh-nightshift] S10 %s must be run in-game by a player'):format(label)) end
    return nil
end

registerCommand('nightshift_s10_available', function(source, args)
    source = requirePlayer(source, 'availability')
    if not source then return end
    local current = services()
    if not current or type(current.workerAvailability) ~= 'table' then
        if type(print) == 'function' then print('[gnsh-nightshift] S10 availability service is unavailable') end
        return
    end
    local district = type(args) == 'table' and args[1] or nil
    report('availability', current.workerAvailability:setAvailable(source, district and { district = district } or nil))
end, false)

registerCommand('nightshift_s10_customer', function(source, args)
    source = requirePlayer(source, 'customer generation')
    if not source then return end
    local current = services()
    if not current or type(current.npcCustomer) ~= 'table' then
        if type(print) == 'function' then print('[gnsh-nightshift] S10 customer service is unavailable') end
        return
    end
    local request = {}
    if type(args) == 'table' and args[1] then request.district = args[1] end
    if type(args) == 'table' and args[2] then request.zone = args[2] end
    report('customer', current.npcCustomer:generate(source, request))
end, false)

registerCommand('nightshift_s10_offline', function(source)
    source = requirePlayer(source, 'availability reset')
    if not source then return end
    local current = services()
    if not current or type(current.workerAvailability) ~= 'table' then
        if type(print) == 'function' then print('[gnsh-nightshift] S10 availability service is unavailable') end
        return
    end
    report('offline', current.workerAvailability:reset(source, 'smoke_command'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S10 smoke commands enabled: /nightshift_s10_available [district], /nightshift_s10_customer [district] [zone], /nightshift_s10_offline')
end
if type(server) == 'table' then server._s10SmokeCommandsLoaded = true end
