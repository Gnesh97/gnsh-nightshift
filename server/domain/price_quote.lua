NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local PriceQuote = {}

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
    return Result.err(Codes.QUOTE_INVALID, message, details)
end

local function currency(value)
    value = type(value) == 'string' and value:upper() or value
    return type(value) == 'string' and value:match('^[A-Z][A-Z][A-Z]$') ~= nil and value or nil
end

local function epoch(value)
    if type(value) == 'number' then return tonumber(value) end
    if type(value) ~= 'string' then return nil end
    local year, month, day, hour, minute, second = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$')
    if not year then return nil end
    local ok, output = pcall(os.time, { year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false })
    if not ok or not output then return nil end
    local utcView = os.time(os.date('!*t', output))
    return output + os.difftime(output, utcView)
end

local function timestamp(value)
    if type(value) == 'number' then
        value = integer(value, 0)
        if not value then return nil end
        local ok, output = pcall(os.date, '!%Y-%m-%dT%H:%M:%SZ', value)
        return ok and output or nil
    end
    if not text(value, 64) or not value:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil end
    return value
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('price quote must be a table') end
    local id = values.id or values.quoteId
    if not text(id, 128) then return nil, invalid('quote ID is required') end
    local amount = integer(values.amountMinor or values.amount, 1, 100000000000)
    if amount == nil then return nil, invalid('quote amount is invalid') end
    local code = currency(values.currency)
    if not code then return nil, invalid('quote currency is invalid') end
    local bookingId = values.bookingId
    if bookingId ~= nil and not integer(bookingId, 1) and not text(bookingId, 160) then return nil, invalid('quote booking ID is invalid') end
    local issuedAt = timestamp(values.issuedAt or values.quotedAt)
    if not issuedAt then return nil, invalid('quote issuedAt is required') end
    local expiresAt = values.expiresAt
    if expiresAt ~= nil then
        expiresAt = timestamp(expiresAt)
        if not expiresAt then return nil, invalid('quote expiry is invalid') end
    end
    if expiresAt and not epoch(expiresAt) then return nil, invalid('quote expiry is not parseable') end
    local accepted = values.accepted == true
    local acceptedAt = values.acceptedAt
    if acceptedAt ~= nil then acceptedAt = timestamp(acceptedAt); if not acceptedAt then return nil, invalid('quote acceptedAt is invalid') end end
    return {
        id = id,
        quoteId = id,
        bookingId = bookingId,
        amountMinor = amount,
        currency = code,
        issuedAt = issuedAt,
        quotedAt = issuedAt,
        expiresAt = expiresAt,
        lineItems = copy(values.lineItems or values.breakdown or {}),
        breakdown = copy(values.breakdown or values.lineItems or {}),
        accepted = accepted,
        acceptedAt = acceptedAt,
        acceptedSnapshot = copy(values.acceptedSnapshot)
    }
end

function PriceQuote.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(copy(normalized), { __index = PriceQuote })
end

function PriceQuote.validate(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return true
end

function PriceQuote.copy(value)
    return copy(value)
end

function PriceQuote:isExpired(now)
    if self.expiresAt == nil then return false end
    local expiry = epoch(self.expiresAt)
    local current = epoch(now == nil and os.time() or now)
    if not expiry or not current then return false end
    return current >= expiry
end

function PriceQuote:accept(now, bookingId)
    if bookingId ~= nil and self.bookingId ~= nil and tostring(bookingId) ~= tostring(self.bookingId) then
        return Result.err(Codes.QUOTE_INVALID, 'quote is bound to another booking', { quoteId = self.id })
    end
    if self:isExpired(now) then return Result.err(Codes.QUOTE_EXPIRED, 'quote has expired', { quoteId = self.id }) end
    if self.accepted == true then return Result.ok(setmetatable(copy(self), { __index = PriceQuote }), { idempotent = true }) end
    local acceptedAt = timestamp(now) or timestamp(os.time()) or self.issuedAt
    local output = setmetatable(copy(self), { __index = PriceQuote })
    output.accepted = true
    output.acceptedAt = acceptedAt
    output.acceptedSnapshot = {
        quoteId = self.id,
        bookingId = self.bookingId or bookingId,
        amountMinor = self.amountMinor,
        currency = self.currency,
        quotedAt = self.quotedAt,
        expiresAt = self.expiresAt,
        acceptedAt = acceptedAt
    }
    if output.bookingId == nil then output.bookingId = bookingId end
    return Result.ok(output, { frozen = true })
end

function PriceQuote:withAmount(amount, currencyCode)
    if self.accepted == true then return Result.err(Codes.QUOTE_IMMUTABLE, 'accepted quote cannot be recalculated', { quoteId = self.id }) end
    local value = integer(amount, 1, 100000000000)
    local code = currency(currencyCode or self.currency)
    if value == nil or not code then return invalid('replacement quote amount is invalid') end
    local output = setmetatable(copy(self), { __index = PriceQuote })
    output.amountMinor = value
    output.currency = code
    output.acceptedSnapshot = nil
    return Result.ok(output)
end

function PriceQuote:bind(bookingId)
    if not integer(bookingId, 1) and not text(bookingId, 160) then return invalid('quote booking ID is invalid') end
    if self.accepted == true and self.bookingId == nil then return Result.err(Codes.QUOTE_IMMUTABLE, 'accepted quote cannot be rebound') end
    if self.bookingId ~= nil and tostring(self.bookingId) ~= tostring(bookingId) then return Result.err(Codes.QUOTE_IMMUTABLE, 'quote is already bound to another booking') end
    local output = setmetatable(copy(self), { __index = PriceQuote })
    output.bookingId = bookingId
    return Result.ok(output)
end

PriceQuote.freeze = PriceQuote.accept
PriceQuote.acceptSnapshot = PriceQuote.accept
PriceQuote.isValid = function(self, now) return not self:isExpired(now) end

NightShift.Domain.PriceQuote = PriceQuote
NightShift.PriceQuote = PriceQuote
