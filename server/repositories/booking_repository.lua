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

local function normalizedStatuses(values)
    if values == nil then return nil end
    if type(values) ~= 'table' or #values == 0 or #values > 16 then return nil, invalid('booking status filter is invalid') end
    local output = {}
    for index, value in ipairs(values) do
        if type(value) ~= 'string' then return nil, invalid('booking status filter is invalid', { index = index }) end
        local status = value:upper()
        if not Domain.statuses[status] or status:match('^[A-Z_]+$') == nil then return nil, invalid('booking status filter is invalid', { index = index }) end
        output[index] = status
    end
    return output
end

function Repository:findForClient(client, options)
    if type(client) ~= 'table' then return invalid('booking client scope is invalid') end
    options = options or {}
    if type(options) ~= 'table' then return invalid('booking client query options must be a table') end

    local rawProfileId = client.clientProfileId or client.profileId
    local profileId = rawProfileId == nil and nil or integer(rawProfileId, 1, 2147483647)
    if rawProfileId ~= nil and not profileId then return invalid('booking client profile ID is invalid') end
    local clientRef = client.clientRef or client.identityKey or client.key
    if clientRef ~= nil and not text(clientRef, 160) then return invalid('booking client reference is invalid') end
    if profileId == nil and clientRef == nil then return invalid('booking client scope requires a profile ID or reference') end

    local limit = options.limit == nil and 50 or integer(options.limit, 1, 100)
    local offset = options.offset == nil and 0 or integer(options.offset, 0)
    if not limit then return invalid('repository limit is invalid') end
    if not offset then return invalid('repository offset is invalid') end
    local order = options.order == nil and 'ASC' or type(options.order) == 'string' and options.order:upper() or nil
    if order ~= 'ASC' and order ~= 'DESC' then return invalid('booking query order is invalid') end
    local orderBy = options.orderBy == nil and 'scheduled' or options.orderBy
    if orderBy ~= 'scheduled' and orderBy ~= 'history' then return invalid('booking query order field is invalid') end
    local statuses, statusError = normalizedStatuses(options.statuses)
    if statusError then return statusError end

    local predicates, predicateParams = {}, {}
    if profileId ~= nil then
        predicates[#predicates + 1] = 'client_profile_id = ?'
        predicateParams[#predicateParams + 1] = profileId
    end
    if clientRef ~= nil then
        predicates[#predicates + 1] = '(client_type = ? AND client_ref = ?)'
        predicateParams[#predicateParams + 1] = 'PLAYER'
        predicateParams[#predicateParams + 1] = clientRef
    end
    local scope = #predicates == 1 and predicates[1] or '(' .. table.concat(predicates, ' OR ') .. ')'
    local where = { scope }
    local whereParams = copy(predicateParams)
    if statuses then
        local placeholders = {}
        for _, status in ipairs(statuses) do
            placeholders[#placeholders + 1] = '?'
            whereParams[#whereParams + 1] = status
        end
        where[#where + 1] = 'status IN (' .. table.concat(placeholders, ', ') .. ')'
    end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sortColumn = orderBy == 'history' and 'COALESCE(completed_at, updated_at, created_at)' or 'COALESCE(scheduled_at, created_at)'
    local whereSql = table.concat(where, ' AND ')
    local listParams = copy(whereParams)
    listParams[#listParams + 1] = limit
    listParams[#listParams + 1] = offset
    local sql = ('SELECT %s FROM %s WHERE %s ORDER BY %s %s, id %s LIMIT ? OFFSET ?'):format(selectList, self._table, whereSql, sortColumn, order, order)
    local result = self._db:query(sql, listParams)
    if type(result) ~= 'table' or not result.ok then return result end
    local rows = result.value or {}
    if type(rows) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'booking query rows are invalid') end
    local mapped = {}
    for index, row in ipairs(rows) do
        local value, mapResult = self._base:_map(row)
        if not value then return mapResult end
        mapped[index] = value
    end

    local countSql = ('SELECT COUNT(*) AS total FROM %s WHERE %s'):format(self._table, whereSql)
    local countResult = self._db:scalar(countSql, whereParams)
    if type(countResult) ~= 'table' or not countResult.ok then return countResult end
    local totalValue = countResult.value
    if type(totalValue) == 'table' then totalValue = totalValue.total or totalValue[1] end
    local total = tonumber(totalValue)
    if not total or total < 0 or math.floor(total) ~= total then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'booking query count is invalid') end
    return Result.ok({ items = mapped, total = total, limit = limit, offset = offset }, { order = order, orderBy = orderBy })
end

Repository.findByClient = Repository.findForClient

local function mapRows(repository, result, message)
    if type(result) ~= 'table' or not result.ok then return result end
    local rows = result.value or {}
    if type(rows) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, message or 'booking query rows are invalid') end
    local mapped = {}
    for index, row in ipairs(rows) do
        local value, mapResult = repository._base:_map(row)
        if not value then return mapResult end
        mapped[index] = value
    end
    return Result.ok(mapped)
end

local function dueOptions(options, field, defaultValue)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('booking due query options must be a table') end
    local limit = options.limit == nil and 50 or integer(options.limit, 1, 100)
    if not limit then return nil, invalid('repository limit is invalid') end
    local seconds = options[field]
    seconds = seconds == nil and defaultValue or integer(seconds, 0, 604800)
    if seconds == nil then return nil, invalid(('booking %s is invalid'):format(field)) end
    return { limit = limit, seconds = seconds }
end

local function queryEpoch(value, field)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then
        return nil, invalid(field .. ' timestamp is invalid')
    end
    return math.floor(value)
end

function Repository:findDueScheduled(now, options)
    local settings, settingsError = dueOptions(options, 'leadTimeSeconds', 0)
    if not settings then return settingsError end
    local epoch, epochError = queryEpoch(now == nil and os.time() or now, 'due')
    if not epoch then return epochError end
    local boundary, boundaryError = databaseTimestamp(epoch + settings.seconds, 'scheduledAt')
    if not boundary then return boundaryError end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE status = ? AND scheduled_at IS NOT NULL AND scheduled_at <= ? ORDER BY scheduled_at ASC, id ASC LIMIT ?'):format(selectList, self._table)
    local result = self._db:query(sql, { 'SCHEDULED', boundary, settings.limit })
    return mapRows(self, result, 'scheduled due query rows are invalid')
end

function Repository:findDueArrived(now, options)
    local settings, settingsError = dueOptions(options, 'graceSeconds', 300)
    if not settings then return settingsError end
    local epoch, epochError = queryEpoch(now == nil and os.time() or now, 'due')
    if not epoch then return epochError end
    local cutoff = math.max(0, epoch - settings.seconds)
    local boundary, boundaryError = databaseTimestamp(cutoff, 'arrival')
    if not boundary then return boundaryError end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE status = ? AND updated_at IS NOT NULL AND updated_at <= ? ORDER BY updated_at ASC, id ASC LIMIT ?'):format(selectList, self._table)
    local result = self._db:query(sql, { 'ARRIVED', boundary, settings.limit })
    return mapRows(self, result, 'arrived due query rows are invalid')
end

Repository.findDueNoShow = Repository.findDueArrived

function Repository:findScheduleCandidates(booking, options)
    if type(booking) ~= 'table' then return invalid('schedule candidate booking is invalid') end
    options = options or {}
    if type(options) ~= 'table' then return invalid('schedule candidate options must be a table') end
    local workerRef = booking.workerRef
    local locationRef = booking.locationRef
    local hasWorker = text(workerRef, 160)
    local hasLocation = text(locationRef, 160)
    if not hasWorker and not hasLocation then return Result.ok({}) end
    local limit = options.limit == nil and 100 or integer(options.limit, 1, 200)
    if not limit then return invalid('schedule candidate limit is invalid') end
    local predicates, parameters = {}, {}
    if booking.id ~= nil then
        local id = integer(booking.id, 1, 2147483647) or (text(booking.id, 160) and booking.id)
        if id ~= nil then
            predicates[#predicates + 1] = 'id <> ?'
            parameters[#parameters + 1] = id
        end
    end
    local statuses = { 'SCHEDULED', 'RESERVED', 'TRAVELLING', 'ARRIVED', 'ACTIVE' }
    local placeholders = {}
    for _, status in ipairs(statuses) do
        placeholders[#placeholders + 1] = '?'
        parameters[#parameters + 1] = status
    end
    predicates[#predicates + 1] = 'status IN (' .. table.concat(placeholders, ', ') .. ')'
    local resources = {}
    if hasWorker then
        resources[#resources + 1] = '(worker_type = ? AND worker_ref = ?)'
        parameters[#parameters + 1] = type(booking.workerType) == 'string' and booking.workerType:upper() or 'PLAYER'
        parameters[#parameters + 1] = workerRef
    end
    if hasLocation then
        resources[#resources + 1] = 'location_ref = ?'
        parameters[#parameters + 1] = locationRef
    end
    predicates[#predicates + 1] = '(' .. table.concat(resources, ' OR ') .. ')'
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE %s ORDER BY scheduled_at ASC, id ASC LIMIT ?'):format(selectList, self._table, table.concat(predicates, ' AND '))
    parameters[#parameters + 1] = limit
    local result = self._db:query(sql, parameters)
    return mapRows(self, result, 'schedule candidate query rows are invalid')
end

Repository.findForSchedule = Repository.findScheduleCandidates

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

function Repository:findByQuoteId(quoteId)
    if not text(quoteId, 128) then return invalid('booking quote ID is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    -- A quote ID should be unique, but do not silently pick an arbitrary row
    -- if legacy data or a missing DB constraint violates that invariant.
    local sql = ('SELECT %s FROM %s WHERE quote_id = ? OR agreed_quote_id = ? LIMIT 2'):format(selectList, self._table)
    local result = self._db:query(sql, { quoteId, quoteId })
    if type(result) ~= 'table' or not result.ok then return result end
    local rows = result.value or {}
    if type(rows) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'booking quote lookup rows are invalid') end
    if #rows == 0 then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking was not found') end
    if #rows > 1 then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'booking quote ID is not unique') end
    local booking, mapResult = self._base:_map(rows[1])
    if not booking then return mapResult end
    return Result.ok(booking, { quoteId = quoteId })
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
