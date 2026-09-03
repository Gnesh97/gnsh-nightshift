NightShift = NightShift or {}

-- S13 development smoke commands reuse the existing S10/S11 development
-- opt-in. They only call server-authoritative Client Mode methods.
local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end
local server = NightShift.Server
if type(server) == 'table' and server._s13SmokeCommandsLoaded == true then return end

local function stageResult(name)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local results = type(instance) == 'table' and instance.results or nil
    return type(results) == 'table' and results[name] or nil
end

local function services()
    local stage = stageResult('services')
    if type(stage) ~= 'table' then return nil end
    return stage.services or stage.value and stage.value.services or stage
end

local function environment()
    local stage = stageResult('config')
    local config = type(stage) == 'table' and (stage.config or stage.value and stage.value.config) or NightShift.DefaultConfig
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
local configured = booleanConvar('nightshift_s13_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s10_smoke_commands') == true or booleanConvar('nightshift_s11_smoke_commands') == true then enabled = true end
if not enabled then return end

local function sourceValue(value)
    value = tonumber(value)
    return value and value >= 1 and value <= 65535 and value == math.floor(value) and value or nil
end

local function player(source, label)
    local value = sourceValue(source)
    if value then return value end
    if type(print) == 'function' then print(('[gnsh-nightshift] S13 %s must be run in-game by a player'):format(label)) end
    return nil
end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then print(('[gnsh-nightshift] S13 %s failed: invalid service result'):format(label)); return end
    if result.ok ~= true then
        local errorResult = errorValue(result)
        print(('[gnsh-nightshift] S13 %s failed: code=%s message=%s'):format(label, tostring(errorResult.code or 'UNKNOWN'), tostring(errorResult.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    local booking = value.booking or {}
    local travel = value.travel or {}
    local spawn = value.spawn or {}
    print(('[gnsh-nightshift] S13 %s ok: booking=%s bookingStatus=%s travel=%s travelState=%s token=%s generation=%s'):format(
        label, tostring(booking.id or value.bookingId or 'n/a'), tostring(booking.status or 'n/a'),
        tostring(travel.travelKey or value.travelKey or 'n/a'), tostring(travel.state or 'n/a'),
        tostring(value.token or (value.session and value.session.token) or 'n/a'),
        tostring(value.generationToken or spawn.generationToken or 'n/a')
    ))
end

local function currentClientMode()
    local current = services()
    return current and current.clientMode or nil
end

registerCommand('nightshift_s13_confirm', function(source, args)
    source = player(source, 'confirm')
    if not source then return end
    local mode = currentClientMode()
    report('confirm', mode and args and args[1] and mode:confirm(source, { quoteId = args[1] }) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or quote ID is unavailable'))
end, false)

registerCommand('nightshift_s13_travel', function(source, args)
    source = player(source, 'travel')
    if not source then return end
    local mode = currentClientMode()
    report('travel', mode and args and args[1] and mode:startTravel(source, args[1]) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or booking ID is unavailable'))
end, false)

registerCommand('nightshift_s13_progress', function(source, args)
    source = player(source, 'progress')
    if not source then return end
    local mode = currentClientMode()
    report('progress', mode and args and args[1] and mode:updateTravelProgress(source, args[1]) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or booking ID is unavailable'))
end, false)

registerCommand('nightshift_s13_spawn', function(source, args)
    source = player(source, 'spawn')
    if not source then return end
    local mode = currentClientMode()
    report('spawn', mode and args and args[1] and mode:requestSpawn(source, args[1]) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or booking ID is unavailable'))
end, false)

registerCommand('nightshift_s13_spawn_confirm', function(source, args)
    source = player(source, 'spawn confirmation')
    if not source then return end
    local mode = currentClientMode()
    local context = mode and args and args[1] and mode:get(args[1]) or nil
    local contextValue = type(context) == 'table' and context.ok and context.value or nil
    local payload = contextValue and {
        bookingId = args[1], travelKey = contextValue.travelKey, profileKey = contextValue.profileKey,
        generationToken = contextValue.generationToken, entity = tonumber(args[2]), networkId = tonumber(args[3])
    } or nil
    report('spawn-confirm', mode and payload and mode:confirmSpawn(source, payload) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'spawn context is unavailable'))
end, false)

registerCommand('nightshift_s13_arrive', function(source, args)
    source = player(source, 'arrival')
    if not source then return end
    local mode = currentClientMode()
    local context = mode and args and args[1] and mode:get(args[1]) or nil
    local contextValue = type(context) == 'table' and context.ok and context.value or nil
    local position
    if args and args[2] and args[3] and args[4] then position = { x = tonumber(args[2]), y = tonumber(args[3]), z = tonumber(args[4]) } end
    local payload = contextValue and {
        bookingId = args[1], travelKey = contextValue.travelKey, profileKey = contextValue.profileKey,
        generationToken = contextValue.generationToken, entity = tonumber(args and args[5]), networkId = tonumber(args and args[6]), position = position
    } or nil
    report('arrival', mode and payload and mode:confirmArrival(source, payload) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'arrival context is unavailable'))
end, false)

registerCommand('nightshift_s13_session_start', function(source, args)
    source = player(source, 'session start')
    if not source then return end
    local mode = currentClientMode()
    report('session-start', mode and args and args[1] and mode:startSession(source, args[1], {}) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or booking ID is unavailable'))
end, false)

registerCommand('nightshift_s13_session_complete', function(source, args)
    source = player(source, 'session complete')
    if not source then return end
    local mode = currentClientMode()
    report('session-complete', mode and args and args[1] and mode:completeSession(source, args[1], { token = args[1], bookingId = args[2] }) or NightShift.Result.err('CLIENT_MODE_NOT_READY', 'client mode service or session token is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S13 smoke commands enabled: /nightshift_s13_confirm [quoteId], /nightshift_s13_travel [bookingId], /nightshift_s13_progress [bookingId], /nightshift_s13_spawn [bookingId], /nightshift_s13_spawn_confirm [bookingId] [entity] [networkId], /nightshift_s13_arrive [bookingId] [x] [y] [z] [entity] [networkId], /nightshift_s13_session_start [bookingId], /nightshift_s13_session_complete [token] [bookingId]')
end
if type(server) == 'table' then server._s13SmokeCommandsLoaded = true end
