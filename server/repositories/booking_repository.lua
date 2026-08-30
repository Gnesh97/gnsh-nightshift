NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.Booking

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'idempotency_key', 'initiator_type', 'client_type', 'client_ref',
    'worker_type', 'worker_ref', 'client_profile_id', 'worker_profile_id',
    'npc_worker_id', 'service_package_id', 'mode', 'meeting_mode',
    'location_type', 'location_ref', 'location_id', 'quote_minor',
    'quote_currency', 'quoted_at', 'quote_id', 'quote_expires_at',
    'agreed_price_minor', 'agreed_currency', 'agreed_at', 'agreed_quote_id',
    'price_minor', 'currency', 'status', 'correlation_id',
    'external_reference', 'scheduled_at', 'started_at', 'ended_at',
    'completed_at', 'version', 'created_at', 'updated_at'
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

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function databaseTimestamp(value, field)
    if value == nil then return nil end
    if type(value) == 'number' then
        if not integer(value, 0) then return nil, invalid(field .. ' timestamp is invalid') end
        local ok, formatted = pcall(os.date, '!%Y-%m-%d %H:%M:%S.000', value)
        if not ok or type(formatted) ~= 'string' then return nil, invalid(field .. ' timestamp is invalid') end
        return formatted
    end
    if type(value) ~= 'string' or not text(value, 64) then return nil, invalid(field .. ' timestamp is invalid') end

    local date, clock, remainder = value:match('^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d:%d%d:%d%d)(.*)$')
    if not date or date == '0000-00-00' then return nil, invalid(field .. ' timestamp is invalid') end
    if remainder == '' or remainder == 'Z' then return date .. ' ' .. clock .. '.000' end

    local fraction = remainder:match('^%.(%d+)$') or remainder:match('^%.(%d+)Z$')
    if not fraction then return nil, invalid(field .. ' timestamp is invalid') end
    fraction = (fraction .. '000'):sub(1, 3)
    return date .. ' ' .. clock .. '.' .. fraction
end

local function normalizeSnapshot(value, field)
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a table') end
    local amount = integer(value.amountMinor or value.amount, 0, 100000000000)
    local currency = type(value.currency) == 'string' and value.currency:upper() or nil
    if not amount or not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid(field .. ' snapshot is invalid') end
    local quoteId = value.quoteId or value.quote_id
    if quoteId ~= nil and not text(quoteId, 128) then return nil, invalid(field .. ' quote ID is invalid') end
    local quotedAt, quotedError = databaseTimestamp(value.quotedAt or value.quoted_at, field .. '.quotedAt')
    if quotedError then return nil, quotedError end
    local agreedAt, agreedError = databaseTimestamp(value.agreedAt or value.agreed_at, field .. '.agreedAt')
    if agreedError then return nil, agreedError end
    local expiresAt, expiryError = databaseTimestamp(value.expiresAt or value.expires_at, field .. '.expiresAt')
    if expiryError then return nil, expiryError end
    return { amountMinor = amount, currency = currency, quotedAt = quotedAt, agreedAt = agreedAt, expiresAt = expiresAt, quoteId = quoteId }
end

local function safeTableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'booking repository requires a database adapter') end
    local tableName = options.tableName or 'nightshift_bookings'
    if not safeTableName(tableName) then return nil, invalid('booking repository table name is invalid') end
    local base, err = Base.new({
        db = database,
        tableName = tableName,
        columns = columns,
        mapper = function(row)
            local booking, bookingError = Domain.fromRow(row)
            if booking then return booking end

            local source = bookingError and bookingError.error or bookingError
            local details = source and source.details
            return Result.err(Codes.MAPPING_FAILED, 'booking row is invalid', {
                cause = source and source.code or nil,
                causeMessage = source and source.message or nil,
                causeDetails = type(details) == 'table' and details or nil
            })
        end
    })
    if not base then return nil, err end
    return setmetatable({ _base = base, _db = database, _table = tableName }, Repository)
end

function Repository:findById(id)
    local result = self._base:findById(id)
    if type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND then
        return Result.err(Codes.BOOKING_NOT_FOUND, 'booking was not found', { id = id })
    end
    return result
end

function Repository:findAll(options)
    return self._base:findAll(options)
end

function Repository:findByIdempotencyKey(key)
    if not text(key, 128) then return invalid('booking idempotency key is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE idempotency_key = ? LIMIT 1'):format(selectList, self._table)
    local result = self._db:single(sql, { key })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking was not found', { idempotencyKey = key }) end
    local booking, mapResult = self._base:_map(result.value)
    if not booking then return mapResult end
    return Result.ok(booking, { idempotencyKey = key })
