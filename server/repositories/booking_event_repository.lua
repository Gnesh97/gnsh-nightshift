NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'booking_id', 'event_key', 'event_type', 'actor_type', 'actor_ref',
    'old_state', 'new_state', 'reason', 'correlation_id', 'metadata_json',
    'payload', 'occurred_at', 'created_at'
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function integer(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value or (minimum and value < minimum) then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function encode(value)
    if value == nil then return nil end
    if type(value) == 'string' then
        if #value > 16384 then return nil, invalid('event metadata is too long') end
        return value
    end
    local json = rawget(_G, 'json')
    if type(json) == 'table' and type(json.encode) == 'function' then
        local ok, output = pcall(json.encode, value)
        if ok and type(output) == 'string' and #output <= 16384 then return output end
    end
    return nil, invalid('event metadata cannot be serialized')
end

local function decode(value)
    if type(value) ~= 'string' then return copy(value) end
    local json = rawget(_G, 'json')
    if type(json) == 'table' and type(json.decode) == 'function' then
        local ok, output = pcall(json.decode, value)
        if ok then return output end
    end
    return value
end

local function mapRow(row)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'booking event row is not a table') end
    local bookingId = row.booking_id or row.bookingId
    local eventKey = row.event_key or row.eventKey
    local eventType = row.event_type or row.eventType
    if not integer(bookingId, 1) or not text(eventKey, 128) or not text(eventType, 64) then
        return nil, Result.err(Codes.MAPPING_FAILED, 'booking event row is invalid')
    end
    return {
        id = row.id,
        bookingId = bookingId,
        eventKey = eventKey,
        eventType = eventType,
        actorType = row.actor_type or row.actorType,
        actorRef = row.actor_ref or row.actorRef,
        oldState = row.old_state or row.oldState,
        newState = row.new_state or row.newState,
        reason = row.reason,
        correlationId = row.correlation_id or row.correlationId,
        metadata = decode(row.metadata_json or row.metadata),
        payload = decode(row.payload),
        occurredAt = row.occurred_at or row.occurredAt,
        createdAt = row.created_at or row.createdAt
    }
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'booking event repository requires a database adapter') end
    local tableName = options.tableName or 'nightshift_booking_events'
    if type(tableName) ~= 'string' or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then return nil, invalid('booking event repository table name is invalid') end
    local base, err = Base.new({ db = database, tableName = tableName, columns = columns, mapper = mapRow })
    if not base then return nil, err end
    return setmetatable({ _base = base, _db = database, _table = tableName }, Repository)
end

function Repository:create(event)
    if type(event) ~= 'table' then return invalid('booking event must be a table') end
    if not integer(event.bookingId, 1) and not text(event.bookingId, 160) then return invalid('booking event bookingId is invalid') end
    if not text(event.eventKey, 128) or not text(event.eventType, 64) then return invalid('booking event key/type is invalid') end
    local metadata, metadataError = encode(event.metadata)
    if metadataError then return metadataError end
    local payload, payloadError = encode(event.payload)
    if payloadError then return payloadError end
    local row = {
        booking_id = event.bookingId,
        event_key = event.eventKey,
        event_type = event.eventType,
        actor_type = event.actorType,
        actor_ref = event.actorRef,
        old_state = event.oldState,
        new_state = event.newState,
        reason = event.reason,
        correlation_id = event.correlationId,
        metadata_json = metadata,
        payload = payload,
        occurred_at = event.occurredAt
    }
    return self._base:create(row)
end

function Repository:findByKey(bookingId, eventKey)
    if not integer(bookingId, 1) and not text(bookingId, 160) then return invalid('booking event bookingId is invalid') end
    if not text(eventKey, 128) then return invalid('booking event key is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE booking_id = ? AND event_key = ? LIMIT 1'):format(selectList, self._table)
    local result = self._db:single(sql, { bookingId, eventKey })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking event was not found', { bookingId = bookingId, eventKey = eventKey }) end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:findByBooking(bookingId, options)
    if not integer(bookingId, 1) and not text(bookingId, 160) then return invalid('booking event bookingId is invalid') end
    options = options or {}
    local limit = tonumber(options.limit or 100)
    local offset = tonumber(options.offset or 0)
    if not limit or limit < 1 or limit > 1000 or math.floor(limit) ~= limit or not offset or offset < 0 or math.floor(offset) ~= offset then
        return invalid('booking event pagination is invalid')
    end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE booking_id = ? ORDER BY id ASC LIMIT ? OFFSET ?'):format(selectList, self._table)
    local result = self._db:query(sql, { bookingId, limit, offset })
    if type(result) ~= 'table' or not result.ok then return result end
    local output = {}
    for index, row in ipairs(result.value or {}) do
        local mapped, mapError = self._base:_map(row)
        if not mapped then return mapError end
        output[index] = mapped
    end
    return Result.ok(output, { bookingId = bookingId, limit = limit, offset = offset })
end

Repository.findAllByBooking = Repository.findByBooking
NightShift.Repositories.BookingEvent = Repository
NightShift.Repositories.BookingEvents = Repository
