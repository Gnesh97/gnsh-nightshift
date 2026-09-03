local function check(value, message) assert(value, message) end
local Result = NightShift.Result
local Api = NightShift.Server.LocationProviderApi
check(type(Api) == 'table' and type(Api.new) == 'function', 'S22 location provider API must be loaded')

local calls = 0
local available = true
local input = { district = 'vinewood', nested = { value = 1 } }
local provider = {
    id = 'housing',
    resource = 'gnsh-housing',
    capabilities = { listAvailable = true, validate = true, resolveWorldTarget = true },
    isAvailable = function() return available end,
    listAvailable = function(_, _, context)
        calls = calls + 1
        check(context.nested.value == 7, 'provider receives request data')
        context.nested.value = 99
        return Result.ok({ { locationRef = 'house-1' } })
    end,
    validate = function(_, _, locationRef) return Result.ok({ valid = locationRef == 'house-1' }) end,
    resolveWorldTarget = function(_, locationRef) return Result.ok({ worldTarget = { kind = 'coords', id = locationRef } }) end
}

local api = Api.new()
local registered = assert(api:register(provider))
check(registered.value.id == 'housing', 'typed provider should register')
check(not api:register(provider).ok, 'duplicate provider should be rejected')
input.nested.value = 7
local listed = assert(api:resolve('housing', 'listAvailable', 1, input))
check(calls == 1 and input.nested.value == 7 and listed.value[1].locationRef == 'house-1', 'provider input/output must be isolated')
local providers = assert(api:list())
check(#providers.value == 1 and providers.value[1].available and providers.value[1].capabilities.validate, 'provider list should expose status and capabilities')
local attachedService = { _providers = {} }
check(api:attachLocationService(attachedService).ok and type(attachedService._providers.housing) == 'table',
    'provider facades should attach to the location service')
local external = {
    id = 'motel',
    listAvailable = function() return { rooms = {} } end,
    validate = function() return { valid = true } end,
    resolveWorldTarget = function() return { worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 } } end
}
check(api:register(external).ok and type(attachedService._providers.motel) == 'table',
    'providers registered after boot should reach attached location services')
available = false
local down = api:resolve('housing', 'validate', 1, 'house-1')
check(not down.ok and down.error.code == 'PROVIDER_UNAVAILABLE', 'unavailable provider must fail gracefully')
available = true
local unsupported = api:resolve('housing', 'reserve', 'house-1', 'booking-1')
check(not unsupported.ok and unsupported.error.code == 'PROVIDER_CAPABILITY_UNSUPPORTED', 'unsupported capability must be explicit')
check(not Api.new():register({ id = 'bad', listAvailable = function() end }).ok, 'missing required methods must be rejected')
check(api:unregister('housing').ok and not api:unregister('housing').ok, 'provider unregister should be idempotently guarded')
print('NS-223 tests passed: typed location provider registry, immutable calls, availability, and guarded operations')
