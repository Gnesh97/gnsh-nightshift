NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Booking = {}

local participantTypes = { PLAYER = true, NPC = true, SYSTEM = true }
local initiatorTypes = { PLAYER = true, NPC = true, SYSTEM = true, ADMIN = true }
local statuses = {
    DRAFT = true, QUOTED = true, OFFERED = true, ACCEPTED = true,
    RESERVED = true, TRAVELLING = true, ARRIVED = true, ACTIVE = true,
    COMPLETED = true, SETTLED = true, DECLINED = true, CANCELLED = true,
    EXPIRED = true, INTERRUPTED = true
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
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 128)
end

local function token(value, maxLength)
    return type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') ~= nil and #value <= (maxLength or 64)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.BOOKING_INVALID, message, details)
end

local function canonical(value)
    return type(value) == 'string' and value:upper() or value
end

local function normalizeType(value, field, allowed)
    value = canonical(value)
    if not allowed[value] then return nil, invalid(field .. ' is invalid', { field = field }) end
    return value
end

local function normalizeRef(value, field)
    if not text(value, 160) then return nil, invalid(field .. ' is required', { field = field }) end
    return value
end

local function normalizeTimestamp(value, field)
    if value == nil then return nil end
    if type(value) == 'number' then
        if not integer(value, 0) then return nil, invalid(field .. ' must be a finite timestamp', { field = field }) end
        return value
    end
    if not text(value, 64) then return nil, invalid(field .. ' must be a timestamp', { field = field }) end
    return value
end

-- MariaDB DATETIME values arrive without a timezone and zero dates may be
-- exposed by oxmysql as false/invalid Date values. Normalize only the row
-- boundary so the domain and PriceQuote always see the canonical UTC shape.
local function normalizeRowTimestamp(value)
    if value == nil or value == false then return nil end
    if type(value) == 'number' then
        value = integer(value, 0)
        if not value or value <= 0 then return nil end
        if value >= 100000000000 then value = math.floor(value / 1000) end
        local ok, output = pcall(os.date, '!%Y-%m-%dT%H:%M:%SZ', value)
        if not ok or type(output) ~= 'string' or output:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') == nil then return nil end
        return output
    end
    if type(value) ~= 'string' then return nil end
    if value:match('^0000%-00%-00') then return nil end

    local date, clock, remainder = value:match('^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d:%d%d:%d%d)(.*)$')
    if date and (remainder == '' or remainder == 'Z' or remainder:match('^%.%d+$') or remainder:match('^%.%d+Z$')) then
        return date .. 'T' .. clock .. 'Z'
    end
    return value
end

-- oxmysql can expose SQL NULL as false on some adapter/runtime combinations.
-- Treat that sentinel as NULL only while decoding database rows; false remains
-- invalid for normal domain inputs.
local function normalizeRowNullable(value)
    if value == false then return nil end
    if type(value) == 'string' and value:match('^%s*$') then return nil end
    return value
end

local function normalizeCurrency(value, field)
    value = type(value) == 'string' and value:upper() or value
    if type(value) ~= 'string' or value:match('^[A-Z][A-Z][A-Z]$') == nil then
        return nil, invalid(field .. ' must be a three-letter currency', { field = field })
    end
    return value
end

local function normalizePackage(value)
    if type(value) == 'string' then
        if not text(value, 96) or not token(value, 96) then return nil, invalid('servicePackage ID is invalid', { field = 'servicePackage' }) end
        return { id = value }
    end
    if type(value) ~= 'table' then return nil, invalid('servicePackage is required', { field = 'servicePackage' }) end
    local allowed = { id = true, priceMinor = true, price_minor = true, durationMinutes = true, duration = true, currency = true }
    for key in pairs(value) do
        if not allowed[key] then return nil, invalid('servicePackage field is not allowlisted', { field = 'servicePackage.' .. tostring(key) }) end
    end
    local id = value.id
    if not text(id, 96) or not token(id, 96) then return nil, invalid('servicePackage ID is invalid', { field = 'servicePackage.id' }) end
    local output = { id = id }
    local price = value.priceMinor
    if price == nil then price = value.price_minor end
    if price ~= nil then
        price = integer(price, 0, 100000000000)
        if price == nil then return nil, invalid('servicePackage price is invalid', { field = 'servicePackage.priceMinor' }) end
        output.priceMinor = price
    end
    local duration = value.durationMinutes
    if duration == nil then duration = value.duration end
    if duration ~= nil then
        duration = integer(duration, 1, 10080)
        if duration == nil then return nil, invalid('servicePackage duration is invalid', { field = 'servicePackage.durationMinutes' }) end
        output.durationMinutes = duration
    end
    if value.currency ~= nil then
        output.currency = normalizeCurrency(value.currency, 'servicePackage.currency')
        if not output.currency then return nil, invalid('servicePackage currency is invalid', { field = 'servicePackage.currency' }) end
    end
    return output
