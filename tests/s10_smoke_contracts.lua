local function smokeCheck(value, message)
    assert(value, message)
end

do
    local previousRegisterCommand = rawget(_G, 'RegisterCommand')
    local previousGetConvar = rawget(_G, 'GetConvar')
    local previousMeta = getmetatable(_G)
    local previousServer = NightShift.Server
    local registered = {}
    local native = {}

    native.RegisterCommand = function(name, callback, restricted)
        registered[name] = { callback = callback, restricted = restricted }
    end
    native.GetConvar = function(name, fallback)
        return name == 'nightshift_s10_smoke_commands' and 'true' or fallback
    end

    local ok, errorMessage = pcall(function()
        NightShift.Server = {
            instance = {
                results = {
                    config = { config = { environment = 'production' } },
                    services = {
                        services = {
                            workerAvailability = { setAvailable = function() return NightShift.Result.ok({ state = 'AVAILABLE' }) end },
                            npcCustomer = { generate = function() return NightShift.Result.ok({ state = 'CUSTOMER' }) end }
                        }
                    }
                }
            }
        }
        _G.RegisterCommand = nil
        _G.GetConvar = nil
        setmetatable(_G, {
            __index = function(_, key) return native[key] end
        })

        dofile('server/dev/s10_smoke.lua')

        smokeCheck(registered.nightshift_s10_available, 'S10 availability command must use the direct RegisterCommand native')
        smokeCheck(registered.nightshift_s10_customer, 'S10 customer command must use the direct RegisterCommand native')
        smokeCheck(registered.nightshift_s10_offline, 'S10 offline command must use the direct RegisterCommand native')
        smokeCheck(NightShift.Server._s10SmokeCommandsLoaded == true, 'S10 command module must mark itself loaded')
    end)

    setmetatable(_G, previousMeta)
    _G.RegisterCommand = previousRegisterCommand
    _G.GetConvar = previousGetConvar
    NightShift.Server = previousServer
    smokeCheck(ok, errorMessage)
end
