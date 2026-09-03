NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'actor_source', 'actor_type', 'actor_ref', 'action',
    'target_type', 'target_ref', 'result_status', 'result_code',
    'reason', 'correlation_id', 'metadata_json', 'occurred_at', 'created_at'
}

local resultStatuses = { OK = true, ERROR = true, UNKNOWN = true }

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
    return type(value) == 'string' and value:match('%S') ~= nil
        and #value <= (maxLength or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or math.floor(value) ~= value then return nil end
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
        local ok, formatted = pcall(os.date, '!%Y-%m-%d %H:%M:%S', value)
        if not ok or type(formatted) ~= 'string' then return nil, invalid(field .. ' timestamp is invalid') end
        return formatted .. '.000'
    end
    if type(value) ~= 'string' or not text(value, 80) then
        return nil, invalid(field .. ' timestamp is invalid')
    end
    local date, clock, fraction = value:match('^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d:%d%d:%d%d)%.?(%d*)Z?$')
    if not date or date == '0000-00-00' then return nil, invalid(field .. ' timestamp is invalid') end
    fraction = fraction or ''
    fraction = (fraction .. '000'):sub(1, 3)
    return date .. ' ' .. clock .. '.' .. fraction
end

local function encode(value)
    if value == nil then return nil end
    if type(value) == 'string' then
        if #value > 16384 then return nil, invalid('audit metadata is too long') end
        return value
    end
    local json = rawget(_G, 'json')
    if type(json) == 'table' and type(json.encode) == 'function' then
        local ok, output = pcall(json.encode, value)
        if ok and type(output) == 'string' and #output <= 16384 then return output end
    end
    return nil, invalid('audit metadata cannot be serialized')
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
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'audit row is not a table') end
    local status = tostring(row.result_status or row.resultStatus or 'UNKNOWN'):upper()
    if not resultStatuses[status] then return nil, Result.err(Codes.MAPPING_FAILED, 'audit result status is invalid') end
    local action = row.action
    if not text(action, 96) then return nil, Result.err(Codes.MAPPING_FAILED, 'audit action is invalid') end
    return {
        id = row.id,
        actorSource = row.actor_source or row.actorSource,
        actorType = row.actor_type or row.actorType,
        actorRef = row.actor_ref or row.actorRef,
        action = action,
        targetType = row.target_type or row.targetType,
        targetRef = row.target_ref or row.targetRef,
        resultStatus = status,
        resultCode = row.result_code or row.resultCode,
        reason = row.reason,
        correlationId = row.correlation_id or row.correlationId,
        metadata = decode(row.metadata_json or row.metadata),
        occurredAt = row.occurred_at or row.occurredAt,
        createdAt = row.created_at or row.createdAt
    }
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then
        return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'audit repository requires a database adapter')
    end
    local tableName = options.tableName or 'nightshift_audit_log'
    if type(tableName) ~= 'string' or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then
        return nil, invalid('audit repository table name is invalid')
    end
    local base, baseError = Base.new({
        db = database, tableName = tableName, columns = columns, mapper = mapRow
    })
    if not base then return nil, baseError end
    return setmetatable({ _base = base, _db = database, _table = tableName }, Repository)
end

function Repository:create(event)
    if type(event) ~= 'table' or not text(event.action, 96) then
        return invalid('audit event action is required')
    end
    local status = tostring(event.resultStatus or 'UNKNOWN'):upper()
    if not resultStatuses[status] then return invalid('audit result status is invalid') end
    local actorSource = event.actorSource
    if actorSource ~= nil and not integer(actorSource, 1, 2147483647) then
        return invalid('audit actor source is invalid')
    end
    local metadata, metadataError = encode(event.metadata)
    if metadataError then return metadataError end
    local occurredAt, timestampError = databaseTimestamp(event.occurredAt, 'audit occurredAt')
    if timestampError then return timestampError end
    local row = {
        actor_source = actorSource,
        actor_type = event.actorType,
        actor_ref = event.actorRef,
        action = event.action,
        target_type = event.targetType,
        target_ref = event.targetRef,
        result_status = status,
        result_code = event.resultCode,
        reason = event.reason,
        correlation_id = event.correlationId,
        metadata_json = metadata,
        occurred_at = occurredAt
    }
    if type(self._db.insert) ~= 'function' then
        return Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'audit database insert capability is unavailable')
    end
    return self._base:create(row)
end

function Repository:findRecent(options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('audit query options must be a table') end
    local limit = integer(options.limit == nil and 100 or options.limit, 1, 500)
    local offset = integer(options.offset == nil and 0 or options.offset, 0)
    if not limit or not offset then return invalid('audit pagination is invalid') end
    local predicates, parameters = {}, {}
    local since, sinceError = databaseTimestamp(options.since or options.from, 'audit since')
    if sinceError then return sinceError end
    local untilValue, untilError = databaseTimestamp(options['until'] or options.to, 'audit until')
    if untilError then return untilError end
    if since then predicates[#predicates + 1] = 'occurred_at >= ?'; parameters[#parameters + 1] = since end
    if untilValue then predicates[#predicates + 1] = 'occurred_at < ?'; parameters[#parameters + 1] = untilValue end
    if since and untilValue and since >= untilValue then return invalid('audit time range is invalid') end
    if options.action ~= nil then
        if not text(options.action, 96) then return invalid('audit action filter is invalid') end
        predicates[#predicates + 1] = 'action = ?'; parameters[#parameters + 1] = options.action
    end
    if options.targetType ~= nil then
        if not text(options.targetType, 64) then return invalid('audit target type filter is invalid') end
        predicates[#predicates + 1] = 'target_type = ?'; parameters[#parameters + 1] = options.targetType
    end
    if options.resultStatus ~= nil then
        local status = tostring(options.resultStatus):upper()
        if not resultStatuses[status] then return invalid('audit result status filter is invalid') end
        predicates[#predicates + 1] = 'result_status = ?'; parameters[#parameters + 1] = status
    end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    if type(self._db.query) ~= 'function' then
        return Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'audit database query capability is unavailable')
    end
    local where = #predicates > 0 and (' WHERE ' .. table.concat(predicates, ' AND ')) or ''
    parameters[#parameters + 1] = limit
    parameters[#parameters + 1] = offset
    local sql = ('SELECT %s FROM %s%s ORDER BY id DESC LIMIT ? OFFSET ?'):format(selectList, self._table, where)
    local result = self._db:query(sql, parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    if type(result.value) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'audit rows are invalid') end
    local output = {}
    for index, row in ipairs(result.value) do
        local value, mapError = self._base:_map(row)
        if not value then return mapError end
        output[index] = value
    end
    return Result.ok(output, { limit = limit, offset = offset })
end

Repository.list = Repository.findRecent
NightShift.Repositories.Audit = Repository
NightShift.Repositories.AuditLog = Repository
