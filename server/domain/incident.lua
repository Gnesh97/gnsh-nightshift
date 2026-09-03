NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Incident = {}

local types = {
    CUSTOMER_NO_SHOW = true,
    WORKER_NO_SHOW = true,
    NON_PAYMENT = true,
    LOCATION_UNAVAILABLE = true,
    NPC_NAVIGATION_FAILED = true,
    POLICE_INTERRUPTION = true,
    PLAYER_DISCONNECT = true
}

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

function Incident.isType(value)
    return type(value) == 'string' and types[value:upper()] == true
end

function Incident.new(input)
    if type(input) ~= 'table' then return nil, Result.err(Codes.INCIDENT_INVALID, 'incident input must be a table') end
    local bookingId = input.bookingId or input.booking_id
    if not ((type(bookingId) == 'number' and bookingId >= 1 and math.floor(bookingId) == bookingId) or text(bookingId, 160)) then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident booking ID is required')
    end
    local incidentType = type(input.type) == 'string' and input.type:upper() or nil
    if not Incident.isType(incidentType) then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident type is not allowed', { type = input.type })
    end
    local idempotencyKey = input.idempotencyKey or input.idempotency_key
    if not text(idempotencyKey, 128) then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident idempotency key is required')
    end
    local actorType = input.actorType and tostring(input.actorType):upper() or nil
    if actorType ~= nil and not text(actorType, 32) then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident actor type is invalid')
    end
    if input.actorRef ~= nil and not text(input.actorRef, 160) then
        return nil, Result.err(Codes.INCIDENT_INVALID, 'incident actor reference is invalid')
    end
    return {
        id = input.id,
        bookingId = bookingId,
        type = incidentType,
        status = 'OPEN',
        idempotencyKey = idempotencyKey,
        actorType = actorType,
        actorRef = input.actorRef,
        reason = text(input.reason, 256) and input.reason or nil,
        occurredAt = input.occurredAt,
        evidence = copy(input.evidence),
        metadata = copy(input.metadata)
    }
end

Incident.types = types
NightShift.Domain.Incident = Incident
