NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Repositories = NightShift.Repositories or {}
local Base = {}
Base.__index = Base

local reserved = { id = true, version = true, created_at = true, updated_at = true }

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function validIdentifier(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

local function quoteIdentifier(value)
    return '`' .. value .. '`'
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function validId(value)
    if type(value) == 'number' then
        return value >= 1 and value == value and value ~= math.huge and value ~= -math.huge and math.floor(value) == value
    end
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function sortedFields(values, allowReserved)
    if type(values) ~= 'table' then return nil, invalid('repository values must be a table') end
    local fields = {}
    for key in pairs(values) do
        if not validIdentifier(key) or (not allowReserved and reserved[key]) then
            return nil, invalid('repository field is not allowlisted', { field = tostring(key) })
        end
        fields[#fields + 1] = key
    end
    table.sort(fields)
    if #fields == 0 then return nil, invalid('repository values must not be empty') end
    return fields
end

local function mapError(message, details)
    return Result.err(Codes.MAPPING_FAILED, message, details)
end

function Base.new(options)
    options = options or {}
    local db = options.db
    local tableName = options.tableName or options.table
    local idColumn = options.idColumn or 'id'
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'repository requires a database adapter') end
    if not validIdentifier(tableName) or not validIdentifier(idColumn) then
        return nil, invalid('repository table and ID column must be safe identifiers')
    end
    if type(options.mapper) ~= 'nil' and type(options.mapper) ~= 'function' then
        return nil, invalid('repository mapper must be a function')
    end
    return setmetatable({
        _db = db,
        _table = tableName,
        _idColumn = idColumn,
        _mapper = options.mapper or function(row) return row end,
        _columns = options.columns
    }, Base)
end

function Base:_selectList()
    if self._columns == nil then return '*' end
    if type(self._columns) ~= 'table' then return nil, invalid('repository columns must be an array') end
    local output = {}
    for index, column in ipairs(self._columns) do
        if not validIdentifier(column) then return nil, invalid('repository column is not a safe identifier', { index = index }) end
        output[#output + 1] = quoteIdentifier(column)
    end
    if #output == 0 then return nil, invalid('repository columns must not be empty') end
    return table.concat(output, ', ')
end

function Base:_map(row)
    if type(row) ~= 'table' then return nil, mapError('database row is not a table') end
    local ok, mapped = pcall(self._mapper, copy(row))
    if not ok or mapped == nil then return nil, mapError('repository row mapper failed') end
    if type(mapped) == 'table' and mapped.ok ~= nil then
        if mapped.ok ~= true then return nil, mapError('repository row mapper returned an error', { cause = mapped.error and mapped.error.code }) end
        mapped = mapped.value
    end
    if type(mapped) ~= 'table' then return nil, mapError('repository row mapper must return a table') end
    return copy(mapped)
end

function Base:findById(id)
    if not validId(id) then return invalid('repository ID is invalid', { field = self._idColumn }) end
    local columns, columnError = self:_selectList()
    if not columns then return columnError end
    local sql = ('SELECT %s FROM %s WHERE %s = ? LIMIT 1'):format(columns, quoteIdentifier(self._table), quoteIdentifier(self._idColumn))
    local result = self._db:single(sql, { id })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'repository row was not found', { id = id }) end
    local mapped, mapResult = self:_map(result.value)
    if not mapped then return mapResult end
    return Result.ok(mapped, { id = id })
end

function Base:findAll(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return invalid('repository findAll options must be a table') end
    local limit = options.limit == nil and 100 or tonumber(options.limit)
    local offset = options.offset == nil and 0 or tonumber(options.offset)
    if not limit or limit < 1 or limit > 1000 or math.floor(limit) ~= limit then return invalid('repository limit is invalid') end
    if not offset or offset < 0 or math.floor(offset) ~= offset then return invalid('repository offset is invalid') end
    local columns, columnError = self:_selectList()
    if not columns then return columnError end
    local sql = ('SELECT %s FROM %s ORDER BY %s ASC LIMIT ? OFFSET ?'):format(columns, quoteIdentifier(self._table), quoteIdentifier(self._idColumn))
    local result = self._db:query(sql, { limit, offset })
    if type(result) ~= 'table' or not result.ok then return result end
    local rows = result.value or {}
    if type(rows) ~= 'table' then return mapError('database rows are not an array') end
    local mapped = {}
    for index, row in ipairs(rows) do
        local value, mapResult = self:_map(row)
        if not value then return mapResult end
        mapped[index] = value
    end
    return Result.ok(mapped, { limit = limit, offset = offset })
end

function Base:create(values)
    local fields, fieldError = sortedFields(values, false)
    if not fields then return fieldError end
    local names, placeholders, parameters = {}, {}, {}
    for _, field in ipairs(fields) do
        names[#names + 1] = quoteIdentifier(field)
        placeholders[#placeholders + 1] = '?'
        parameters[#parameters + 1] = values[field]
    end
    local sql = ('INSERT INTO %s (%s) VALUES (%s)'):format(quoteIdentifier(self._table), table.concat(names, ', '), table.concat(placeholders, ', '))
    local result = self._db:insert(sql, parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    return Result.ok(copy(result.value), { operation = 'create', table = self._table })
end

function Base:_exists(id)
    local sql = ('SELECT 1 AS present FROM %s WHERE %s = ? LIMIT 1'):format(quoteIdentifier(self._table), quoteIdentifier(self._idColumn))
    local result = self._db:scalar(sql, { id })
    if type(result) ~= 'table' or not result.ok then return nil, result end
    return result.value ~= nil and result.value ~= false
end

function Base:updateExpectedVersion(id, expectedVersion, changes)
    if not validId(id) then return invalid('repository ID is invalid', { field = self._idColumn }) end
    expectedVersion = tonumber(expectedVersion)
    if not expectedVersion or expectedVersion < 1 or math.floor(expectedVersion) ~= expectedVersion then
        return invalid('expected version is invalid')
    end
    local fields, fieldError = sortedFields(changes, false)
    if not fields then return fieldError end
    local assignments, parameters = {}, {}
    for _, field in ipairs(fields) do
        assignments[#assignments + 1] = quoteIdentifier(field) .. ' = ?'
        parameters[#parameters + 1] = changes[field]
    end
    assignments[#assignments + 1] = 'version = version + 1'
    assignments[#assignments + 1] = 'updated_at = CURRENT_TIMESTAMP(3)'
    parameters[#parameters + 1] = id
    parameters[#parameters + 1] = expectedVersion
    local sql = ('UPDATE %s SET %s WHERE %s = ? AND version = ?'):format(quoteIdentifier(self._table), table.concat(assignments, ', '), quoteIdentifier(self._idColumn))
    local result = self._db:update(sql, parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local affected = tonumber(result.value and result.value.affectedRows) or 0
    if affected > 0 then return Result.ok({ id = id, version = expectedVersion + 1, affectedRows = affected }) end
    local exists, existsResult = self:_exists(id)
    if exists == nil then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'row existence could not be verified', { id = id, cause = existsResult and existsResult.error and existsResult.error.code }) end
    if not exists then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'repository row was not found', { id = id }) end
    return Result.err(Codes.VERSION_CONFLICT, 'repository row version does not match', { id = id, expectedVersion = expectedVersion })
end

Base.update = Base.updateExpectedVersion
Base.findByID = Base.findById

Repositories.Base = Base
NightShift.Repositories = Repositories
