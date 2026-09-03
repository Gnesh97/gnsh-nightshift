NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s22SmokeCommandsLoaded == true then return end

local function stageValue(name, key)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
    if type(stage) ~= 'table' then return nil end
    return stage[key] or stage.value and stage.value[key] or stage
end

local function enabled()
    local config = stageValue('config', 'config') or NightShift.DefaultConfig or {}
    local active = type(config) == 'table' and tostring(config.environment or ''):lower() == 'development'
    -- These commands exercise reservation/provider lifecycle state and are
    -- intentionally development-only.  A convar can opt in during
    -- development, but must not expose the surface in production.
    if not active then return false end
    if type(getConvar) ~= 'function' then return true end
    local ok, value = pcall(getConvar, 'nightshift_s22_smoke_commands', '')
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

local function errorValue(result)
    return type(result) == 'table' and (result.error or result)
        or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S22 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local err = errorValue(result)
        print(('[gnsh-nightshift] S22 %s failed: code=%s message=%s'):format(
            label, tostring(err.code or 'UNKNOWN'), tostring(err.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'providers' then
        local count = type(value) == 'table' and #value or 0
        print(('[gnsh-nightshift] S22 providers ok: count=%s'):format(tostring(count)))
        for _, provider in ipairs(value) do
            print(('  provider=%s available=%s'):format(
                tostring(provider.name or provider.id or 'n/a'), tostring(provider.available == true)))
        end
        return
    end
    if label == 'locations' then
        print(('[gnsh-nightshift] S22 locations ok: count=%s'):format(tostring(#value)))
        for _, location in ipairs(value) do
            print(('  ref=%s type=%s available=%s reservable=%s'):format(
                tostring(location.locationRef or location.id or 'n/a'),
                tostring(location.locationType or location.type or 'n/a'),
                tostring(location.available == true), tostring(location.reservable == true)))
        end
        return
    end
    print(('[gnsh-nightshift] S22 %s ok: ref=%s type=%s booking=%s reservation=%s status=%s'):format(
        label, tostring(value.locationRef or value.location and value.location.locationRef or 'n/a'),
        tostring(value.locationType or value.location and value.location.locationType or 'n/a'),
        tostring(value.bookingId or 'n/a'), tostring(value.reservationKey or 'n/a'),
        tostring(value.status or value.reserved or value.occupied or value.released or 'n/a')))
end

local function validSource(source, label)
    local numeric = tonumber(source)
    if numeric == nil or numeric < 0 then
        if type(print) == 'function' then
            print(('[gnsh-nightshift] S22 %s must be run from the FXServer console or an in-game player'):format(label))
        end
        return false
    end
    return true
end

registerCommand('nightshift_s22_provider_list', function(source)
    if not validSource(source, 'provider-list') then return end
    local current = services()
    local output = {}
    local function add(label, registry)
        if type(registry) ~= 'table' then return end
        local listed
        if type(registry.list) == 'function' then
            listed = registry:list()
        elseif type(registry.listAvailable) == 'function' then
            listed = registry:listAvailable(source, {})
        end
        for _, provider in ipairs(type(listed) == 'table' and listed.value or {}) do
            local value = {}
            for key, item in pairs(provider) do value[key] = item end
            value.name = value.name or label
            output[#output + 1] = value
        end
    end
    add('config', current.configLocations)
    add('motel', current.motelProviders)
    add('housing', current.housingProviders)
    if type(current.locationProviderApi) == 'table' and type(current.locationProviderApi.list) == 'function' then
        local listed = current.locationProviderApi:list()
        for _, provider in ipairs(type(listed) == 'table' and listed.value or {}) do output[#output + 1] = provider end
    end
    report('providers', NightShift.Result.ok(output))
end, false)

registerCommand('nightshift_s22_locations', function(source, args)
    if not validSource(source, 'locations') then return end
    local service = services().location
    report('locations', service and service:list({
        locationType = args and args[1] and tostring(args[1]):upper() or nil,
        available = true
    }) or NightShift.Result.err(NightShift.Errors.Codes.LOCATION_UNAVAILABLE, 'location service is unavailable'))
end, false)

registerCommand('nightshift_s22_location_resolve', function(source, args)
    if not validSource(source, 'resolve') then return end
    local service = services().location
    local locationType, locationRef, meetingMode = args and args[1], args and args[2], args and args[3]
    report('resolve', service and service:resolve(source, {
        locationType = locationType, locationRef = locationRef, meetingMode = meetingMode
    }) or NightShift.Result.err(NightShift.Errors.Codes.LOCATION_UNAVAILABLE, 'location service is unavailable'))
end, false)

registerCommand('nightshift_s22_location_reserve', function(source, args)
    if not validSource(source, 'reserve') then return end
    local current = services()
    local bookingId, locationType, locationRef, meetingMode = args and args[1], args and args[2], args and args[3], args and args[4]
    report('reserve', current.locationReservation and current.locationReservation:reserve(bookingId, {
        locationType = locationType, locationRef = locationRef, meetingMode = meetingMode, source = source
    }, { source = source }) or NightShift.Result.err(NightShift.Errors.Codes.RESERVATION_INVALID, 'location reservation service is unavailable'))
end, false)

registerCommand('nightshift_s22_location_occupy', function(source, args)
    if not validSource(source, 'occupy') then return end
    local current = services()
    report('occupy', current.locationReservation and current.locationReservation:occupy(args and args[1], args and args[2])
        or NightShift.Result.err(NightShift.Errors.Codes.RESERVATION_INVALID, 'location reservation service is unavailable'))
end, false)

registerCommand('nightshift_s22_location_release', function(source, args)
    if not validSource(source, 'release') then return end
    local current = services()
    report('release', current.locationReservation and current.locationReservation:release(args and args[1], args and args[2])
        or NightShift.Result.err(NightShift.Errors.Codes.RESERVATION_INVALID, 'location reservation service is unavailable'))
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S22 smoke commands enabled: /nightshift_s22_provider_list, /nightshift_s22_locations [type], /nightshift_s22_location_resolve [type] [ref] [mode], /nightshift_s22_location_reserve [bookingId] [type] [ref] [mode], /nightshift_s22_location_occupy [bookingId] [reservationKey], /nightshift_s22_location_release [bookingId] [reservationKey]')
end
if type(server) == 'table' then server._s22SmokeCommandsLoaded = true end
