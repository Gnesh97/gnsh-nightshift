local function smokeS11Check(value, message)
    assert(value, message)
end

do
    local previousRegisterCommand = rawget(_G, 'RegisterCommand')
    local previousGetConvar = rawget(_G, 'GetConvar')
    local previousMeta = getmetatable(_G)
    local previousServer = NightShift.Server
    local registered = {}
    local native = {}
    native.RegisterCommand = function(name, callback, restricted) registered[name] = { callback = callback, restricted = restricted } end
    native.GetConvar = function(_, fallback) return fallback end
    local ok, errorMessage = pcall(function()
        NightShift.Server = { instance = { results = { config = { config = { environment = 'development' } }, services = { services = {} } } } }
        _G.RegisterCommand, _G.GetConvar = nil, nil
        setmetatable(_G, { __index = function(_, key) return native[key] end })
        dofile('server/dev/s11_smoke.lua')
        for _, name in ipairs({ 'nightshift_s11_begin', 'nightshift_s11_counter', 'nightshift_s11_accept', 'nightshift_s11_travel', 'nightshift_s11_arrive', 'nightshift_s11_session_start', 'nightshift_s11_session_complete' }) do
            smokeS11Check(registered[name], name .. ' must use the direct RegisterCommand native')
        end
        smokeS11Check(NightShift.Server._s11SmokeCommandsLoaded == true, 'S11 command module must mark itself loaded')
    end)
    setmetatable(_G, previousMeta)
    _G.RegisterCommand, _G.GetConvar = previousRegisterCommand, previousGetConvar
    NightShift.Server = previousServer
    smokeS11Check(ok, errorMessage)
end

do
    local previousRegisterCommand = rawget(_G, 'RegisterCommand')
    local previousGetConvar = rawget(_G, 'GetConvar')
    local previousMeta = getmetatable(_G)
    local previousServer = NightShift.Server
    local registered = {}
    local native = {
        RegisterCommand = function(name, callback, restricted) registered[name] = { callback = callback, restricted = restricted } end,
        GetConvar = function(name, fallback)
            if name == 'nightshift_s10_smoke_commands' then return 'true' end
            if name == 'nightshift_s11_smoke_commands' then return 'false' end
            return fallback
        end
    }
    local ok, errorMessage = pcall(function()
        NightShift.Server = { instance = { results = { config = { config = { environment = 'production' } }, services = { services = {} } } } }
        _G.RegisterCommand, _G.GetConvar = nil, nil
        setmetatable(_G, { __index = function(_, key) return native[key] end })
        dofile('server/dev/s11_smoke.lua')
        smokeS11Check(registered.nightshift_s11_begin, 'existing S10 smoke opt-in must enable the S11 suite')
    end)
    setmetatable(_G, previousMeta)
    _G.RegisterCommand, _G.GetConvar = previousRegisterCommand, previousGetConvar
    NightShift.Server = previousServer
    smokeS11Check(ok, errorMessage)
end

do
    local startedPayload, completedPayload
    local session, sessionError = NightShift.ClientAppointmentSession.new({
        startTransport = function(payload)
            startedPayload = payload
            local appointmentToken = 'appointment-token-1'
            return NightShift.Result.ok({ ['token'] = appointmentToken, bookingId = payload.bookingId, locationRef = payload.locationRef })
        end,
        completeTransport = function(payload) completedPayload = payload; return NightShift.Result.ok({ completed = true }) end
    })
    smokeS11Check(session and not sessionError, 'client appointment session controller should construct')
    local started = session:start(42, 'configured_default')
    smokeS11Check(started.ok and started.value.token == 'appointment-token-1' and startedPayload.bookingId == '42', 'client controller must pass a bound start request')
    local completed = session:complete(started.value.token, 42, 'configured_default')
    smokeS11Check(completed.ok and completedPayload.bookingId == '42' and completedPayload.token == 'appointment-token-1', 'client controller must forward completion without deciding settlement')
end

print('NS-112/NS-113 tests passed: direct smoke command registration and thin client session transport')
