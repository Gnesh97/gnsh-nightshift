local function check(value, message) assert(value, message) end
local Venue = NightShift.Domain.Venue
local Service = NightShift.VenueService

local clock = { now = function() return 1000 end }
local service = assert(Service.new({
    clock = clock,
    venues = {
        {
            id = 'club-1', name = 'Club One', capacity = 4,
            rooms = { main = { capacity = 2 } },
            commission = { rate = 10, fixed = 5 },
            openingHours = { [5] = { open = 0, close = 1440 } }
        }
    }
}))
check(service:list().value[1].id == 'club-1', 'configured venue should be listed')
check(not service:register({ id = 'club-2' }, 7).ok, 'venue registration must require administration')
check(service:register({ id = 'club-2' }, 0).ok, 'console venue registration should succeed')
check(not service:register({ id = 'club-2' }).ok, 'duplicate venue should be rejected')
check(not Venue.new({ id = 'bad', rooms = 'not-a-table' }), 'venue rooms must be validated')

local first = service:reserveSlot('club-1', {
    roomId = 'main', bookingId = 'booking-1', startAt = 1000, endAt = 1100
})
check(first.ok and first.value.status == 'RESERVED', 'venue slot should reserve')
check(service:reserveSlot('club-1', {
    roomId = 'main', bookingId = 'booking-1', startAt = 1000, endAt = 1100
}).ok, 'same venue slot reservation should be idempotent')
local overlap = service:reserveSlot('club-1', {
    roomId = 'main', bookingId = 'booking-2', startAt = 1050, endAt = 1150
})
check(not overlap.ok and overlap.error.code == NightShift.Errors.Codes.RESERVATION_CONFLICT,
    'overlapping venue slots must be rejected')
check(service:occupySlot('club-1', { reservationKey = first.value.venueId .. ':main:1000', bookingId = 'booking-1' }).ok,
    'reserved venue slot should be occupiable')
check(not service:releaseSlot('club-1', { reservationKey = first.value.venueId .. ':main:1000', bookingId = 'other' }).ok,
    'venue reservation owner must be enforced')
check(service:releaseSlot('club-1', { reservationKey = first.value.venueId .. ':main:1000', bookingId = 'booking-1' }).value.released,
    'venue slot should release')
local commission = service:commission('club-1', 1000)
check(commission.ok and commission.value.commission == 105 and commission.value.net == 895,
    'venue commission should be explainable')

print('NS-232 tests passed: venue profiles, room slots, capacity, desk guards, and commission')
