NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.Deposit

local Repository = {}
Repository.__index = Repository

local columns = { 'id', 'booking_id', 'idempotency_key', 'amount_minor', 'currency', 'status', 'provider_reference', 'version', 'created_at', 'updated_at' }

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

local function tableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'deposit repository requires a database adapter') end
    local name = options.tableName or 'nightshift_booking_deposits'
    if not tableName(name) then return nil, invalid('deposit repository table name is invalid') end
    local base, errorResult = Base.new({ db = db, tableName = name, columns = columns, mapper = function(row)
        local deposit, mapError = Domain.fromRow(row)
        if not deposit then return Result.err(Codes.MAPPING_FAILED, 'deposit row is invalid', { cause = mapError and mapError.error and mapError.error.code }) end
        return deposit
    end })
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = db, _table = name }, Repository)
end

function Repository:_find(field, value)
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM %s WHERE %s = ? LIMIT 1'):format(selectList, self._table, field)
    local result = self._db:single(sql, { value })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'deposit was not found', { [field] = value }) end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:findById(id)
    if not integer(id, 1) then return invalid('deposit ID is invalid') end
    return self:_find('id', id)
end

function Repository:findByBooking(bookingId, options)
    if not integer(bookingId, 1) and not text(bookingId, 160) then return invalid('deposit booking ID is invalid') end
    options = options or {}
    local limit = integer(options.limit or 100, 1)
    local offset = integer(options.offset or 0, 0)
    if not limit or limit > 1000 or not offset then return invalid('deposit pagination is invalid') end
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

function Repository:findByIdempotencyKey(key)
    if not text(key, 128) then return invalid('deposit idempotency key is invalid') end
    return self:_find('idempotency_key', key)
end

Repository.findByKey = Repository.findByIdempotencyKey

function Repository:create(value)
    local row, errorResult = Domain.toRow(value)
    if not row then return errorResult end
    return self._base:create(row)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('deposit changes must be a table') end
    local allowed = { status = 'status', providerReference = 'providerReference', provider_reference = 'providerReference' }
    local mapped, seen = {}, {}
    for key, value in pairs(changes) do
        local field = allowed[key]
        if not field or seen[field] then return invalid('deposit field is not mutable', { field = tostring(key) }) end
        seen[field] = true
        if field == 'status' then
            if type(value) ~= 'string' or not Domain.statuses[value:upper()] then return invalid('deposit status is invalid') end
            mapped.status = value:upper()
        elseif field == 'providerReference' then
            if value ~= nil and not text(value, 128) then return invalid('deposit provider reference is invalid') end
            mapped.provider_reference = value
        end
    end
    if next(mapped) == nil then return invalid('deposit changes must not be empty') end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
NightShift.Repositories.Deposit = Repository
NightShift.Repositories.Deposits = Repository
