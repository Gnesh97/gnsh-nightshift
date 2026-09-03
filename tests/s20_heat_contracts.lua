local Heat = NightShift.Heat
local HeatService = NightShift.HeatService
local Result = NightShift.Result

local function check(condition, message)
    if not condition then error(message, 2) end
end

check(type(Heat) == 'table' and type(Heat.new) == 'function', 'heat domain must load')
check(type(HeatService) == 'table' and type(HeatService.new) == 'function', 'heat service must load')

local domain = assert(Heat.new({ min = 0, max = 100 }))
local applied = domain:apply({ playerHeat = 130, districtPressure = -5 })
check(applied.ok and applied.value.playerHeat == 100 and applied.value.districtPressure == 0, 'heat must clamp bounds')
local decayed = domain:decay(applied.value, 10, { intervalSeconds = 10, player = 5, district = 10 })
check(decayed.ok and decayed.value.playerHeat == 95 and decayed.value.districtPressure == 0, 'domain decay must clamp')

local service = assert(HeatService.new({
    config = {
        enabled = true, playerEnabled = true, min = 0, max = 100,
        playerIncrement = 10, districtIncrement = 7,
        decayIntervalSeconds = 10, playerDecay = 2, districtDecay = 3
    },
    clock = { now = function() return 100 end }
}))
local first = service:record({
    eventKey = 'booking:1:active', playerKey = 'player:1',
    district = 'vinewood', playerAmount = 15, districtAmount = 20, occurredAt = 100
})
check(first.ok and first.value.playerHeat == 15 and first.value.districtPressure == 20, 'event must increment both scopes')
local replay = service:record({
    eventKey = 'booking:1:active', playerKey = 'player:1',
    district = 'vinewood', playerAmount = 15, districtAmount = 20, occurredAt = 100
})
check(replay.ok and replay.value.idempotent == true, 'event key replay must be idempotent')
local snapshot = service:get({ playerKey = 'player:1', district = 'vinewood', now = 120 })
check(snapshot.ok and snapshot.value.playerHeat == 11 and snapshot.value.districtPressure == 14, 'scheduled decay must be elapsed and bounded')
local districtOnly = service:record({ eventKey = 'district:1', district = 'vinewood', districtAmount = 9, occurredAt = 120 })
check(districtOnly.ok and districtOnly.value.playerHeat == nil and districtOnly.value.districtPressure == 23, 'district-only event must not create player heat')
local disabled = assert(HeatService.new({ config = { enabled = false } }))
check(not disabled:record({ eventKey = 'x', district = 'vinewood' }).ok, 'disabled heat must fail closed')

local playerDisabled = assert(HeatService.new({
    config = {
        enabled = true, playerEnabled = false, playerIncrement = 10, districtIncrement = 4,
        decayIntervalSeconds = 10, playerDecay = 2, districtDecay = 2
    },
    clock = { now = function() return 100 end }
}))
local playerDisabledEvent = playerDisabled:record({
    eventKey = 'player-disabled:1', playerKey = 'player:1', district = 'vinewood',
    occurredAt = 100
})
check(playerDisabledEvent.ok and playerDisabledEvent.value.playerHeat == nil, 'player heat must stay disabled')
local playerDisabledDecay = playerDisabled:decay(120)
check(playerDisabledDecay.ok, 'district decay must not arithmetic on disabled player heat')
local playerDisabledSnapshot = playerDisabled:get({ playerKey = 'player:1', district = 'vinewood', now = 120 })
check(playerDisabledSnapshot.ok and playerDisabledSnapshot.value.playerHeat == nil, 'disabled player heat must remain nil')

local eventService = assert(HeatService.new({
    config = { enabled = true, playerIncrement = 4, districtIncrement = 6 },
    clock = { now = function() return 100 end }
}))
local bus = assert(NightShift.EventBus.new({ clock = { timestamp = function() return 100 end } }))
local attached = assert(eventService:attach(bus))
check(attached.value and #attached.value.subscriptions == 2, 'heat must subscribe to committed booking/incident events')
local delivered = bus:publishCommitted('booking.state_changed', {
    eventKey = 'booking:event:1',
    booking = { district = 'vespucci', workerProfileId = 'worker:1' }
})
check(delivered.ok and delivered.value.failed == 0, 'heat event adapter must not fail committed events')
local eventSnapshot = eventService:get({ district = 'vespucci', playerKey = 'worker:1', now = 100 })
check(eventSnapshot.ok and eventSnapshot.value.playerHeat == 4 and eventSnapshot.value.districtPressure == 6,
    'booking event adapter must record scoped heat')

print('NS-200 heat contracts passed: bounded player/district heat, idempotent events, and scheduled decay')
