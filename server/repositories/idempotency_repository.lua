NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'scope', 'idempotency_key', 'fingerprint', 'status',
    'result_json', 'created_at', 'updated_at', 'expires_at', 'version'
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

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function identifier(value)
    return text(value, 96) and value:match('^[%w%._:%-]+$') ~= nil
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function encode(value)
    if value == nil then return nil end
    local json = rawget(_G, 'json')
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then
        return nil, invalid('idempotency result requires a JSON encoder')
    end
    local ok, encoded = pcall(json.encode, value)
    if not ok or type(encoded) ~= 'string' or #encoded > 65535 then
        return nil, invalid('idempotency result cannot be serialized')
    end
    return encoded
end

local function decode(value)
    if value == nil then return nil end
    if type(value) ~= 'string' then return copy(value) end
    local json = rawget(_G, 'json')
    if type(json) == 'table' and type(json.decode) == 'function' then
        local ok, decoded = pcall(json.decode, value)
        if ok then return decoded end
    end
    return nil
end

local function timestamp(value, field)
    if type(value) == 'number' then
        if not integer(value, 0) then return nil, invalid(field .. ' is invalid') end
        return os.date('!%Y-%m-%d %H:%M:%S', value) .. '.000'
    end
    if not text(value, 80) then return nil, invalid(field .. ' is invalid') end
    local date, clock, fraction = value:match('^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d:%d%d:%d%d)%.?(%d*)Z?$')
    if not date then
        date, clock, fraction = value:match('^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)%.?(%d*)Z?$')
    end
    if not date then return nil, invalid(field .. ' is invalid') end
    fraction = ((fraction or '') .. '000'):sub(1, 3)
    return date .. ' ' .. clock .. '.' .. fraction
end

local function mapRow(row)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'idempotency row is not a table') end
    local scope = row.scope
    local key = row.idempotency_key or row.idempotencyKey
    local digest = row.fingerprint
    local status = tostring(row.status or ''):upper()
    if not identifier(scope) or not text(key, 160) or key:match('^[%w%._:%-/]+$') == nil
        or not text(digest, 32) or (status ~= 'PENDING' and status ~= 'COMPLETED') then
        return nil, Result.err(Codes.MAPPING_FAILED, 'idempotency row is invalid')
    end
    return {
        id = row.id,
        scope = scope,
        key = key,
        fingerprint = digest,
        status = status,
        value = decode(row.result_json or row.result),
        createdAt = row.created_at or row.createdAt,
        updatedAt = row.updated_at or row.updatedAt,
        expiresAt = row.expires_at or row.expiresAt,
        version = integer(row.version, 1, 2147483647) or 1
    }
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'idempotency repository requires a database adapter') end
    local tableName = options.tableName or 'nightshift_idempotency'
    if not text(tableName, 96) or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then
        return nil, invalid('idempotency repository table name is invalid') end
    local base, baseError = Base.new({ db = db, tableName = tableName, columns = columns, mapper = mapRow })
    if not base then return nil, baseError end
    return setmetatable({ _base = base, _db = db, _table = tableName }, Repository)
end

function Repository:findByKey(scope, key)
    if not identifier(scope) then return invalid('idempotency scope is invalid') end
    if not text(key, 160) or key:match('^[%w%._:%-/]+$') == nil then return invalid('idempotency key is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:single(('SELECT %s FROM %s WHERE scope = ? AND idempotency_key = ? LIMIT 1'):format(selectList, self._table), { scope, key })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'idempotency entry was not found') end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

Repository.findByIdempotencyKey = Repository.findByKey

function Repository:create(entry)
    if type(entry) ~= 'table' or not identifier(entry.scope) or not text(entry.key, 160)
        or entry.key:match('^[%w%._:%-/]+$') == nil then return invalid('idempotency entry key is invalid') end
    if not text(entry.fingerprint, 32) then return invalid('idempotency fingerprint is invalid') end
    local status = tostring(entry.status or ''):upper()
    if status ~= 'PENDING' and status ~= 'COMPLETED' then return invalid('idempotency status is invalid') end
    local resultJson, resultError = encode(entry.value)
    if resultError then return resultError end
    local createdAt, createdError = timestamp(entry.createdAt, 'idempotency createdAt')
    if createdError then return createdError end
    local updatedAt, updatedError = timestamp(entry.updatedAt or entry.createdAt, 'idempotency updatedAt')
    if updatedError then return updatedError end
    local expiresAt, expiresError = timestamp(entry.expiresAt, 'idempotency expiresAt')
    if expiresError then return expiresError end
    if type(self._db.insert) ~= 'function' then return Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'idempotency database insert capability is unavailable') end
    local sql = ('INSERT INTO %s (scope, idempotency_key, fingerprint, status, result_json, created_at, updated_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'):format(self._table)
    local result = self._db:insert(sql, {
        entry.scope, entry.key, entry.fingerprint, status, resultJson,
        createdAt, updatedAt, expiresAt
    })
    if type(result) ~= 'table' or result.ok ~= true then return result end
    return Result.ok(result.value)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('idempotency changes are invalid') end
    local mapped = {}
    if changes.status ~= nil then
        local status = tostring(changes.status):upper()
        if status ~= 'PENDING' and status ~= 'COMPLETED' then return invalid('idempotency status is invalid') end
        mapped.status = status
    end
    if changes.value ~= nil then
        local encoded, encodeError = encode(changes.value)
        if encodeError then return encodeError end
        mapped.result_json = encoded
    end
    if changes.expiresAt ~= nil then
        local expiresAt, expiresError = timestamp(changes.expiresAt, 'idempotency expiresAt')
        if expiresError then return expiresError end
        mapped.expires_at = expiresAt
    end
    if next(mapped) == nil then return invalid('idempotency changes must not be empty') end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

function Repository:deleteExpired(now, limit)
    if not integer(now, 0) then return invalid('idempotency purge timestamp is invalid') end
    limit = integer(limit or 200, 1, 1000)
    if not limit then return invalid('idempotency purge limit is invalid') end
    if type(self._db.update) ~= 'function' then return Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'idempotency database update capability is unavailable') end
    local value = os.date('!%Y-%m-%d %H:%M:%S', now) .. '.000'
    local result = self._db:update(('DELETE FROM %s WHERE expires_at <= ? LIMIT ?'):format(self._table), { value, limit })
    if type(result) ~= 'table' or not result.ok then return result end
    return Result.ok({ deleted = tonumber(result.value and result.value.affectedRows) or 0 })
end

Repository.get = Repository.findByKey
NightShift.Repositories.Idempotency = Repository
NightShift.Repositories.Idempotencies = Repository
