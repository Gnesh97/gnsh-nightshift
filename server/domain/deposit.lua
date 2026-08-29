NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Deposit = {}
local statuses = {
    HELD = true,
    REFUNDED = true,
    PARTIALLY_REFUNDED = true,
    RETAINED = true,
    PENDING = true,
    UNKNOWN = true,
    FAILED = true
}

local transitions = {
    HELD = { REFUNDED = true, PARTIALLY_REFUNDED = true, RETAINED = true, PENDING = true, UNKNOWN = true },
    PENDING = { REFUNDED = true, PARTIALLY_REFUNDED = true, RETAINED = true, UNKNOWN = true, FAILED = true },
    UNKNOWN = { REFUNDED = true, PARTIALLY_REFUNDED = true, RETAINED = true, PENDING = true },
    FAILED = { PENDING = true }
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
    return Result.err(Codes.DEPOSIT_INVALID, message, details)
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('deposit must be a table') end
    local bookingId = values.bookingId or values.booking_id
    if not integer(bookingId, 1) and not text(bookingId, 160) then return nil, invalid('deposit booking ID is required') end
    local idempotencyKey = values.idempotencyKey or values.idempotency_key
    if not text(idempotencyKey, 128) then return nil, invalid('deposit idempotency key is required') end
    local amount = integer(values.amountMinor or values.amount_minor or values.amount, 0, 100000000000)
    if amount == nil then return nil, invalid('deposit amount is invalid') end
    local currency = type(values.currency) == 'string' and values.currency:upper() or nil
    if not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return nil, invalid('deposit currency is invalid') end
    local status = type(values.status) == 'string' and values.status:upper() or 'HELD'
    if not statuses[status] then return nil, invalid('deposit status is invalid') end
    local version = integer(values.version or 1, 1, 2147483647)
    if not version then return nil, invalid('deposit version is invalid') end
    return {
        id = values.id,
        bookingId = bookingId,
        idempotencyKey = idempotencyKey,
        amountMinor = amount,
        currency = currency,
        status = status,
        account = text(values.account, 32) and values.account or nil,
        providerReference = text(values.providerReference or values.provider_reference, 128) and (values.providerReference or values.provider_reference) or nil,
        refundedAmountMinor = integer(values.refundedAmountMinor or values.refunded_amount_minor, 0, amount),
        version = version,
        createdAt = values.createdAt or values.created_at,
        updatedAt = values.updatedAt or values.updated_at
    }
end

function Deposit.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(copy(normalized), { __index = Deposit })
end

function Deposit.validate(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return true
end

function Deposit.copy(value) return copy(value) end

function Deposit.toRow(value)
    local normalized, errorResult = normalize(value)
    if not normalized then return nil, errorResult end
    return {
        booking_id = normalized.bookingId,
        idempotency_key = normalized.idempotencyKey,
        amount_minor = normalized.amountMinor,
        currency = normalized.currency,
        status = normalized.status,
        provider_reference = normalized.providerReference
    }
end

function Deposit.fromRow(row)
    if type(row) ~= 'table' then return nil, invalid('deposit row must be a table') end
    return Deposit.new({
        id = row.id,
        bookingId = row.booking_id or row.bookingId,
        idempotencyKey = row.idempotency_key or row.idempotencyKey,
        amountMinor = row.amount_minor or row.amountMinor,
        currency = row.currency,
        status = row.status,
        account = row.account,
        providerReference = row.provider_reference or row.providerReference,
        refundedAmountMinor = row.refunded_amount_minor or row.refundedAmountMinor,
        version = row.version,
        createdAt = row.created_at or row.createdAt,
        updatedAt = row.updated_at or row.updatedAt
    })
end

function Deposit:canTransition(status)
    status = type(status) == 'string' and status:upper() or status
    return transitions[self.status] and transitions[self.status][status] == true
end

function Deposit:transition(status, changes)
    status = type(status) == 'string' and status:upper() or status
    if not statuses[status] then return Result.err(Codes.DEPOSIT_INVALID, 'deposit status is invalid') end
    if status ~= self.status and not self:canTransition(status) then
        return Result.err(Codes.DEPOSIT_ALREADY_FINALIZED, 'deposit cannot transition from its current status', { from = self.status, to = status })
    end
    local output = copy(self)
    output.status = status
    for key, value in pairs(changes or {}) do output[key] = copy(value) end
    output.version = self.version + (status == self.status and 0 or 1)
    local normalized, errorResult = Deposit.new(output)
    if not normalized then return errorResult end
    return Result.ok(normalized)
end

Deposit.statuses = copy(statuses)
Deposit.transitions = copy(transitions)
NightShift.Domain.Deposit = Deposit
NightShift.Deposit = Deposit
