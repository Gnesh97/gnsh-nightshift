NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local meetingModes = {
    come_to_me = 'COME_TO_ME',
    pickup = 'PICKUP',
    meet_there = 'MEET_THERE'
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

local function sourceValue(value)
    local source = integer(value, 1, 65535)
    return source
end

-- This is an intentionally small, non-cryptographic fingerprint used only to
-- keep repeated NUI quote clicks on the same draft idempotent. It never leaves
-- the server and is not used for authorization or secrecy.
local function fingerprint(value)
    value = tostring(value or '')
    local hash = 2166136261
    for index = 1, #value do
        hash = (hash * 16777619 + value:byte(index)) % 4294967291
    end
    return tostring(hash)
end

local function epoch(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = ok and tonumber(value) or nil
        if value and value >= 0 then return value end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.CLIENT_BOOKING_COMMAND_INVALID, message, details)
end

local function failed(message, details)
    return Result.err(Codes.CLIENT_BOOKING_COMMAND_FAILED, message, details)
end

local function unwrap(result, message)
    if type(result) ~= 'table' then return nil, failed(message or 'service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value or result.data end
    return result
end

local function callService(service, method, ...)
    if type(service) ~= 'table' or type(service[method]) ~= 'function' then
        return nil, failed(('required service method "%s" is unavailable'):format(method))
    end
    local ok, result = pcall(service[method], service, ...)
    if not ok then return nil, failed(('service method "%s" failed'):format(method)) end
    return unwrap(result, ('service method "%s" returned an invalid result'):format(method))
end

local function normalizeDraft(payload)
    if type(payload) ~= 'table' then return nil, invalid('booking quote payload must be a table') end
    local allowed = { workerId = true, packageId = true, meetingMode = true, locationId = true }
    for key in pairs(payload) do
        if not allowed[key] then return nil, invalid('booking quote field is not allowlisted', { field = tostring(key) }) end
    end
    if not text(payload.workerId, 160) then return nil, invalid('worker ID is required') end
    if not text(payload.packageId, 96) then return nil, invalid('service package ID is required') end
    if not text(payload.locationId, 160) then return nil, invalid('location ID is required') end
    local mode = type(payload.meetingMode) == 'string' and meetingModes[payload.meetingMode:lower()] or nil
    if not mode then return nil, invalid('meeting mode is invalid') end
    return {
        workerId = payload.workerId,
        packageId = payload.packageId,
        meetingMode = mode,
        locationId = payload.locationId
    }
end

local function normalizeQuoteId(payload)
    if type(payload) ~= 'table' then return nil, invalid('booking confirmation payload must be a table') end
    local allowed = { quoteId = true }
    for key in pairs(payload) do
        if not allowed[key] then return nil, invalid('booking confirmation field is not allowlisted', { field = tostring(key) }) end
    end
    if not text(payload.quoteId, 128) then return nil, invalid('quote ID is required') end
    return payload.quoteId
end

local function quoteIdOf(quote)
    local value = type(quote) == 'table' and (quote.quoteId or quote.id) or nil
    return text(value, 128) and value or nil
end

local function safeQuote(quote, workerId)
    if type(quote) ~= 'table' then return nil, invalid('pricing service returned an invalid quote') end
    local quoteId = quoteIdOf(quote)
    local amount = integer(quote.amountMinor or quote.amount, 1, 100000000000)
    local currency = type(quote.currency) == 'string' and quote.currency:upper() or nil
    if not quoteId or not amount or not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then
        return nil, Result.err(Codes.QUOTE_INVALID, 'quote response is invalid')
    end
    local expiresAt = quote.expiresAt
    if expiresAt ~= nil and type(expiresAt) ~= 'string' and type(expiresAt) ~= 'number' then
        return nil, Result.err(Codes.QUOTE_INVALID, 'quote expiry is invalid')
    end
    return {
        quoteId = quoteId,
        amount = amount,
        currency = currency,
        expiresAt = expiresAt,
        workerId = workerId
    }
end

local function bookingQuoteId(booking)
    local quote = type(booking) == 'table' and (booking.quote or booking.quote_snapshot) or nil
    return quoteIdOf(quote)
end

local function draftMatches(booking, draft)
    if type(booking) ~= 'table' or type(draft) ~= 'table' then return false end
    local workerRef = booking.workerRef or booking.worker_ref
    local package = booking.servicePackage or booking.service_package
    local packageId = booking.servicePackageId or booking.service_package_id
    if type(package) == 'table' then packageId = package.id or package.packageId or package.package_id or packageId end
    local meetingMode = booking.meetingMode or booking.meeting_mode or booking.mode
    local locationRef = booking.locationRef or booking.location_ref or booking.locationId or booking.location_id
    if not text(workerRef, 160) or not text(packageId, 96) or not text(meetingMode, 32) or not text(locationRef, 160) then return false end
    return tostring(workerRef) == draft.workerId and
        tostring(packageId) == draft.packageId and
        tostring(meetingMode):upper() == draft.meetingMode and
        tostring(locationRef) == draft.locationId
end

local function confirmation(booking)
    if type(booking) ~= 'table' or booking.id == nil then return nil, failed('booking response is invalid') end
    local status = type(booking.status) == 'string' and booking.status:upper() or nil
    if status ~= 'RESERVED' then return nil, failed('booking did not reach RESERVED state', { status = status }) end
    return Result.ok({ bookingId = tostring(booking.id), status = status })
end

local function reservationResources(booking, ttlSeconds)
    if type(booking) ~= 'table' then return nil, failed('booking resource context is invalid') end
    local workerRef = booking.workerRef or booking.worker_ref
    local locationRef = booking.locationRef or booking.location_ref
    if not text(workerRef, 160) or not text(locationRef, 160) then
        return nil, Result.err(Codes.RESERVATION_INVALID, 'booking does not contain reservable worker and location references')
    end
    return {
        { type = 'NPC', id = workerRef, ttlSeconds = ttlSeconds },
        { type = 'LOCATION', id = locationRef, ttlSeconds = ttlSeconds }
    }
end

function Service.new(options)
    options = options or {}
    local booking = options.bookingService or options.booking
    local pricing = options.pricingService or options.pricing
    local identity = options.identityService or options.identity
    local worker = options.workerService or options.npcWorker
    local repository = options.repository or options.bookingRepository
    local reservation = options.reservationService or options.bookingReservation
    if type(booking) ~= 'table' or type(booking.createDraft) ~= 'function' or type(booking.applyAuthoritativeQuote) ~= 'function' or
        type(booking.offer) ~= 'function' or type(booking.accept) ~= 'function' or type(booking.reserve) ~= 'function' or
        type(booking.get) ~= 'function' then
        return nil, failed('client booking command requires a booking service')
    end
    if type(pricing) ~= 'table' or type(pricing.quote) ~= 'function' then return nil, failed('client booking command requires pricing') end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, failed('client booking command requires identity') end
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' then return nil, failed('client booking command requires NPC worker lookup') end
    if type(repository) ~= 'table' or type(repository.findByQuoteId) ~= 'function' then return nil, failed('client booking command requires quote lookup') end
    if type(reservation) ~= 'table' or type(reservation.reserve) ~= 'function' then return nil, failed('client booking command requires reservation service') end
    local reservationTtl = integer(options.reservationTtlSeconds or options.resourceTtlSeconds or 3600, 1, 86400)
    if not reservationTtl then return nil, invalid('reservation TTL is invalid') end
    -- PricingConfig defaults to a five-minute quote lifetime. Keep the
    -- idempotency window aligned with that lifetime unless a custom pricing
    -- adapter supplies a different window through bootstrap options.
    local quoteWindowSeconds = integer(options.quoteWindowSeconds or 300, 1, 86400)
    if not quoteWindowSeconds then return nil, invalid('quote idempotency window is invalid') end
    return setmetatable({
        _booking = booking,
        _pricing = pricing,
        _identity = identity,
        _workerService = worker,
        _repository = repository,
        _reservation = reservation,
        _clientMode = options.clientModeService or options.clientMode,
        _reservationTtl = reservationTtl,
        _clock = options.clock,
        _quoteWindowSeconds = quoteWindowSeconds
    }, Service)
end

function Service:_actor(source)
    local playerSource = sourceValue(source)
    if not playerSource then return nil, invalid('player source is invalid') end
    local identity, identityError = callService(self._identity, 'resolve', playerSource)
    if not identity then return nil, identityError end
    local reference = identity.identityKey or identity.key
    if not text(reference, 160) then return nil, Result.err(Codes.IDENTITY_INVALID, 'resolved identity has no safe player reference') end
    return { type = 'PLAYER', ref = reference, source = playerSource }
end

function Service:_resolveWorker(workerId)
    local worker, workerError = callService(self._workerService, 'get', workerId)
    if not worker then return nil, workerError end
    local workerKey = worker.workerKey or worker.key or worker.id
    if not text(workerKey, 160) or tostring(workerKey) ~= workerId then
        return nil, Result.err(Codes.NPC_WORKER_INVALID, 'worker lookup returned a mismatched worker')
    end
    local state = type(worker.state) == 'string' and worker.state:upper() or nil
    if state and state ~= 'AVAILABLE' then
        return nil, Result.err(Codes.NPC_WORKER_CONFLICT, 'worker is no longer available')
    end
    return worker
end

function Service:quote(source, payload)
    local draft, draftError = normalizeDraft(payload)
    if not draft then return draftError end
    local actor, actorError = self:_actor(source)
    if not actor then return actorError end
    local worker, workerError = self:_resolveWorker(draft.workerId)
    if not worker then return workerError end
    local pricingRequest = {
        servicePackageId = draft.packageId,
        meetingMode = draft.meetingMode,
        locationId = draft.locationId,
        district = worker.activeDistrict,
        npcPriceClass = worker.priceClass
    }
    local quote, quoteError = callService(self._pricing, 'quote', pricingRequest)
    if not quote then return quoteError end
    local publicQuote, publicError = safeQuote(quote, draft.workerId)
    if not publicQuote then return publicError end
    local requestWindow = math.floor(epoch(self._clock) / self._quoteWindowSeconds)
    local idempotencyKey = ('nui-draft:%s:%s:%s:%s:%s:%s'):format(
        fingerprint(actor.ref),
        fingerprint(draft.workerId),
        fingerprint(draft.packageId),
        draft.meetingMode,
        fingerprint(draft.locationId),
        tostring(requestWindow)
    )
    local booking, bookingError = callService(self._booking, 'createDraft', actor, {
        idempotencyKey = idempotencyKey,
        initiatorType = 'PLAYER',
        clientType = 'PLAYER',
        clientRef = actor.ref,
        workerType = 'NPC',
        workerRef = draft.workerId,
        servicePackageId = draft.packageId,
        meetingMode = draft.meetingMode,
        locationType = 'CONFIG_LOCATION',
        locationRef = draft.locationId
    })
    if not booking then return bookingError end
    if booking.id == nil then return failed('booking draft did not return an ID') end
    local status = type(booking.status) == 'string' and booking.status:upper() or 'DRAFT'
    if status == 'DRAFT' then
        local quoted, quoteError = callService(self._booking, 'applyAuthoritativeQuote', actor, booking.id, quote, booking.version)
        if not quoted then return quoteError end
    elseif status ~= 'QUOTED' and status ~= 'OFFERED' and status ~= 'ACCEPTED' and status ~= 'RESERVED' then
        return Result.err(Codes.BOOKING_STATE_INVALID, 'booking cannot receive a quote in its current state', { status = status })
    end
    if status ~= 'DRAFT' then
        local bookingClientType = type(booking.clientType) == 'string' and booking.clientType:upper() or nil
        if bookingClientType ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then
            return Result.err(Codes.BOOKING_OWNERSHIP_DENIED, 'actor does not own the existing booking')
        end
        if not draftMatches(booking, draft) then
            return Result.err(Codes.BOOKING_STATE_INVALID, 'existing booking does not match the quote request')
        end
        -- createDraft may return an existing booking for a repeated request.
        -- In that case the persisted quote is authoritative; do not create a
        -- second draft just because the pricing service minted a new ID.
        local storedQuote = booking.quote or booking.quote_snapshot or booking.agreedPrice
        if type(storedQuote) == 'table' then
            local existingQuote, existingError = safeQuote(storedQuote, draft.workerId)
            if existingQuote then return Result.ok(existingQuote) end
            if existingError then return existingError end
        end
        return Result.err(Codes.QUOTE_INVALID, 'booking is already bound to a quote')
    end
    return Result.ok(publicQuote)
end

function Service:confirm(source, payload)
    if self._clientMode and type(self._clientMode.confirm) == 'function' then
        return self._clientMode:confirm(source, payload)
    end
    local quoteId, quoteError = normalizeQuoteId(payload)
    if not quoteId then return quoteError end
    local actor, actorError = self:_actor(source)
    if not actor then return actorError end
    local indexed, lookupError = callService(self._repository, 'findByQuoteId', quoteId)
    if not indexed then
        if type(lookupError) == 'table' and lookupError.error and lookupError.error.code == Codes.REPOSITORY_NOT_FOUND then
            return Result.err(Codes.BOOKING_NOT_FOUND, 'booking for quote was not found')
        end
        return lookupError
    end
    if indexed.id == nil then return failed('quote lookup returned an invalid booking') end
    local booking, bookingError = callService(self._booking, 'get', indexed.id)
    if not booking then return bookingError end
    local bookingClientType = type(booking.clientType) == 'string' and booking.clientType:upper() or nil
    if bookingClientType ~= 'PLAYER' or tostring(booking.clientRef or '') ~= actor.ref then
        return Result.err(Codes.BOOKING_OWNERSHIP_DENIED, 'actor does not own this booking')
    end
    local storedQuoteId = bookingQuoteId(booking)
    local agreedQuote = type(booking.agreedPrice) == 'table' and booking.agreedPrice or nil
    local agreedQuoteId = quoteIdOf(agreedQuote)
    if storedQuoteId ~= quoteId and agreedQuoteId ~= quoteId then
        return Result.err(Codes.QUOTE_INVALID, 'quote is not bound to this booking')
    end
    local status = type(booking.status) == 'string' and booking.status:upper() or nil
    if status == 'RESERVED' then return confirmation(booking) end
    if status == 'QUOTED' then
        booking, bookingError = callService(self._booking, 'offer', actor, booking.id, booking.version)
        if not booking then return bookingError end
        status = 'OFFERED'
    end
    if status == 'OFFERED' then
        booking, bookingError = callService(self._booking, 'accept', actor, booking.id, booking.version)
        if not booking then return bookingError end
        status = 'ACCEPTED'
    end
    if status ~= 'ACCEPTED' then
        return Result.err(Codes.BOOKING_STATE_INVALID, 'booking cannot be confirmed in its current state', { status = status })
    end
    local resources, resourcesError = reservationResources(booking, self._reservationTtl)
    if not resources then return resourcesError end
    local reserved, reserveError = callService(self._booking, 'reserve', actor, booking.id, booking.version, resources)
    if not reserved then return reserveError end
    return confirmation(reserved)
end

NightShift.ClientBookingCommandService = Service
NightShift.ClientBookingCommands = Service

return Service
