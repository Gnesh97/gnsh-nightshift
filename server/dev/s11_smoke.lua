NightShift = NightShift or {}

-- S11 commands are development-only by default. Non-development servers must
-- explicitly opt in with the S11 flag or the existing S10 smoke-suite flag.
local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end
local server = NightShift.Server
if type(server) == 'table' and server._s11SmokeCommandsLoaded == true then return end

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

local enabled = environment() == 'development'
local function convarBoolean(name)
    if type(getConvar) ~= 'function' then return nil end
    local ok, value = pcall(getConvar, name, '')
    if not ok then return nil end
    value = tostring(value):lower()
    if value == 'true' or value == '1' then return true end
    if value == 'false' or value == '0' then return false end
    return nil
end

local configured = convarBoolean('nightshift_s11_smoke_commands')
local legacyEnabled = convarBoolean('nightshift_s10_smoke_commands') == true
if legacyEnabled then
    -- S10 and S11 are one development smoke suite. Preserve the existing S10
    -- opt-in so advancing the sprint does not require another server.cfg line.
    enabled = true
elseif configured ~= nil then
    enabled = configured
end
if not enabled then return end

local function sourceValue(source)
    source = tonumber(source)
    return source and source >= 1 and source <= 65535 and source == math.floor(source) and source or nil
end

local function player(source, label)
    local value = sourceValue(source)
    if value then return value end
    if type(print) == 'function' then print(('[gnsh-nightshift] S11 %s must be run in-game by a player'):format(label)) end
    return nil
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then print(('[gnsh-nightshift] S11 %s failed: invalid service result'):format(label)); return end
    if result.ok ~= true then
        local errorValue = result.error or result
        print(('[gnsh-nightshift] S11 %s failed: code=%s message=%s'):format(label, tostring(errorValue.code or 'UNKNOWN'), tostring(errorValue.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    local negotiation = value.negotiation or {}
    local booking = value.booking or {}
    print(('[gnsh-nightshift] S11 %s ok: negotiation=%s status=%s offer=%s round=%s booking=%s bookingStatus=%s token=%s'):format(
        label, tostring(negotiation.id or 'n/a'), tostring(negotiation.status or value.status or 'n/a'),
        tostring(negotiation.currentOfferMinor or 'n/a'), tostring(negotiation.round or 'n/a'),
        tostring(booking.id or 'n/a'), tostring(booking.status or 'n/a'), tostring(value.token or (value.session and value.session.token) or 'n/a')
    ))
end

registerCommand('nightshift_s11_begin', function(source, args)
    source = player(source, 'begin')
    if not source then return end
    local current = services()
    if not current or type(current.npcCustomer) ~= 'table' or type(current.workerMode) ~= 'table' then
        report('begin', NightShift.Result.err('WORKER_MODE_UNAVAILABLE', 'S11 worker mode services are unavailable')); return
    end
    local request = { district = args and args[1] or nil, zone = args and args[2] or nil }
    local generated = current.npcCustomer:generate(source, request)
    if not generated.ok then report('begin', generated); return end
    local opportunity = generated.value
    report('begin', current.workerMode:start(source, opportunity.opportunityKey, {
        servicePackageId = args and args[3] or 'standard', locationType = 'CONFIG_LOCATION',
        locationRef = 'configured_default', meetingMode = 'MEET_THERE'
    }))
end, false)

registerCommand('nightshift_s11_counter', function(source, args)
    source = player(source, 'counter')
    if not source then return end
    local current = services()
    local id, amount = args and args[1], args and tonumber(args[2])
    if not current or type(current.workerMode) ~= 'table' or not id or not amount then report('counter', NightShift.Result.err('WORKER_MODE_INVALID', 'negotiation ID and integer amount are required')); return end
    report('counter', current.workerMode:counter(source, id, amount))
end, false)

registerCommand('nightshift_s11_accept', function(source, args)
    source = player(source, 'accept')
    if not source then return end
    local current = services()
    if not current or type(current.workerMode) ~= 'table' or not args or not args[1] then report('accept', NightShift.Result.err('WORKER_MODE_INVALID', 'negotiation ID is required')); return end
    report('accept', current.workerMode:accept(source, args[1]))
end, false)

registerCommand('nightshift_s11_travel', function(source, args)
    source = player(source, 'travel')
    if not source then return end
    local current = services()
    report('travel', current and current.workerMode and args and args[1] and current.workerMode:startTravel(source, args[1]) or NightShift.Result.err('WORKER_MODE_INVALID', 'booking ID is required'))
end, false)

registerCommand('nightshift_s11_arrive', function(source, args)
    source = player(source, 'arrive')
    if not source then return end
    local current = services()
    report('arrive', current and current.workerMode and args and args[1] and current.workerMode:markArrival(source, args[1]) or NightShift.Result.err('WORKER_MODE_INVALID', 'booking ID is required'))
end, false)

registerCommand('nightshift_s11_session_start', function(source, args)
    source = player(source, 'session start')
    if not source then return end
    local current = services()
    report('session-start', current and current.workerMode and args and args[1] and current.workerMode:startSession(source, args[1], { locationRef = args[2] or 'configured_default' }) or NightShift.Result.err('WORKER_MODE_INVALID', 'booking ID is required'))
end, false)

registerCommand('nightshift_s11_session_complete', function(source, args)
    source = player(source, 'session complete')
    if not source then return end
    local current = services()
    local request = { bookingId = args and args[2] or nil, locationRef = args and args[3] or 'configured_default', payerSource = args and tonumber(args[4]) or nil }
    report('session-complete', current and current.workerMode and args and args[1] and current.workerMode:completeSession(source, args[1], request) or NightShift.Result.err('WORKER_MODE_INVALID', 'session token is required'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S11 smoke commands enabled: /nightshift_s11_begin [district] [zone] [package], /nightshift_s11_counter [negotiationId] [amount], /nightshift_s11_accept [negotiationId], /nightshift_s11_travel [bookingId], /nightshift_s11_arrive [bookingId], /nightshift_s11_session_start [bookingId] [locationRef], /nightshift_s11_session_complete [token] [bookingId] [locationRef] [payerSource]')
end
if type(server) == 'table' then server._s11SmokeCommandsLoaded = true end
