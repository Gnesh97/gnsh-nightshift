NightShift = NightShift or {}

-- S14 is enabled automatically in development. A convar can still disable it
-- for a production host, but no server.cfg entry is required for the dev path.
local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end
local server = NightShift.Server
if type(server) == 'table' and server._s14SmokeCommandsLoaded == true then return end

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
local configured = booleanConvar('nightshift_s14_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s13_smoke_commands') == true then enabled = true end
if not enabled then return end

local function sourceValue(value)
    value = tonumber(value)
    return value and value >= 1 and value <= 65535 and value == math.floor(value) and value or nil
end

local function player(source, label)
    local value = sourceValue(source)
    if value then return value end
    if type(print) == 'function' then print(('[gnsh-nightshift] S14 %s must be run in-game by a player'):format(label)) end
    return nil
end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then print(('[gnsh-nightshift] S14 %s failed: invalid service result'):format(label)); return end
    if result.ok ~= true then
        local errorResult = errorValue(result)
        print(('[gnsh-nightshift] S14 %s failed: code=%s message=%s'):format(label, tostring(errorResult.code or 'UNKNOWN'), tostring(errorResult.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    local booking = value.booking or {}
    local travel = value.travel or value.destinationTravel or {}
    local pickup = value.pickup or {}
    local vehicle = value.vehicle or {}
    print(('[gnsh-nightshift] S14 %s ok: booking=%s bookingStatus=%s phase=%s travel=%s pickup=%s vehicle=%s seat=%s token=%s'):format(
        label, tostring(booking.id or value.bookingId or 'n/a'), tostring(booking.status or 'n/a'),
        tostring(value.phase or 'n/a'), tostring(travel.travelKey or 'n/a'),
        tostring(pickup.locationRef or value.pickupLocationRef or 'n/a'), tostring(vehicle.vehicleId or 'n/a'),
        tostring(vehicle.seat or 'n/a'), tostring(value.token or (value.session and value.session.token) or 'n/a')
    ))
end

local function modeOrError()
    local current = services()
    local mode = current and current.clientMode or nil
    if type(mode) ~= 'table' then return nil, NightShift.Result.err(NightShift.Errors.Codes.CLIENT_MODE_NOT_READY, 'client mode service is unavailable') end
    return mode
end

local function bookingArg(args, label)
    if type(args) == 'table' and args[1] then return args[1] end
    return nil, NightShift.Result.err(NightShift.Errors.Codes.PICKUP_INVALID, ('S14 %s requires a booking ID'):format(label))
end

registerCommand('nightshift_s14_confirm', function(source, args)
    source = player(source, 'confirm')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('confirm', mode and args and args[1] and mode:confirm(source, { quoteId = args[1] }) or unavailable)
end, false)

registerCommand('nightshift_s14_travel', function(source, args)
    source = player(source, 'travel')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('travel', mode and args and args[1] and mode:startTravel(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s14_spawn', function(source, args)
    source = player(source, 'spawn')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('spawn', mode and args and args[1] and mode:requestSpawn(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s14_spawn_confirm', function(source, args)
    source = player(source, 'spawn confirmation')
    if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    local context = mode and id and mode:get(id) or nil
    local value = type(context) == 'table' and context.ok and context.value or nil
    local payload = value and {
        bookingId = id, travelKey = value.travelKey or value.pickupTravelKey, profileKey = value.profileKey,
        generationToken = value.generationToken, entity = tonumber(args[2]), networkId = tonumber(args[3])
    } or nil
    report('spawn-confirm', mode and payload and mode:confirmSpawn(source, payload) or unavailable or NightShift.Result.err(NightShift.Errors.Codes.PICKUP_NOT_READY, 'spawn context is unavailable'))
end, false)

registerCommand('nightshift_s14_pickup_arrive', function(source, args)
    source = player(source, 'pickup arrival')
    if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    local payload = id and { bookingId = id, entity = tonumber(args[2]), networkId = tonumber(args[3]) } or nil
    report('pickup-arrival', mode and payload and mode:confirmArrival(source, payload) or unavailable or NightShift.Result.err(NightShift.Errors.Codes.PICKUP_INVALID, 'pickup arrival requires a booking ID'))
end, false)

registerCommand('nightshift_s14_vehicle', function(source, args)
    source = player(source, 'vehicle binding')
    if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    local payload = id and {
        bookingId = id, vehicleId = args[2], seat = tonumber(args[3]), networkId = tonumber(args[4]), entity = tonumber(args[5])
    } or nil
    report('vehicle-bind', mode and payload and mode:bindVehicle(source, payload) or unavailable or NightShift.Result.err(NightShift.Errors.Codes.PICKUP_INVALID, 'vehicle binding requires a booking ID and vehicle ID'))
end, false)

registerCommand('nightshift_s14_enter', function(source, args)
    source = player(source, 'vehicle entry')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('vehicle-entry', mode and args and args[1] and mode:enterVehicle(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s14_destination_travel', function(source, args)
    source = player(source, 'destination travel')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('destination-travel', mode and args and args[1] and mode:startDestinationTravel(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s14_destination_arrive', function(source, args)
    source = player(source, 'destination arrival')
    if not source then return end
    local mode, unavailable = modeOrError()
    local id = args and args[1]
    local payload = id and { bookingId = id, entity = tonumber(args[2]), networkId = tonumber(args[3]) } or nil
    report('destination-arrival', mode and payload and mode:confirmDestinationArrival(source, payload) or unavailable or NightShift.Result.err(NightShift.Errors.Codes.PICKUP_INVALID, 'destination arrival requires a booking ID'))
end, false)

registerCommand('nightshift_s14_session_start', function(source, args)
    source = player(source, 'session start')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('session-start', mode and args and args[1] and mode:startSession(source, args[1], {}) or unavailable)
end, false)

registerCommand('nightshift_s14_session_complete', function(source, args)
    source = player(source, 'session complete')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('session-complete', mode and args and args[1] and mode:completeSession(source, args[1], { token = args[1], bookingId = args[2] }) or unavailable)
end, false)

registerCommand('nightshift_s14_state', function(source, args)
    source = player(source, 'state')
    if not source then return end
    local mode, unavailable = modeOrError()
    report('state', mode and args and args[1] and mode:get(args[1]) or unavailable)
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S14 smoke commands enabled: /nightshift_s14_confirm [quoteId], /nightshift_s14_travel [bookingId], /nightshift_s14_spawn [bookingId], /nightshift_s14_spawn_confirm [bookingId] [entity] [networkId], /nightshift_s14_pickup_arrive [bookingId] [entity] [networkId], /nightshift_s14_vehicle [bookingId] [vehicleId] [seat] [networkId] [entity], /nightshift_s14_enter [bookingId], /nightshift_s14_destination_travel [bookingId], /nightshift_s14_destination_arrive [bookingId] [entity] [networkId], /nightshift_s14_session_start [bookingId], /nightshift_s14_session_complete [token] [bookingId], /nightshift_s14_state [bookingId]')
end
if type(server) == 'table' then server._s14SmokeCommandsLoaded = true end
