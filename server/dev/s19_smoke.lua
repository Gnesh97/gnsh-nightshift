NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s19SmokeCommandsLoaded == true then return end

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
local configured = booleanConvar('nightshift_s19_smoke_commands')
if configured ~= nil then enabled = configured end
if booleanConvar('nightshift_s18_smoke_commands') == true or booleanConvar('nightshift_s17_smoke_commands') == true then enabled = true end
if not enabled then return end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S19 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local err = errorValue(result)
        print(('[gnsh-nightshift] S19 %s failed: code=%s message=%s'):format(label, tostring(err.code or 'UNKNOWN'), tostring(err.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'dispute' then
        print(('[gnsh-nightshift] S19 dispute ok: booking=%s events=%s arrivals=%s incidents=%s payment=%s evidenceOnly=%s'):format(
            tostring(value.bookingId or 'n/a'), tostring(type(value.events) == 'table' and #value.events or 0),
            tostring(type(value.arrivals) == 'table' and #value.arrivals or 0),
            tostring(type(value.incidents) == 'table' and #value.incidents or 0),
            tostring(value.paymentState or 'n/a'), tostring(result.metadata and result.metadata.evidenceOnly == true)))
        return
    end
    print(('[gnsh-nightshift] S19 %s ok: booking=%s worker=%s state=%s provider=%s filtered=%s'):format(
        label, tostring(value.bookingId or 'n/a'), tostring(value.workerProfileId or 'n/a'),
        tostring(value.state or value.status or value.active or 'n/a'),
        tostring(result.metadata and result.metadata.providerAvailable or 'n/a'),
        tostring(result.metadata and result.metadata.filtered or 'n/a')))
end

local function currentServices()
    return stageValue('services', 'services') or {}
end

local function actorFor(source, label)
    local numeric = tonumber(source)
    if numeric == nil or numeric < 0 then
        if type(print) == 'function' then print(('[gnsh-nightshift] S19 %s must be run from the FXServer console or an in-game player'):format(label)) end
        return nil
    end
    if numeric == 0 then return { type = 'SYSTEM', ref = 'nightshift:s19-smoke', source = 0 } end
    local services = currentServices()
    local identity = services.identity
    if type(identity) == 'table' and type(identity.resolve) == 'function' then
        local ok, resolved = pcall(identity.resolve, identity, numeric)
        if ok and type(resolved) == 'table' and resolved.ok and type(resolved.value) == 'table' then
            local ref = resolved.value.identityKey or resolved.value.key
            if type(ref) == 'string' and ref:match('%S') then return { type = 'PLAYER', ref = ref, source = numeric } end
        end
    end
    return { type = 'PLAYER', ref = 'player:' .. tostring(numeric), source = numeric }
end

registerCommand('nightshift_s19_safety_checkin', function(source, args)
    local actor = actorFor(source, 'safety check-in'); if not actor then return end
    local service = currentServices().safety
    report('safety-checkin', service and service:checkIn(actor, args and args[1]) or NightShift.Result.err(NightShift.Errors.Codes.SAFETY_NOT_READY, 'safety service is unavailable'))
end, false)

registerCommand('nightshift_s19_safety_ok', function(source, args)
    local actor = actorFor(source, 'safety OK'); if not actor then return end
    local service = currentServices().safety
    report('safety-ok', service and service:imOkay(actor, args and args[1]) or NightShift.Result.err(NightShift.Errors.Codes.SAFETY_NOT_READY, 'safety service is unavailable'))
end, false)

registerCommand('nightshift_s19_safety_help', function(source, args)
    local actor = actorFor(source, 'safety help'); if not actor then return end
    local service = currentServices().safety
    report('safety-help', service and service:requestHelp(actor, args and args[1], args and args[2]) or NightShift.Result.err(NightShift.Errors.Codes.SAFETY_NOT_READY, 'safety service is unavailable'))
end, false)

registerCommand('nightshift_s19_safety_end', function(source, args)
    local actor = actorFor(source, 'safety end'); if not actor then return end
    local service = currentServices().safety
    report('safety-end', service and service:requestEnd(actor, args and args[1]) or NightShift.Result.err(NightShift.Errors.Codes.SAFETY_NOT_READY, 'safety service is unavailable'))
end, false)

registerCommand('nightshift_s19_blacklist_add', function(source, args)
    local actor = actorFor(source, 'blacklist add'); if not actor then return end
    local service = currentServices().blacklist
    report('blacklist-add', service and service:add(actor, args and args[1], args and args[2] or 'OTHER') or NightShift.Result.err(NightShift.Errors.Codes.BLACKLIST_NOT_READY or 'BLACKLIST_INVALID', 'blacklist service is unavailable'))
end, false)

registerCommand('nightshift_s19_blacklist_remove', function(source, args)
    local actor = actorFor(source, 'blacklist remove'); if not actor then return end
    local service = currentServices().blacklist
    report('blacklist-remove', service and service:remove(actor, args and args[1]) or NightShift.Result.err(NightShift.Errors.Codes.BLACKLIST_NOT_READY or 'BLACKLIST_INVALID', 'blacklist service is unavailable'))
end, false)

registerCommand('nightshift_s19_blacklist_list', function(source)
    local actor = actorFor(source, 'blacklist list'); if not actor then return end
    local service = currentServices().blacklist
    report('blacklist-list', service and service:list(actor) or NightShift.Result.err(NightShift.Errors.Codes.BLACKLIST_NOT_READY or 'BLACKLIST_INVALID', 'blacklist service is unavailable'))
end, false)

registerCommand('nightshift_s19_incident', function(source, args)
    local actor = actorFor(source, 'incident'); if not actor then return end
    local service = currentServices().incident
    local bookingId, incidentType = args and args[1], args and args[2]
    local reason = args and args[3]
    local key = args and args[4] or ('smoke:%s:%s:%s'):format(tostring(source), tostring(bookingId), tostring(incidentType))
    report('incident', service and service:report(actor, {
        bookingId = bookingId, type = incidentType, reason = reason, idempotencyKey = key
    }) or NightShift.Result.err(NightShift.Errors.Codes.INCIDENT_NOT_READY or 'INCIDENT_INVALID', 'incident service is unavailable'))
end, false)

registerCommand('nightshift_s19_dispute', function(source, args)
    local actor = actorFor(source, 'dispute'); if not actor then return end
    local service = currentServices().dispute
    report('dispute', service and service:read(args and args[1]) or NightShift.Result.err(NightShift.Errors.Codes.DISPUTE_NOT_READY or 'DISPUTE_INVALID', 'dispute service is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S19 smoke commands enabled: /nightshift_s19_safety_checkin [bookingId], /nightshift_s19_safety_ok [bookingId], /nightshift_s19_safety_help [bookingId] [reason], /nightshift_s19_safety_end [bookingId], /nightshift_s19_blacklist_add [workerProfileId] [reason], /nightshift_s19_blacklist_remove [workerProfileId], /nightshift_s19_blacklist_list, /nightshift_s19_incident [bookingId] [type] [reason] [idempotencyKey], /nightshift_s19_dispute [bookingId]')
end
if type(server) == 'table' then server._s19SmokeCommandsLoaded = true end
