local function s19check(value, message) assert(value, message) end
local Safety = NightShift.SafetyService
local Result = NightShift.Result
local function booking(id, status)
    return { id = id, status = status or 'ACTIVE', version = 1, workerType = 'PLAYER', workerRef = 'worker:1', clientType = 'NPC', clientRef = 'npc:1' }
end
local bookings = { ['1'] = booking(1) }
local bs = {
    get = function(_, id) return Result.ok(bookings[tostring(id)]) end,
    interrupt = function(_, actor, id)
        bookings[tostring(id)] = NightShift.Validators.copy(bookings[tostring(id)])
        bookings[tostring(id)].status = 'INTERRUPTED'
        return Result.ok(bookings[tostring(id)])
    end
}
local dispatched
local service = assert(Safety.new({
    bookingService = bs,
    dispatch = { emitSafetyAlert = function(_, payload) dispatched = payload; return Result.ok({ sent = true }) end },
    clock = { now = function() return 100 end },
    checkInIntervalSeconds = 30
}))
local actor = { type = 'PLAYER', ref = 'worker:1', source = 1 }
local started = service:checkIn(actor, 1)
s19check(started.ok and started.value.bookingId == '1', 'safety check-in must bind active booking')
s19check(service:imOkay(actor, 1).ok, 'I am OK must be idempotent')
s19check(not service:checkIn({ type = 'PLAYER', ref = 'worker:2', source = 2 }, 1).ok, 'other actor must be denied')
local help = service:requestHelp(actor, 1, 'need assistance')
s19check(help.ok and dispatched and dispatched.bookingId == '1', 'help must invoke optional dispatch')
s19check(service:requestEnd(actor, 1).ok, 'end request must be accepted')
local repeatedEnd = service:requestEnd(actor, 1)
s19check(repeatedEnd.ok and repeatedEnd.metadata.idempotent == true, 'end request must be idempotent')
local absent = assert(Safety.new({ bookingService = bs }))
s19check(absent:requestHelp(actor, 1, 'quiet').ok, 'missing provider must not break booking core')
print('NS-190 tests passed: safety ownership, check-in, help hook, idempotent end request')
