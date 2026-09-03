NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = { 'id', 'booking_id', 'idempotency_key', 'payment_type', 'amount_minor', 'currency', 'status', 'provider_reference', 'commission_snapshot', 'version', 'created_at', 'updated_at' }
local statuses = { PENDING = true, SUCCEEDED = true, COMMITTED = true, DECLINED = true, FAILED = true, UNKNOWN = true, REVERSED = true, REFUNDED = true }

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

local function tableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

local function encodeSnapshot(value)
    if value == nil then return nil end
    if type(value) == 'string' then return value end
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then return nil end
    local ok, encoded = pcall(json.encode, value)
    return ok and type(encoded) == 'string' and encoded or nil
end

local function decodeSnapshot(value)
    if type(value) ~= 'string' or value == '' or type(json) ~= 'table' or type(json.decode) ~= 'function' then return nil end
    local ok, decoded = pcall(json.decode, value)
    return ok and type(decoded) == 'table' and decoded or nil
end

local function normalize(value)
    if type(value) ~= 'table' then return nil, invalid('payment must be a table') end
    local bookingId = value.bookingId or value.booking_id
    if not integer(bookingId, 1) and not text(bookingId, 160) then return nil, invalid('payment booking ID is required') end
    local key = value.idempotencyKey or value.idempotency_key
    if not text(key, 128) then return nil, invalid('payment idempotency key is required') end
    local paymentType = value.paymentType or value.payment_type
    if not text(paymentType, 32) then return nil, invalid('payment type is required') end
    local amount = integer(value.amountMinor or value.amount_minor or value.amount, 0, 100000000000)
    if amount == nil then return nil, invalid('payment amount is invalid') end
    local currency = type(value.currency) == 'string' and value.currency:upper() or nil
    if not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('payment currency is invalid') end
    local status = type(value.status) == 'string' and value.status:upper() or 'PENDING'
    if not statuses[status] then return nil, invalid('payment status is invalid') end
    local version = integer(value.version or 1, 1, 2147483647)
    if not version then return nil, invalid('payment version is invalid') end
    return {
        id = value.id,
        bookingId = bookingId,
        idempotencyKey = key,
        paymentType = paymentType:upper(),
        amountMinor = amount,
        currency = currency,
        status = status,
        providerReference = value.providerReference or value.provider_reference,
        commissionSnapshot = value.commissionSnapshot or decodeSnapshot(value.commission_snapshot),
        version = version,
        createdAt = value.createdAt or value.created_at,
        updatedAt = value.updatedAt or value.updated_at
    }
end

local function mapRow(row)
    return normalize(row)
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'payment repository requires a database adapter') end
    local name = options.tableName or 'nightshift_payments'
    if not tableName(name) then return nil, invalid('payment repository table name is invalid') end
    local base, errorResult = Base.new({ db = db, tableName = name, columns = columns, mapper = function(row)
        local payment, mapError = mapRow(row)
        if not payment then return Result.err(Codes.MAPPING_FAILED, 'payment row is invalid', { cause = mapError and mapError.error and mapError.error.code }) end
        return payment
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
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'payment was not found', { [field] = value }) end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:findById(id)
    if not integer(id, 1) then return invalid('payment ID is invalid') end
    return self:_find('id', id)
end

function Repository:findByIdempotencyKey(key)
    if not text(key, 128) then return invalid('payment idempotency key is invalid') end
    return self:_find('idempotency_key', key)
end

Repository.findByKey = Repository.findByIdempotencyKey

function Repository:findByBooking(bookingId, options)
    if not integer(bookingId, 1) and not text(bookingId, 160) then return invalid('payment booking ID is invalid') end
    options = options or {}
    local limit = integer(options.limit or 100, 1)
    local offset = integer(options.offset or 0, 0)
    if not limit or limit > 1000 or not offset then return invalid('payment pagination is invalid') end
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

function Repository:create(value)
    local normalized, errorResult = normalize(value)
    if not normalized then return errorResult end
    local row = {
        booking_id = normalized.bookingId,
        idempotency_key = normalized.idempotencyKey,
        payment_type = normalized.paymentType,
        amount_minor = normalized.amountMinor,
        currency = normalized.currency,
        status = normalized.status,
        provider_reference = normalized.providerReference,
        commission_snapshot = encodeSnapshot(normalized.commissionSnapshot)
    }
    return self._base:create(row)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('payment changes must be a table') end
    local mapped, seen = {}, {}
    local aliases = { status = 'status', providerReference = 'providerReference', provider_reference = 'providerReference' }
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field or seen[field] then return invalid('payment field is not mutable', { field = tostring(key) }) end
        seen[field] = true
        if field == 'status' then
            if type(value) ~= 'string' or not statuses[value:upper()] then return invalid('payment status is invalid') end
            mapped.status = value:upper()
        else
            if value ~= nil and not text(value, 128) then return invalid('payment provider reference is invalid') end
            mapped.provider_reference = value
        end
    end
    if next(mapped) == nil then return invalid('payment changes must not be empty') end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
Repository.statuses = copy(statuses)
NightShift.Repositories.Payment = Repository
NightShift.Repositories.Payments = Repository