end

function Repository:findByExternalReference(reference)
    if not text(reference, 160) then return invalid('booking external reference is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE external_reference = ? LIMIT 1'):format(selectList, self._table)
    local result = self._db:single(sql, { reference })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking was not found', { externalReference = reference }) end
    local booking, mapResult = self._base:_map(result.value)
    if not booking then return mapResult end
    return Result.ok(booking, { externalReference = reference })
end

function Repository:create(booking)
    local row, rowError = Domain.toRow(booking)
    if not row then return rowError end
    return self._base:create(row)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('booking changes must be a table') end
    local mapped, seen = {}, {}
    local aliases = {
        status = 'status', quote = 'quote', quote_snapshot = 'quote',
        agreedPrice = 'agreedPrice', agreed_price = 'agreedPrice', agreed_price_snapshot = 'agreedPrice',
        scheduledAt = 'scheduledAt', scheduled_at = 'scheduledAt',
        startAt = 'startAt', start_at = 'startAt', started_at = 'startAt',
        endAt = 'endAt', end_at = 'endAt', ended_at = 'endAt',
        completedAt = 'completedAt', completed_at = 'completedAt',
        correlationId = 'correlationId', correlation_id = 'correlationId',
        externalReference = 'externalReference', external_reference = 'externalReference',
        meetingMode = 'meetingMode', meeting_mode = 'meetingMode',
        locationType = 'locationType', location_type = 'locationType',
        locationRef = 'locationRef', location_ref = 'locationRef'
    }
    local immutable = { id = true, idempotencyKey = true, clientType = true, clientRef = true, workerType = true, workerRef = true, initiatorType = true, servicePackage = true, servicePackageId = true, version = true }
    for key, value in pairs(changes) do
        if immutable[key] then return invalid('booking field is immutable', { field = tostring(key) }) end
        local field = aliases[key]
        if not field then return invalid('booking field is not mutable', { field = tostring(key) }) end
        if seen[field] then return invalid('booking field was supplied more than once', { field = field }) end
        seen[field] = true
        if field == 'status' then
            if type(value) ~= 'string' or not Domain.statuses[value:upper()] then return invalid('booking status is invalid') end
            mapped.status = value:upper()
        elseif field == 'quote' or field == 'agreedPrice' then
            local snapshot, snapshotError = value == nil and nil or normalizeSnapshot(value, field)
            if snapshotError then return snapshotError end
            if field == 'quote' then
                mapped.quote_minor = snapshot and snapshot.amountMinor or nil
                mapped.quote_currency = snapshot and snapshot.currency or nil
                mapped.quoted_at = snapshot and snapshot.quotedAt or nil
                mapped.quote_id = snapshot and snapshot.quoteId or nil
                mapped.quote_expires_at = snapshot and snapshot.expiresAt or nil
            else
                mapped.agreed_price_minor = snapshot and snapshot.amountMinor or nil
                mapped.agreed_currency = snapshot and snapshot.currency or nil
                mapped.agreed_at = snapshot and snapshot.agreedAt or nil
                mapped.agreed_quote_id = snapshot and snapshot.quoteId or nil
                if snapshot then mapped.price_minor, mapped.currency = snapshot.amountMinor, snapshot.currency end
            end
        elseif field == 'meetingMode' then
            if type(value) ~= 'string' or value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') == nil then return invalid('meeting mode is invalid') end
            mapped.mode, mapped.meeting_mode = value, value
        elseif field == 'locationType' then
            if value ~= nil and (type(value) ~= 'string' or value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') == nil) then return invalid('location type is invalid') end
            mapped.location_type = value
        elseif field == 'locationRef' or field == 'correlationId' or field == 'externalReference' then
            if value ~= nil and not text(value, field == 'correlationId' and 96 or 160) then return invalid(field .. ' is invalid') end
            mapped[field == 'locationRef' and 'location_ref' or field == 'correlationId' and 'correlation_id' or 'external_reference'] = value
        else
            local timestamp, timestampError = databaseTimestamp(value, field)
            if timestampError then return nil, timestampError end
            mapped[field == 'scheduledAt' and 'scheduled_at' or field == 'startAt' and 'started_at' or field == 'endAt' and 'ended_at' or 'completed_at'] = timestamp
        end
    end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
Repository.findByID = Repository.findById
Repository.findByKey = Repository.findByIdempotencyKey
NightShift.Repositories.Booking = Repository
NightShift.Repositories.Bookings = Repository