end

local function normalizePrice(value, field)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a snapshot table', { field = field }) end
    local allowed = { amountMinor = true, amount = true, currency = true, quotedAt = true, quoted_at = true, agreedAt = true, agreed_at = true, expiresAt = true, expires_at = true, quoteId = true, quote_id = true, bookingId = true, booking_id = true }
    for key in pairs(value) do
        if not allowed[key] then return nil, invalid(field .. ' field is not allowlisted', { field = field .. '.' .. tostring(key) }) end
    end
    local amount = value.amountMinor
    if amount == nil then amount = value.amount end
    amount = integer(amount, 0, 100000000000)
    if amount == nil then return nil, invalid(field .. '.amountMinor is invalid', { field = field .. '.amountMinor' }) end
    local currency, currencyError = normalizeCurrency(value.currency, field .. '.currency')
    if not currency then return nil, currencyError end
    local output = { amountMinor = amount, currency = currency }
    local quoteId = value.quoteId or value.quote_id
    if quoteId ~= nil then
        if not text(quoteId, 128) then return nil, invalid(field .. '.quoteId is invalid', { field = field .. '.quoteId' }) end
        output.quoteId = quoteId
    end
    local bookingId = value.bookingId or value.booking_id
    if bookingId ~= nil then
        if not integer(bookingId, 1) and not text(bookingId, 160) then return nil, invalid(field .. '.bookingId is invalid', { field = field .. '.bookingId' }) end
        output.bookingId = bookingId
    end
    for _, item in ipairs({ { 'quotedAt', 'quoted_at' }, { 'agreedAt', 'agreed_at' }, { 'expiresAt', 'expires_at' } }) do
        local name, alias = item[1], item[2]
        local timestamp, timestampError = normalizeTimestamp(value[name] == nil and value[alias] or value[name], field .. '.' .. name)
        if timestampError then return nil, timestampError end
        if timestamp ~= nil then output[name] = timestamp end
    end
    return output
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('booking values must be a table') end
    local source = copy(values)
    local aliases = {
        idempotency_key = 'idempotencyKey', initiator_type = 'initiatorType',
        client_type = 'clientType', client_ref = 'clientRef',
        worker_type = 'workerType', worker_ref = 'workerRef',
        service_package = 'servicePackage', service_package_id = 'servicePackage',
        meeting_mode = 'meetingMode', mode = 'meetingMode',
        location_type = 'locationType', location_ref = 'locationRef',
        scheduled_at = 'scheduledAt', start_at = 'startAt', started_at = 'startAt',
        end_at = 'endAt', ended_at = 'endAt', completed_at = 'completedAt',
        correlation_id = 'correlationId', external_reference = 'externalReference',
        agreed_price = 'agreedPrice', agreed_price_snapshot = 'agreedPrice',
        quote_snapshot = 'quote', version_number = 'version'
    }
    for alias, name in pairs(aliases) do
        if source[name] == nil and source[alias] ~= nil then source[name] = source[alias] end
    end

    local allowed = {
        id = true, idempotencyKey = true, initiatorType = true, clientType = true, clientRef = true,
        workerType = true, workerRef = true, servicePackage = true, meetingMode = true,
        locationType = true, locationRef = true, quote = true, agreedPrice = true,
        scheduledAt = true, startAt = true, endAt = true, completedAt = true, status = true,
        version = true, correlationId = true, externalReference = true, createdAt = true, updatedAt = true
    }
    for key in pairs(source) do
        if not allowed[key] and aliases[key] == nil then return nil, invalid('booking field is not allowlisted', { field = tostring(key) }) end
    end

    local output = {}
    if source.id ~= nil then
        if not integer(source.id, 1) and not text(source.id, 160) then return nil, invalid('booking ID is invalid', { field = 'id' }) end
        output.id = source.id
    end
    if not text(source.idempotencyKey, 128) then return nil, invalid('idempotencyKey is required', { field = 'idempotencyKey' }) end
    output.idempotencyKey = source.idempotencyKey
    output.initiatorType = select(1, normalizeType(source.initiatorType or 'PLAYER', 'initiatorType', initiatorTypes))
    if not output.initiatorType then return nil, invalid('initiatorType is invalid', { field = 'initiatorType' }) end
    output.clientType = select(1, normalizeType(source.clientType, 'clientType', participantTypes))
    if not output.clientType then return nil, invalid('clientType is invalid', { field = 'clientType' }) end
    output.clientRef = normalizeRef(source.clientRef, 'clientRef')
    if not output.clientRef then return nil, invalid('clientRef is required', { field = 'clientRef' }) end
    output.workerType = select(1, normalizeType(source.workerType, 'workerType', participantTypes))
    if not output.workerType then return nil, invalid('workerType is invalid', { field = 'workerType' }) end
    output.workerRef = normalizeRef(source.workerRef, 'workerRef')
    if not output.workerRef then return nil, invalid('workerRef is required', { field = 'workerRef' }) end
    local package, packageError = normalizePackage(source.servicePackage)
    if not package then return nil, packageError end
    output.servicePackage = package
    if source.meetingMode == nil or not token(source.meetingMode, 32) then return nil, invalid('meetingMode is required', { field = 'meetingMode' }) end
    output.meetingMode = source.meetingMode
    if source.locationType ~= nil or source.locationRef ~= nil then
        if not token(source.locationType, 32) then return nil, invalid('locationType is invalid', { field = 'locationType' }) end
        output.locationType = source.locationType
        output.locationRef = normalizeRef(source.locationRef, 'locationRef')
        if not output.locationRef then return nil, invalid('locationRef is required', { field = 'locationRef' }) end
    end
    local quote, quoteError = normalizePrice(source.quote, 'quote')
    if quoteError then return nil, quoteError end
    output.quote = quote
    local agreed, agreedError = normalizePrice(source.agreedPrice, 'agreedPrice')
    if agreedError then return nil, agreedError end
    output.agreedPrice = agreed
    for _, item in ipairs({ { 'scheduledAt', 'scheduledAt' }, { 'startAt', 'startAt' }, { 'endAt', 'endAt' }, { 'completedAt', 'completedAt' } }) do
        local name = item[1]
        local timestamp, timestampError = normalizeTimestamp(source[name], name)
        if timestampError then return nil, timestampError end
        output[name] = timestamp
    end
    output.status = canonical(source.status or 'DRAFT')
    if not statuses[output.status] then return nil, invalid('booking status is invalid', { field = 'status' }) end
    output.version = integer(source.version or 1, 1, 2147483647)
    if not output.version then return nil, invalid('booking version is invalid', { field = 'version' }) end
    for _, item in ipairs({ { 'correlationId', 96 }, { 'externalReference', 160 } }) do
        local name, maxLength = item[1], item[2]
        if source[name] ~= nil then
            if not text(source[name], maxLength) then return nil, invalid(name .. ' is invalid', { field = name }) end
            output[name] = source[name]
        end
    end
    for _, name in ipairs({ 'createdAt', 'updatedAt' }) do
        local timestamp, timestampError = normalizeTimestamp(source[name], name)
        if timestampError then return nil, timestampError end
        output[name] = timestamp
    end
    return output
