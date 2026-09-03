NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Relationship = {}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value ~= math.floor(value) then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function token(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function invalid(message, details)
    return Result.err(Codes.RELATIONSHIP_INVALID, message, details)
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('relationship must be a table') end
    local clientProfileId = integer(values.clientProfileId or values.client_profile_id, 1, 2147483647)
    local workerProfileId = integer(values.workerProfileId or values.worker_profile_id, 1, 2147483647)
    if not clientProfileId or not workerProfileId then return nil, invalid('relationship profile IDs are required') end
    local kind = values.relationshipType or values.relationship_type or 'REGULAR'
    if not token(kind, 32) then return nil, invalid('relationship type is invalid') end
    kind = kind:upper()
    local interactionCount = integer(values.interactionCount or values.interaction_count or 0, 0, 2147483647)
    local trustScore = integer(values.trustScore or values.trust_score or 0, 0, 100)
    if interactionCount == nil or trustScore == nil then return nil, invalid('relationship counters are invalid') end
    local lastBookingId = values.lastBookingId or values.last_booking_id
    if lastBookingId ~= nil and not integer(lastBookingId, 1, 2147483647) and not token(tostring(lastBookingId), 160) then
        return nil, invalid('relationship last booking ID is invalid')
    end
    local version = integer(values.version or 1, 1, 2147483647)
    if not version then return nil, invalid('relationship version is invalid') end
    return {
        id = values.id,
        clientProfileId = clientProfileId,
        workerProfileId = workerProfileId,
        relationshipType = kind,
        interactionCount = interactionCount,
        trustScore = trustScore,
        lastBookingId = lastBookingId,
        version = version,
        createdAt = values.createdAt or values.created_at,
        updatedAt = values.updatedAt or values.updated_at
    }
end

function Relationship.new(values)
    return normalize(values)
end

function Relationship.fromRow(row)
    return normalize(row)
end

function Relationship.validate(values)
    local value, errorResult = normalize(values)
    return value ~= nil, errorResult
end

function Relationship.copy(value)
    return copy(value)
end

function Relationship.toRow(value)
    local normalized, errorResult = normalize(value)
    if not normalized then return nil, errorResult end
    return {
        client_profile_id = normalized.clientProfileId,
        worker_profile_id = normalized.workerProfileId,
        relationship_type = normalized.relationshipType,
        interaction_count = normalized.interactionCount,
        trust_score = normalized.trustScore,
        last_booking_id = normalized.lastBookingId
    }
end

NightShift.Domain.Relationship = Relationship
NightShift.Relationship = Relationship
