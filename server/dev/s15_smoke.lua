NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end
local server = NightShift.Server
if type(server) == 'table' and server._s15SmokeCommandsLoaded == true then return end

local function stageResult(name)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    return type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
end
local function services()
    local stage = stageResult('services')
    return type(stage) == 'table' and (stage.services or stage.value and stage.value.services or stage) or nil
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
end
local enabled = environment() == 'development'
local configured = booleanConvar('nightshift_s15_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s14_smoke_commands') == true then enabled = true end
if not enabled then return end

local function player(value, label)
    value = tonumber(value)
    if value and value >= 1 and value <= 65535 and value == math.floor(value) then return value end
    if type(print) == 'function' then print(('[gnsh-nightshift] S15 %s must be run in-game by a player'):format(label)) end
end
local function errorValue(result) return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' } end
local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then print(('[gnsh-nightshift] S15 %s failed: invalid service result'):format(label)); return end
    if result.ok ~= true then
        local errorResult = errorValue(result)
        print(('[gnsh-nightshift] S15 %s failed: code=%s message=%s'):format(label, tostring(errorResult.code or 'UNKNOWN'), tostring(errorResult.message or 'unknown error')))
        return
    end
    local value, booking, travel = type(result.value) == 'table' and result.value or {}, {}, {}
    booking, travel = value.booking or {}, value.travel or {}
    print(('[gnsh-nightshift] S15 %s ok: booking=%s bookingStatus=%s phase=%s clientArrived=%s workerArrived=%s waitingFor=%s outcome=%s travel=%s token=%s'):format(
        label, tostring(booking.id or value.bookingId or 'n/a'), tostring(booking.status or 'n/a'), tostring(value.phase or 'n/a'),
        tostring(value.clientArrived or false), tostring(value.workerArrived or false), tostring(value.waitingFor or 'n/a'),
        tostring(value.outcome or 'n/a'), tostring(travel.travelKey or value.travelKey or 'n/a'),
        tostring(value.token or (value.session and value.session.token) or 'n/a')))
end
local function modeOrError()
    local mode = services() and services().clientMode
    if type(mode) ~= 'table' then return nil, NightShift.Result.err(NightShift.Errors.Codes.CLIENT_MODE_NOT_READY, 'client mode service is unavailable') end
    return mode
end
local function contextPayload(mode, id, args)
    local current = mode and mode:get(id)
    local value = type(current) == 'table' and current.ok and current.value or {}
    return { bookingId = id, travelKey = value.travelKey, profileKey = value.profileKey, generationToken = value.generationToken,
        entity = tonumber(args and args[2]), networkId = tonumber(args and args[3]) }
end

registerCommand('nightshift_s15_confirm', function(source, args)
    source = player(source, 'confirm'); if not source then return end
    local mode, unavailable = modeOrError()
    report('confirm', mode and args and args[1] and mode:confirm(source, { quoteId = args[1] }) or unavailable)
end, false)
registerCommand('nightshift_s15_travel', function(source, args)
    source = player(source, 'travel'); if not source then return end
    local mode, unavailable = modeOrError()
    report('travel', mode and args and args[1] and mode:startTravel(source, args[1]) or unavailable)
end, false)
registerCommand('nightshift_s15_spawn', function(source, args)
    source = player(source, 'spawn'); if not source then return end
    local mode, unavailable = modeOrError()
    report('spawn', mode and args and args[1] and mode:requestSpawn(source, args[1]) or unavailable)
end, false)
registerCommand('nightshift_s15_spawn_confirm', function(source, args)
    source = player(source, 'spawn confirmation'); if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    report('spawn-confirm', mode and id and mode:confirmSpawn(source, contextPayload(mode, id, args)) or unavailable)
end, false)
registerCommand('nightshift_s15_npc_arrive', function(source, args)
    source = player(source, 'NPC arrival'); if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    report('npc-arrival', mode and id and mode:confirmNpcArrival(source, contextPayload(mode, id, args)) or unavailable)
end, false)
registerCommand('nightshift_s15_client_arrive', function(source, args)
    source = player(source, 'client arrival'); if not source then return end
    local mode, unavailable = modeOrError()
    report('client-arrival', mode and args and args[1] and mode:confirmClientArrival(source, { bookingId = args[1] }) or unavailable)
end, false)
registerCommand('nightshift_s15_tick', function(source, args)
    source = player(source, 'grace tick'); if not source then return end
    local mode, unavailable = modeOrError()
    report('tick', mode and args and args[1] and mode:tick(source, args[1], args[2] and tonumber(args[2]) or nil) or unavailable)
end, false)
registerCommand('nightshift_s15_session_start', function(source, args)
    source = player(source, 'session start'); if not source then return end
    local mode, unavailable = modeOrError()
    report('session-start', mode and args and args[1] and mode:startSession(source, args[1], {}) or unavailable)
end, false)
registerCommand('nightshift_s15_session_complete', function(source, args)
    source = player(source, 'session complete'); if not source then return end
    local mode, unavailable = modeOrError()
    report('session-complete', mode and args and args[1] and mode:completeSession(source, args[1], { token = args[1], bookingId = args[2] }) or unavailable)
end, false)
registerCommand('nightshift_s15_state', function(source, args)
    source = player(source, 'state'); if not source then return end
    local mode, unavailable = modeOrError()
    report('state', mode and args and args[1] and mode:get(args[1]) or unavailable)
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S15 smoke commands enabled: /nightshift_s15_confirm [quoteId], /nightshift_s15_travel [bookingId], /nightshift_s15_spawn [bookingId], /nightshift_s15_spawn_confirm [bookingId] [entity] [networkId], /nightshift_s15_npc_arrive [bookingId] [entity] [networkId], /nightshift_s15_client_arrive [bookingId], /nightshift_s15_tick [bookingId] [timestamp], /nightshift_s15_session_start [bookingId], /nightshift_s15_session_complete [token] [bookingId], /nightshift_s15_state [bookingId]')
end
if type(server) == 'table' then server._s15SmokeCommandsLoaded = true end
