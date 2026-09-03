local function check(value, message) assert(value, message) end

local now = 2000
local clock = NightShift.Clock.new({ now = function() return now end })
local bus = NightShift.EventBus.new({ clock = clock })
local surface, surfaceError = NightShift.DomainEvents.new({ eventBus = bus, native = false })
check(surface and not surfaceError, 'domain event surface must initialize')
local attached = surface:attach()
check(attached.ok and attached.value.subscriptions == 4, 'domain event surface must attach source subscriptions once')

local received = {}
local handle, subscribeError = bus:subscribe('nightshift:bookingAccepted', function(envelope)
    received[#received + 1] = envelope
end)
check(handle and not subscribeError, 'stable booking event must be subscribable')
local createdEvents = {}
handle, subscribeError = bus:subscribe('nightshift:bookingCreated', function(envelope)
    createdEvents[#createdEvents + 1] = envelope
end)
check(handle and not subscribeError, 'stable creation event must be subscribable')

local createdSource = bus:publishCommitted('booking.created', {
    booking = { id = 6, status = 'DRAFT', mode = 'CLIENT' },
    eventKey = 'booking:create:6'
}, { correlationId = 's25-create' })
check(createdSource.ok and #createdEvents == 1 and createdEvents[1].payload.bookingId == 6,
    'committed creation event must produce a stable bookingCreated alias')

local sourceResult = bus:publishCommitted('booking.state_changed', {
    booking = { id = 7, status = 'ACCEPTED', mode = 'CLIENT' },
    oldState = 'OFFERED',
    newState = 'ACCEPTED',
    eventKey = 'booking:7:1:ACCEPTED'
}, { correlationId = 's25-test' })
check(sourceResult.ok and #received == 1, 'committed state event must produce one stable alias')
check(received[1].payload.bookingId == 7 and received[1].payload.status == 'ACCEPTED',
    'stable alias payload must use the safe booking DTO')

local rejected = surface:publish('bookingAccepted', NightShift.Result.err('TEST', 'not committed'))
check(not rejected.ok and rejected.error.code == NightShift.Errors.Codes.EVENT_INVALID, 'event surface must reject failed results')
local direct = surface:publish('bookingAccepted', NightShift.Result.ok({ id = 8, status = 'ACCEPTED' }), { correlationId = 'direct' })
check(direct.ok and direct.value.event == 'nightshift:bookingAccepted', 'direct stable event publication must be allowlisted')
check(#received == 2, 'direct stable publication must reach subscribers')
check(surface:close() == true, 'event surface must close cleanly')

print('NS-257..NS-259 tests passed: committed domain event aliases, DTO payload safety, allowlist, and close')
