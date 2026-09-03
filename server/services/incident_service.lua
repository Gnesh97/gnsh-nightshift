NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Incident = NightShift.Domain.Incident

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and type(value) == 'string' then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

function Service.new(options)
    options = options or {}
    local timeline = options.timelineService or options.timeline
    if type(timeline) ~= 'table' or type(timeline.record) ~= 'function' then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident service requires a timeline service')
    end
    local repository = options.bookingRepository or options.repository
    if type(repository) ~= 'table' or type(repository.findById) ~= 'function' then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident service requires a booking repository')
    end
    return setmetatable({
        _timeline = timeline,
        _repository = repository,
        _eventBus = options.eventBus,
        _clock = options.clock
    }, Service)
end

function Service:report(actor, input)
    if type(input) ~= 'table' then return Result.err(Codes.INCIDENT_INVALID, 'incident input must be a table') end
    local request = copy(input)
    request.actorType = request.actorType or (type(actor) == 'table' and actor.type)
    request.actorRef = request.actorRef or (type(actor) == 'table' and actor.ref)
    request.occurredAt = request.occurredAt or timestamp(self._clock)
    local incident, incidentError = Incident.new(request)
    if not incident then return incidentError end
    local bookingResult = self._repository:findById(incident.bookingId)
    if type(bookingResult) ~= 'table' or bookingResult.ok ~= true or type(bookingResult.value) ~= 'table' then
        return Result.err(Codes.INCIDENT_NOT_FOUND, 'incident booking was not found', { bookingId = incident.bookingId })
    end
    local booking = bookingResult.value
    local eventKey = ('incident:%s:%s'):format(tostring(incident.bookingId), incident.idempotencyKey)
    local timeline = self._timeline:record(booking, booking.status or 'UNKNOWN', booking.status or 'UNKNOWN', {
        eventKey = eventKey,
        eventType = 'INCIDENT_REPORTED',
        actorType = incident.actorType,
        actorRef = incident.actorRef,
        reason = incident.reason,
        incident = copy(incident),
        metadata = copy(incident.metadata)
    })
    if type(timeline) ~= 'table' or timeline.ok ~= true then
        return Result.err(Codes.INCIDENT_OPERATION_FAILED, 'incident timeline could not be persisted', {
            bookingId = incident.bookingId,
            cause = timeline and timeline.error and timeline.error.code
        })
    end
    local output = copy(incident)
    output.eventKey = eventKey
    output.timelineEvent = timeline.value
    if self._eventBus and type(self._eventBus.publishCommitted) == 'function' then
        pcall(self._eventBus.publishCommitted, self._eventBus, 'booking.incident_reported', {
            incident = copy(output),
            bookingId = incident.bookingId,
            district = incident.metadata and incident.metadata.district,
            metadata = copy(incident.metadata)
        }, { correlationId = booking.correlationId })
    end
    return Result.ok(output, { idempotent = timeline.metadata and timeline.metadata.idempotent == true })
end

Service.create = Service.report
NightShift.IncidentService = Service
NightShift.Services.Incident = Service
