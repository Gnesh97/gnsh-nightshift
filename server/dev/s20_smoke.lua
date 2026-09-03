NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s20SmokeCommandsLoaded == true then return end

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
local configured = booleanConvar('nightshift_s20_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s19_smoke_commands') == true
    or booleanConvar('nightshift_s18_smoke_commands') == true then enabled = true end
if not enabled then return end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result)
        or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S20 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local err = errorValue(result)
        print(('[gnsh-nightshift] S20 %s failed: code=%s message=%s'):format(
            label, tostring(err.code or 'UNKNOWN'), tostring(err.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'heat' or label == 'heat-event' then
        print(('[gnsh-nightshift] S20 %s ok: district=%s player=%s playerHeat=%s pressure=%s event=%s idempotent=%s'):format(
            label, tostring(value.district or 'n/a'), tostring(value.playerKey or 'n/a'),
            tostring(value.playerHeat or 'n/a'), tostring(value.districtPressure or 'n/a'),
            tostring(value.eventKey or 'n/a'), tostring(result.metadata and result.metadata.idempotent or false)))
        return
    end
    if label == 'vice' then
        print(('[gnsh-nightshift] S20 vice ok: district=%s score=%s band=%s triggered=%s archetype=%s reasons=%s dispatched=%s'):format(
            tostring(value.district or 'n/a'), tostring(value.score or 'n/a'),
            tostring(value.band or 'n/a'), tostring(value.triggered or false),
            tostring(value.archetype or 'n/a'),
            tostring(value.reason and value.reason.summary or 'n/a'),
            tostring(value.dispatch and value.dispatch.emitted or false)))
        return
    end
    if label == 'feedback' then
        print(('[gnsh-nightshift] S20 feedback ok: heat=%s streetMultiplier=%s privateModifier=%s pricing=%s'):format(
            tostring(value.heatPressure or 'n/a'), tostring(value.streetOpportunityMultiplier or 'n/a'),
            tostring(value.privateBookingAvailabilityModifier or 'n/a'), tostring(value.pricingModifier or 'n/a')))
        return
    end
    print(('[gnsh-nightshift] S20 heat-decay ok: at=%s changed=%s'):format(
        tostring(value.at or 'n/a'), tostring(value.changed or 0)))
end

local function currentServices()
    return stageValue('services', 'services') or {}
end

local function currentJobs()
    return stageValue('jobs', 'jobs') or {}
end

local function requireConsole(source, label)
    local numeric = tonumber(source)
    if numeric == nil or numeric < 0 then
        if type(print) == 'function' then
            print(('[gnsh-nightshift] S20 %s must be run from the FXServer console'):format(label))
        end
        return false
    end
    return true
end

registerCommand('nightshift_s20_heat', function(source, args)
    if not requireConsole(source, 'heat') then return end
    local service = currentServices().heat
    local district = args and args[1]
    local playerKey = args and args[2]
    report('heat', service and service:get({ district = district, playerKey = playerKey })
        or NightShift.Result.err(NightShift.Errors.Codes.HEAT_OPERATION_FAILED, 'heat service is unavailable'))
end, false)

registerCommand('nightshift_s20_heat_event', function(source, args)
    if not requireConsole(source, 'heat event') then return end
    local service = currentServices().heat
    local district, eventType, playerKey = args and args[1], args and args[2], args and args[3]
    local eventKey = args and args[6] or ('smoke:%s:%s:%s'):format(tostring(source), tostring(district), tostring(os.time()))
    report('heat-event', service and service:record({
        eventKey = eventKey,
        eventType = eventType or 'MANUAL_SMOKE',
        district = district,
        playerKey = playerKey,
        playerAmount = args and args[4] and tonumber(args[4]) or nil,
        districtAmount = args and args[5] and tonumber(args[5]) or nil
    }) or NightShift.Result.err(NightShift.Errors.Codes.HEAT_OPERATION_FAILED, 'heat service is unavailable'))
end, false)

registerCommand('nightshift_s20_heat_decay', function(source, args)
    if not requireConsole(source, 'heat decay') then return end
    local jobs = currentJobs()
    local job = jobs.heatDecay
    report('heat-decay', job and job:runOnce(args and args[1] and tonumber(args[1]) or nil)
        or NightShift.Result.err(NightShift.Errors.Codes.HEAT_OPERATION_FAILED, 'heat decay job is unavailable'))
end, false)

registerCommand('nightshift_s20_heat_jobs', function(source)
    if not requireConsole(source, 'heat jobs') then return end
    local job = currentJobs().heatDecay
    report('heat-decay', NightShift.Result.ok({
        at = os.time(),
        changed = 0,
        running = job and job:isRunning() or false
    }))
end, false)

registerCommand('nightshift_s20_vice', function(source, args)
    if not requireConsole(source, 'vice') then return end
    local service = currentServices().vice
    local district, pressure, archetype, meetingMode = args and args[1], args and tonumber(args[2]), args and args[3], args and args[4]
    report('vice', service and service:evaluate({
        district = district,
        districtPressure = pressure,
        npc = { riskArchetype = archetype },
        booking = { id = args and args[5], meetingMode = meetingMode }
    }) or NightShift.Result.err(NightShift.Errors.Codes.VICE_UNAVAILABLE, 'vice service is unavailable'))
end, false)

registerCommand('nightshift_s20_feedback', function(source, args)
    if not requireConsole(source, 'feedback') then return end
    local service = currentServices().demandHeatFeedback
    report('feedback', service and service:apply({
        district = args and args[1],
        heat = args and tonumber(args[2]),
        demandScore = args and tonumber(args[3]),
        activeWorkers = args and tonumber(args[4]),
        supplyCapacity = args and tonumber(args[5]),
        streetOpportunity = args and args[6] and tonumber(args[6]) or nil
    }) or NightShift.Result.err(NightShift.Errors.Codes.DEMAND_FEEDBACK_UNAVAILABLE or NightShift.Errors.Codes.DEMAND_UNAVAILABLE, 'demand heat feedback service is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S20 smoke commands enabled: /nightshift_s20_heat [district] [playerKey], /nightshift_s20_heat_event [district] [eventType] [playerKey] [playerAmount] [districtAmount] [eventKey], /nightshift_s20_heat_decay [unixNow], /nightshift_s20_heat_jobs, /nightshift_s20_vice [district] [pressure] [archetype] [meetingMode] [bookingId], /nightshift_s20_feedback [district] [heat] [demandScore] [activeWorkers] [capacity] [streetOpportunity]')
end
if type(server) == 'table' then server._s20SmokeCommandsLoaded = true end
