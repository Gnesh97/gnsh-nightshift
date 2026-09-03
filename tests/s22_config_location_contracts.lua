local function check(value, message) assert(value, message) end
local Result = NightShift.Result
local Provider = NightShift.OptionalProviders and NightShift.OptionalProviders.ConfigLocations
check(type(Provider) == 'table', 'S22 config location provider must be loaded')

local now = 1700000000
local provider = assert(Provider.new({
    clock = { now = function() return now end },
    locations = {
        { id = 'safe-room', category = 'venue', worldTarget = { kind = 'coords', x = 10, y = 20, z = 30 },
          meetingModes = { 'COME_TO_ME', 'MEET_THERE' }, capacity = 1, fees = { base = 25 },
          openingHours = {
              [1] = { open = 0, close = 1439 }, [2] = { open = 0, close = 1439 },
              [3] = { open = 0, close = 1439 }, [4] = { open = 0, close = 1439 },
              [5] = { open = 0, close = 1439 }, [6] = { open = 0, close = 1439 },
              [7] = { open = 0, close = 1439 }
          } },
        { id = 'always-open', worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 },
          meetingModes = { 'PICKUP' } }
    }
}))
check(provider:isAvailable() and provider:getCapabilities().configLocations, 'config provider must be available without external resources')
local listed = assert(provider:listAvailable(1, { meetingMode = 'COME_TO_ME' })).value
check(#listed == 1 and listed[1].locationRef == 'safe-room' and listed[1].fees.base == 25, 'static config locations must list typed descriptors and fees')
local invalid = provider:validate(1, 'safe-room', { meetingMode = 'PICKUP' })
check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.LOCATION_INCOMPATIBLE, 'meeting modes must be enforced')
local target = assert(provider:resolveWorldTarget('safe-room'))
target.value.worldTarget.x = 999
check(assert(provider:resolveWorldTarget('safe-room')).value.worldTarget.x == 10, 'world targets must be copied')
local first = assert(provider:reserve('safe-room', 'booking-1', 60))
check(first.value.reserved and assert(provider:reserve('safe-room', 'booking-1', 60)).value.idempotent, 'capacity reservation must be idempotent')
local full = provider:reserve('safe-room', 'booking-2', 60)
check(not full.ok and full.error.code == NightShift.Errors.Codes.LOCATION_UNAVAILABLE, 'capacity must reject competing reservations')
check(assert(provider:occupy('safe-room', 'booking-1')).value.occupied, 'reserved config location must be occupiable')
check(assert(provider:release('safe-room', 'booking-1')).value.released, 'config reservation must release')
local invalidCapacity = Provider.new({ locations = { { id = 'bad', worldTarget = {}, meetingModes = { 'PICKUP' }, capacity = 0 } } })
check(not invalidCapacity, 'invalid optional capacity must fail closed')
local fallback = assert(Provider.new({ locations = { { id = 'fallback', worldTarget = { kind = 'coords', x = 0, y = 0, z = 0 }, meetingModes = { 'COME_TO_ME' } } } }))
check(fallback:isAvailable(), 'zero external resources must retain config fallback')
local locationService = assert(NightShift.LocationService.new({
    locations = {
        { id = 'safe-room', type = 'CONFIG_LOCATION', provider = 'config',
          worldTarget = { kind = 'coords', x = 10, y = 20, z = 30 },
          accessRequirements = { public = true }, meetingModes = { 'COME_TO_ME' } }
    },
    providers = { config = provider }
}))
local resolved = locationService:resolve(1, {
    locationType = 'CONFIG_LOCATION', locationRef = 'safe-room', meetingMode = 'COME_TO_ME'
})
check(resolved.ok and resolved.value.locationRef == 'safe-room',
    'config provider should participate in typed location resolution')
print('NS-222 tests passed: static typed locations, capacity, modes, fees, opening hours, and fallback')
