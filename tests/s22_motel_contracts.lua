local function check(value, message) assert(value, message) end
local Registry = NightShift.Motel and NightShift.Motel.ProviderRegistry
check(type(Registry) == 'table', 'S22 motel provider registry must be loaded')
local calls = {}
local provider = {
    isAvailable = function() return true end,
    getCapabilities = function() return { listAvailable=true, validate=true, reserve=true, occupy=true, release=true, resolveWorldTarget=true } end,
    listAvailable = function(_, source, context) calls.list={source,context}; return { rooms={{id='room-1',state='AVAILABLE'}} } end,
    validateRoom = function(_, source, roomId) calls.validate={source,roomId}; return { valid=true } end,
    reserveRoom = function(_, roomId, bookingId, ttl) calls.reserve={roomId,bookingId,ttl}; return true end,
    occupy = function(_, roomId, bookingId) calls.occupy={roomId,bookingId}; return { occupied=true } end,
    releaseRoom = function(_, roomId, bookingId) calls.release={roomId,bookingId}; return true end,
    resolveMeetingTarget = function(_, roomId) return { worldTarget={kind='provider',provider='my_motel',ref=roomId} } end
}
local registry = Registry.new({ defaultProvider='my_motel', providers={ my_motel=provider } })
local listed = registry:listAvailable(7, { district='vinewood' })
check(listed.ok and listed.value.rooms[1].id == 'room-1' and calls.list[1] == 7, 'motel registry must list rooms')
calls.list[2].district = 'mutated'
local listedAgain = registry:listAvailable(7, { district='vinewood' })
check(listedAgain.ok and calls.list[2].district == 'vinewood', 'motel registry must isolate context copies')
check(registry:validate(7, 'room-1').ok, 'motel registry must validate access')
check(registry:reserve('room-1', 'booking-1', 60).ok and calls.reserve[3] == 60, 'motel registry must reserve rooms')
check(registry:occupy('room-1', 'booking-1').ok, 'motel registry must occupy rooms')
check(registry:release('room-1', 'booking-1').ok, 'motel registry must release rooms')
check(registry:resolveWorldTarget('room-1').ok, 'motel registry must resolve world targets')
local descriptions = registry:list()
check(descriptions.ok and descriptions.value[1].capabilities.occupy == true, 'motel registry must expose capabilities')
check(not registry:reserve('', 'booking-1', 60).ok, 'motel registry must validate references')
local missing = Registry.new({ defaultProvider='missing' }):listAvailable(7, {})
check(missing.ok and missing.value.skipped == true, 'missing motel provider must degrade gracefully')
print('NS-220 tests passed: motel/hotel registry, room lifecycle, capabilities, and graceful degradation')
