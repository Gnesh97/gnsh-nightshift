local function check(value, message) assert(value, message) end
local Result = NightShift.Result

do
    local calls
    local provider = {
        available = true,
        pushNotification = function(_, source, payload)
            calls = { source = source, payload = payload }
            payload.privateMutation = true
            return Result.ok({ delivered = true })
        end,
        openApp = function() return Result.ok({ opened = true }) end
    }
    local registry = NightShift.Phone.ProviderRegistry.new({ providers = { phone = provider } })
    check(not registry:pushNotification(0, {}).ok, 'phone source zero must be rejected')
    check(not registry:pushNotification(1.5, {}).ok, 'phone fractional source must be rejected')
    local payload = { nested = { value = 1 } }
    check(registry:pushNotification(7, payload).ok and calls.source == 7, 'valid phone source should delegate')
    check(payload.privateMutation == nil and calls.payload.nested.value == 1, 'phone provider payload must be isolated')
    check(not registry:register('phone', provider).ok, 'duplicate phone provider must be rejected')
end

do
    local housing = NightShift.Housing.ProviderRegistry.new({
        providers = {
            property = {
                available = true,
                listAccessible = function() error('provider down') end
            }
        }
    })
    local failed = housing:listAccessible(7, {})
    check(not failed.ok and failed.error.code == NightShift.Errors.Codes.PROVIDER_UNAVAILABLE,
        'housing provider exceptions must be typed failures')
    check(not housing:register('property', {}).ok, 'duplicate housing provider must be rejected')

    local motel = NightShift.Motel.ProviderRegistry.new({
        providers = { motel = { available = true, listAvailable = function() return {} end } }
    })
    check(not motel:register('motel', {}).ok, 'duplicate motel provider must be rejected')
end

do
    local provider = {
        id = 'nil-error',
        listAvailable = function() return nil, 'provider returned no data' end,
        validate = function() return { valid = true } end,
        resolveWorldTarget = function() return { worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 } } end
    }
    local api = NightShift.Server.LocationProviderApi.new()
    check(api:register(provider).ok, 'nil-error provider should register')
    local result = api:resolve('nil-error', 'listAvailable')
    check(not result.ok and result.error.code == 'PROVIDER_OPERATION_FAILED',
        'provider second return error must not be normalized as success')
end

do
    local configProvider = assert(NightShift.OptionalProviders.ConfigLocations.new({
        locations = {
            { id = 'roadside', type = 'SAFE_ROADSIDE', worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 },
              meetingModes = { 'COME_TO_ME' } },
            { id = 'configured', type = 'CONFIG_LOCATION', worldTarget = { kind = 'coords', x = 4, y = 5, z = 6 },
              meetingModes = { 'COME_TO_ME' } }
        }
    }))
    local listed = assert(configProvider:listAvailable(1, { meetingMode = 'COME_TO_ME' })).value
    check(#listed == 1 and listed[1].locationRef == 'configured',
        'config provider must not advertise non-config location types')
end

do
    local descriptor = {
        id = 'dynamic-target',
        type = 'CONFIG_LOCATION',
        provider = 'dynamic',
        worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 },
        accessRequirements = { public = true },
        meetingModes = { 'COME_TO_ME' }
    }
    local service = assert(NightShift.LocationService.new({
        locations = { descriptor },
        providers = {
            dynamic = {
                available = true,
                validate = function() return Result.ok({ valid = true }) end,
                resolveWorldTarget = function() return Result.ok({ worldTarget = { kind = 'coords', x = 9, y = 8, z = 7 } }) end
            }
        }
    }))
    local resolved = service:resolve(1, {
        locationType = 'CONFIG_LOCATION', locationRef = 'dynamic-target', meetingMode = 'COME_TO_ME'
    })
    check(resolved.ok and resolved.value.worldTarget.x == 9, 'provider target should be used for the response')
    check(descriptor.worldTarget.x == 1 and service:get('dynamic-target').worldTarget.x == 1,
        'registered location descriptors must remain immutable')
end

print('S22 review contracts passed: provider precedence guards, typed failures, filtering, and immutable targets')