end

function Booking.validate(values)
    local normalized, err = normalize(values)
    if not normalized then return nil, err end
    return true
end

function Booking.new(values)
    local normalized, err = normalize(values)
    if not normalized then return nil, err end
    return copy(normalized)
end

function Booking.copy(value)
    return copy(value)
end

function Booking.apply(booking, changes)
    if type(changes) ~= 'table' then return nil, invalid('booking changes must be a table') end
    local merged = copy(booking)
    for key, value in pairs(changes) do
        local aliases = { status = 'status', quote_snapshot = 'quote', agreed_price_snapshot = 'agreedPrice', agreed_price = 'agreedPrice', scheduled_at = 'scheduledAt', start_at = 'startAt', end_at = 'endAt', completed_at = 'completedAt', correlation_id = 'correlationId', external_reference = 'externalReference', location_type = 'locationType', location_ref = 'locationRef', meeting_mode = 'meetingMode' }
        local target = aliases[key] or key
        local allowed = { status = true, quote = true, agreedPrice = true, scheduledAt = true, startAt = true, endAt = true, completedAt = true, correlationId = true, externalReference = true, locationType = true, locationRef = true, meetingMode = true, version = true }
        if not allowed[target] then return nil, invalid('booking field is not mutable', { field = tostring(key) }) end
        merged[target] = copy(value)
    end
    return Booking.new(merged)
end

