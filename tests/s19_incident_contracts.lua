local Incident = NightShift.Domain.Incident
local IncidentService = NightShift.Services.Incident
local DisputeService = NightShift.Services.Dispute
local Result = NightShift.Result

local function check(condition, message)
    if not condition then error(message, 2) end
end

check(Incident.isType('CUSTOMER_NO_SHOW'), 'incident type allowlist missing')
check(not Incident.isType('ACCUSATION'), 'incident type allowlist must reject arbitrary types')

do
    local value, err = Incident.new({ bookingId = 4, type = 'POLICE_INTERRUPTION', idempotencyKey = 'i-4' })
    check(value and not err and value.status == 'OPEN', 'incident domain should normalize valid input')
    local invalid = Incident.new({ bookingId = 4, type = 'ACCUSATION', idempotencyKey = 'bad' })
    check(not invalid, 'incident domain should reject unknown type')
end

local booking = { id = 4, status = 'ACTIVE', correlationId = 'corr-4', paymentState = 'HELD' }
local repository = {
    findById = function(_, id)
        if id == 4 then return Result.ok(booking) end
        return Result.err('REPOSITORY_NOT_FOUND', 'missing')
    end
}
local events = {}
local timeline = {
    record = function(_, current, oldState, newState, metadata)
        events[#events + 1] = { bookingId = current.id, oldState = oldState, newState = newState, eventType = metadata.eventType, metadata = metadata }
        return Result.ok(events[#events])
    end,
    history = function(_, id)
        if id ~= 4 then return Result.err('REPOSITORY_NOT_FOUND', 'missing') end
        return Result.ok(events)
    end
}

do
    local service = assert(IncidentService.new({ repository = repository, timelineService = timeline }))
    local first = service:report({ type = 'SYSTEM', ref = 'test' }, {
        bookingId = 4, type = 'PLAYER_DISCONNECT', idempotencyKey = 'disconnect-1', reason = 'connection lost'
    })
    check(first.ok and #events == 1 and events[1].eventType == 'INCIDENT_REPORTED', 'incident must bind to booking timeline')
    check(events[1].metadata.incident.type == 'PLAYER_DISCONNECT', 'timeline incident evidence missing')
end

do
    local service = assert(DisputeService.new({ repository = repository, timelineService = timeline }))
    local view = service:read(4)
    check(view.ok and view.metadata.evidenceOnly == true, 'dispute must return evidence-only read model')
    check(#view.value.incidents == 1 and view.value.paymentState == 'HELD', 'dispute must include incidents and payment state')
    check(view.value.accusation == nil and view.value.finding == nil, 'dispute must not infer accusation or finding')
end

print('NS-192..NS-193 tests passed: incident timeline binding and evidence-only disputes')