function Booking.toRow(booking)
    local value, err = normalize(booking)
    if not value then return nil, err end
    local package = value.servicePackage
    local quote = value.quote
    local agreed = value.agreedPrice
    local price = agreed and agreed.amountMinor or quote and quote.amountMinor or package.priceMinor or 0
    local currency = agreed and agreed.currency or quote and quote.currency or package.currency or 'USD'
    return {
        idempotency_key = value.idempotencyKey,
        initiator_type = value.initiatorType,
        client_type = value.clientType,
        client_ref = value.clientRef,
        worker_type = value.workerType,
        worker_ref = value.workerRef,
        service_package_id = package.id,
        mode = value.meetingMode,
        meeting_mode = value.meetingMode,
        location_type = value.locationType,
        location_ref = value.locationRef,
        quote_minor = quote and quote.amountMinor or nil,
        quote_currency = quote and quote.currency or nil,
        quoted_at = quote and quote.quotedAt or nil,
        quote_id = quote and quote.quoteId or nil,
        quote_expires_at = quote and quote.expiresAt or nil,
        agreed_price_minor = agreed and agreed.amountMinor or nil,
        agreed_currency = agreed and agreed.currency or nil,
        agreed_at = agreed and agreed.agreedAt or nil,
        agreed_quote_id = agreed and agreed.quoteId or nil,
        price_minor = price,
        currency = currency,
        status = value.status,
        correlation_id = value.correlationId,
        external_reference = value.externalReference,
        scheduled_at = value.scheduledAt,
        started_at = value.startAt,
        ended_at = value.endAt,
        completed_at = value.completedAt,
        -- id/version/timestamps are database-managed and stay out of INSERT values.
    }
end

function Booking.fromRow(row)
    if type(row) ~= 'table' then return nil, invalid('booking row must be a table') end
    local package = {
        id = normalizeRowNullable(row.service_package_id or row.servicePackageId),
        priceMinor = normalizeRowNullable(row.price_minor),
        currency = normalizeRowNullable(row.currency)
    }
    local clientType = normalizeRowNullable(row.client_type or row.clientType) or (normalizeRowNullable(row.client_profile_id) and 'PLAYER' or 'NPC')
    local workerType = normalizeRowNullable(row.worker_type or row.workerType) or (normalizeRowNullable(row.worker_profile_id) and 'PLAYER' or 'NPC')
    local clientRef = normalizeRowNullable(row.client_ref or row.clientRef or row.client_profile_id)
    local workerRef = normalizeRowNullable(row.worker_ref or row.workerRef or row.worker_profile_id or row.npc_worker_id)
    local locationRef = normalizeRowNullable(row.location_ref or row.locationRef or row.location_id)
    if clientRef ~= nil then clientRef = tostring(clientRef) end
    if workerRef ~= nil then workerRef = tostring(workerRef) end
    if locationRef ~= nil then locationRef = tostring(locationRef) end
    local quotedAt = normalizeRowTimestamp(row.quoted_at)
    local agreedAt = normalizeRowTimestamp(row.agreed_at)
    local quoteExpiresAt = normalizeRowTimestamp(row.quote_expires_at)
    local scheduledAt = normalizeRowTimestamp(row.scheduled_at or row.scheduledAt)
    local startAt = normalizeRowTimestamp(row.started_at or row.start_at or row.startAt)
    local endAt = normalizeRowTimestamp(row.ended_at or row.end_at or row.endAt)
    local completedAt = normalizeRowTimestamp(row.completed_at or row.completedAt)
    local createdAt = normalizeRowTimestamp(row.created_at or row.createdAt)
    local updatedAt = normalizeRowTimestamp(row.updated_at or row.updatedAt)
    local values = {
        id = row.id,
        idempotencyKey = row.idempotency_key or row.idempotencyKey,
        initiatorType = row.initiator_type or row.initiatorType or 'PLAYER',
        clientType = clientType,
        clientRef = clientRef,
        workerType = workerType,
        workerRef = workerRef,
        servicePackage = package,
        meetingMode = row.meeting_mode or row.mode or 'IN_PERSON',
        locationType = row.location_type or row.locationType or (locationRef and 'LEGACY' or nil),
        locationRef = locationRef,
        quote = normalizeRowNullable(row.quote_minor) ~= nil and {
            amountMinor = normalizeRowNullable(row.quote_minor),
            currency = normalizeRowNullable(row.quote_currency) or package.currency,
            quotedAt = quotedAt,
            quoteId = normalizeRowNullable(row.quote_id),
            expiresAt = quoteExpiresAt
        } or nil,
        agreedPrice = normalizeRowNullable(row.agreed_price_minor) ~= nil and {
            amountMinor = normalizeRowNullable(row.agreed_price_minor),
            currency = normalizeRowNullable(row.agreed_currency) or package.currency,
            agreedAt = agreedAt,
            quoteId = normalizeRowNullable(row.agreed_quote_id)
        } or nil,
        scheduledAt = scheduledAt,
        startAt = startAt,
        endAt = endAt,
        completedAt = completedAt,
        status = row.status,
        version = row.version,
        correlationId = row.correlation_id or row.correlationId,
        externalReference = row.external_reference or row.externalReference,
        createdAt = createdAt,
        updatedAt = updatedAt
    }
    return Booking.new(values)
end

Booking.statuses = copy(statuses)
Booking.participantTypes = copy(participantTypes)
Booking.initiatorTypes = copy(initiatorTypes)
NightShift.Domain.Booking = Booking
NightShift.Booking = Booking
