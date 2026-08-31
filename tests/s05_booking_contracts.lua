local function check(value, message) assert(value, message) end

local Booking = NightShift.Domain and NightShift.Domain.Booking
check(type(Booking) == 'table', 'S05 booking domain must be loaded')
local StateMachine = NightShift.BookingStateMachine
check(type(StateMachine) == 'table', 'S05 booking state machine must be loaded')
local Timeline = NightShift.BookingTimelineService
check(type(Timeline) == 'table', 'S05 booking timeline service must be loaded')
local Reservations = NightShift.Reservations
check(type(Reservations) == 'table', 'S05 reservation lock manager must be loaded')
local ReservationService = NightShift.BookingReservationService
check(type(ReservationService) == 'table', 'S05 reservation service must be loaded')
local BookingService = NightShift.BookingService
check(type(BookingService) == 'table', 'S05 booking service must be loaded')

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function result(value) return NightShift.Result.ok(value) end

local function bookingInput(overrides)
    local value = {
        idempotencyKey = 's05-booking-1',
        initiatorType = 'PLAYER',
        clientType = 'NPC',
        clientRef = 'npc-client-1',
        workerType = 'PLAYER',
        workerRef = 'identity:worker-1',
        servicePackage = { id = 'standard', priceMinor = 10000, durationMinutes = 30, currency = 'USD' },
        meetingMode = 'IN_PERSON',
        locationType = 'CONFIGURED',
        locationRef = 'configured_default',
        correlationId = 's05-correlation-1',
        externalReference = 'ext-s05-1'
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

do
    local playerWorker = assert(Booking.new(bookingInput()))
    check(playerWorker.clientType == 'NPC' and playerWorker.workerType == 'PLAYER', 'player-worker/NPC-client shape must normalize')
    check(playerWorker.status == 'DRAFT' and playerWorker.version == 1, 'new booking must start as DRAFT version 1')
    check(playerWorker.servicePackage.priceMinor == 10000, 'service package price snapshot must be retained')

    local npcWorker = assert(Booking.new(bookingInput({
        idempotencyKey = 's05-booking-2',
        clientType = 'PLAYER', clientRef = 'identity:client-1',
        workerType = 'NPC', workerRef = 'npc-worker-1'
    })))
    check(npcWorker.clientType == 'PLAYER' and npcWorker.workerType == 'NPC', 'player-client/NPC-worker shape must normalize')

    local row = assert(Booking.toRow(playerWorker))
    check(row.service_package_id == 'standard' and row.mode == 'IN_PERSON', 'booking row must map package and meeting mode')
    check(row.client_type == 'NPC' and row.worker_type == 'PLAYER', 'booking row must persist participant types')
    local priced = assert(Booking.new(bookingInput({
        quote = { amountMinor = 12000, currency = 'USD', quotedAt = '2026-08-29T12:00:00Z' },
        agreedPrice = { amountMinor = 12000, currency = 'USD', agreedAt = '2026-08-29T12:01:00Z' }
    })))
    local pricedRow = assert(Booking.toRow(priced))
    check(pricedRow.quoted_at == '2026-08-29T12:00:00Z' and pricedRow.agreed_at == '2026-08-29T12:01:00Z', 'price snapshot timestamps must persist')
    local roundTrip = assert(Booking.fromRow(row))
    check(roundTrip.clientRef == playerWorker.clientRef and roundTrip.workerRef == playerWorker.workerRef, 'booking row mapping must preserve participant refs')

    local databaseRow = copy(row)
    databaseRow.id, databaseRow.version, databaseRow.status = 7, 2, 'QUOTED'
    databaseRow.quote_minor, databaseRow.quote_currency = 12000, 'USD'
    databaseRow.quoted_at = '2026-08-29 12:00:00.000'
    databaseRow.quote_id, databaseRow.quote_expires_at = 'quote:s05:database', false
    databaseRow.created_at, databaseRow.updated_at = '2026-08-29 11:59:00.000', '2026-08-29 12:00:00.000'
    local databaseRoundTrip = assert(Booking.fromRow(databaseRow))
    check(databaseRoundTrip.quote.quotedAt == '2026-08-29T12:00:00Z' and databaseRoundTrip.quote.expiresAt == nil, 'database DATETIME rows must normalize to UTC timestamps and ignore zero-date expiry values')
    check(databaseRoundTrip.createdAt == '2026-08-29T11:59:00Z', 'database managed timestamps must normalize to the domain timestamp shape')
    databaseRow.quoted_at = 1700000000000
    local millisecondRoundTrip = assert(Booking.fromRow(databaseRow))
    check(millisecondRoundTrip.quote.quotedAt == '2023-11-14T22:13:20Z', 'millisecond database timestamps must normalize to UTC seconds')
    databaseRow.quoted_at = '2026-08-29 12:00:00.000'
    databaseRow.quote_expires_at = '0000-00-00 00:00:00.000'
    local zeroDateRoundTrip = assert(Booking.fromRow(databaseRow))
    check(zeroDateRoundTrip.quote.expiresAt == nil, 'zero-date DATETIME strings must be treated as absent nullable timestamps')
    for _, invalidExpiry in ipairs({ -1, 0, math.huge, -math.huge, 0 / 0 }) do
        databaseRow.quote_expires_at = invalidExpiry
        local invalidNumericRoundTrip = assert(Booking.fromRow(databaseRow))
        check(invalidNumericRoundTrip.quote.expiresAt == nil, 'invalid numeric DATETIME sentinels must be treated as absent nullable timestamps')
    end

    local nullSentinelRow = copy(databaseRow)
    nullSentinelRow.quote_minor, nullSentinelRow.quote_currency, nullSentinelRow.quote_id = false, false, false
    nullSentinelRow.agreed_price_minor, nullSentinelRow.agreed_currency, nullSentinelRow.agreed_quote_id = false, false, false
    local nullSentinelRoundTrip = assert(Booking.fromRow(nullSentinelRow))
    check(nullSentinelRoundTrip.quote == nil and nullSentinelRoundTrip.agreedPrice == nil, 'false SQL NULL sentinels must map to absent price snapshots')
    nullSentinelRow.quote_minor, nullSentinelRow.quote_currency, nullSentinelRow.quote_id = '', '', ''
    nullSentinelRow.agreed_price_minor, nullSentinelRow.agreed_currency, nullSentinelRow.agreed_quote_id = '', '', ''
    local emptySentinelRoundTrip = assert(Booking.fromRow(nullSentinelRow))
    check(emptySentinelRoundTrip.quote == nil and emptySentinelRoundTrip.agreedPrice == nil, 'empty SQL NULL sentinels must map to absent price snapshots')

    local invalid, invalidError = Booking.new(bookingInput({ clientType = 'PLAYER', clientRef = '' }))
    check(not invalid and invalidError.error.code == NightShift.Errors.Codes.BOOKING_INVALID, 'invalid participant ref must fail closed')
end

do
    local calls = {}
    local stored
    local function parseInsert(sql, params)
        local body = sql:match('INSERT INTO.-%((.-)%) VALUES')
        local row = {}
        local index = 0
        for field in (body or ''):gmatch('([A-Za-z_][A-Za-z0-9_]*)') do
            index = index + 1
            row[field] = params[index]
        end
        row.id, row.version = 7, 1
        stored = row
    end
    local db = {}
    function db:single(sql, params)
        calls.single = { sql = sql, params = copy(params) }
        return result(stored)
    end
    function db:query(sql, params)
        calls.query = { sql = sql, params = copy(params) }
        return result(stored and { copy(stored) } or {})
    end
    function db:insert(sql, params)
        calls.insert = { sql = sql, params = copy(params) }
        parseInsert(sql, params)
        return result({ insertId = 7 })
    end
    function db:update(sql, params)
        calls.update = { sql = sql, params = copy(params) }
        return result({ affectedRows = 1 })
    end
    function db:scalar() return result(1) end

    local repository = assert(NightShift.Repositories.Booking.new({ db = db }))
    local booking = assert(Booking.new(bookingInput()))
    local created = repository:create(booking)
    check(created.ok and created.value and created.value.insertId == 7, 'booking repository must persist a normalized domain row')
    check(calls.insert.sql:find('service_package_id', 1, true) ~= nil, 'booking repository must include package ID')
    local found = repository:findByIdempotencyKey('s05-booking-1')
    check(found.ok and found.value.id == 7, 'booking repository must find by idempotency key')
    check(calls.single.params[1] == 's05-booking-1', 'booking idempotency lookup must be parameterized')
    local updated = repository:updateExpectedVersion(7, 1, {
        status = 'QUOTED',
        quote = { amountMinor = 12000, currency = 'USD', quotedAt = '2026-08-29T12:00:00Z' }
    })
    check(updated.ok and updated.value.version == 2 and calls.update.sql:find('quote_minor', 1, true) ~= nil, 'booking repository updates must be versioned and snapshot-aware')
    local expiryEpoch = 1700000000
    local expiryUpdate = repository:updateExpectedVersion(7, 2, {
        quote = { amountMinor = 12000, currency = 'USD', quotedAt = expiryEpoch, expiresAt = expiryEpoch + 300 }
    })
    local expectedExpiry = os.date('!%Y-%m-%d %H:%M:%S.000', expiryEpoch + 300)
    local expirySerialized = false
    for _, parameter in ipairs(calls.update.params or {}) do
        if parameter == expectedExpiry then expirySerialized = true end
    end
    check(expiryUpdate.ok and expirySerialized, 'numeric booking timestamps must be serialized as UTC MariaDB DATETIME values')
    local immutable = repository:updateExpectedVersion(7, 1, { workerRef = 'other' })
    check(not immutable.ok and immutable.error.code == NightShift.Errors.Codes.REPOSITORY_INVALID, 'booking participants must remain immutable')
end

do
    local machine = assert(StateMachine.new())
    check(machine:canTransition('DRAFT', 'QUOTED').ok, 'DRAFT to QUOTED must be allowed')
    check(machine:canTransition('ARRIVED', 'ACTIVE').ok, 'ARRIVED to ACTIVE must be allowed')
    check(machine:canTransition('COMPLETED', 'SETTLED').ok, 'COMPLETED to SETTLED must be allowed')
    check(not machine:canTransition('OFFERED', 'SETTLED').ok, 'OFFERED to SETTLED must be rejected')

    local draft = assert(Booking.new(bookingInput()))
    local quoted = assert(machine:transition(draft, 'QUOTED', { actorType = 'PLAYER', actorRef = 'identity:worker-1', reason = 'quote-created' })).value.booking
    check(quoted.status == 'QUOTED' and quoted.version == 2, 'valid transition must increment version immutably')
    local terminal = assert(Booking.new(bookingInput({ status = 'SETTLED', version = 4 })))
    local reactivated = machine:transition(terminal, 'ACTIVE')
    check(not reactivated.ok and reactivated.error.code == NightShift.Errors.Codes.BOOKING_STATE_INVALID, 'terminal state cannot reactivate')
end

do
    local events = {}
    local eventRepository = {
        create = function(_, event) events[#events + 1] = copy(event); return result({ id = #events }) end,
        findByKey = function(_, bookingId, eventKey)
            for _, event in ipairs(events) do
                if event.bookingId == bookingId and event.eventKey == eventKey then return result(event) end
            end
            return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'event not found')
        end,
        findByBooking = function(_, bookingId)
            local output = {}
            for _, event in ipairs(events) do if event.bookingId == bookingId then output[#output + 1] = copy(event) end end
            return result(output)
        end
    }
    local timeline = assert(Timeline.new({ repository = eventRepository, clock = { timestamp = function() return '2026-08-29T12:00:00Z' end } }))
    local booking = assert(Booking.new(bookingInput({ id = 77 })))
    local first = timeline:record(booking, 'DRAFT', 'QUOTED', { actorType = 'PLAYER', actorRef = 'identity:worker-1', reason = 'quote-created' })
    check(first.ok and #events == 1 and events[1].oldState == 'DRAFT' and events[1].newState == 'QUOTED', 'timeline must record old and new booking state')
    local duplicate = timeline:record(booking, 'DRAFT', 'QUOTED', { actorType = 'PLAYER', actorRef = 'identity:worker-1', reason = 'quote-created' })
    check(duplicate.ok and #events == 1, 'timeline event key must be idempotent')
    local history = assert(timeline:history(77)).value
    check(#history == 1 and history[1].eventType == 'STATE_CHANGED', 'timeline history must list state events')
end

do
    local locks = assert(Reservations.new({ clock = { now = function() return 100 end } }))
    local reservationService = assert(ReservationService.new({ locks = locks, clock = { now = function() return 100 end } }))
    local bookingId = 'booking-atomic-1'
    local first = reservationService:reserve(bookingId, {
        { type = 'NPC', id = 'npc-1', ttlSeconds = 60 },
        { type = 'LOCATION', id = 'room-1', ttlSeconds = 60 }
    })
    check(first.ok, 'reservation should acquire ordered resources')
    local retry = reservationService:reserve(bookingId, {
        { type = 'NPC', id = 'npc-1', ttlSeconds = 60 },
        { type = 'LOCATION', id = 'room-1', ttlSeconds = 60 }
    })
    check(retry.ok and retry.value.idempotent == true, 'retry must not duplicate an existing reservation')
    local incremental = reservationService:reserve(bookingId, {
        { type = 'LOCATION', id = 'room-2', ttlSeconds = 60 }
    })
    check(incremental.ok and #reservationService:active(bookingId).value == 3, 'incremental reservation must retain the existing booking resources')

    local failed = reservationService:reserve('booking-atomic-2', {
        { type = 'NPC', id = 'npc-2', ttlSeconds = 60 },
        { type = 'LOCATION', id = 'room-1', ttlSeconds = 60 }
    })
    check(not failed.ok and failed.error.code == NightShift.Errors.Codes.RESERVATION_CONFLICT, 'location conflict must fail the whole reservation')
    check(not locks:isReserved('NPC', 'npc-2').value.reserved, 'failed location must roll back the NPC lock')

    local other = reservationService:reserve('booking-atomic-3', {
        { type = 'NPC', id = 'npc-3', ttlSeconds = 60 }
    })
    check(other.ok, 'independent booking should retain its reservation')
    local released = reservationService:releaseBooking(bookingId)
    check(released.ok and released.value.released == 3, 'releaseBooking must release all requested booking resources')
    check(not locks:isReserved('NPC', 'npc-1').value.reserved and not locks:isReserved('LOCATION', 'room-2').value.reserved and locks:isReserved('NPC', 'npc-3').value.reserved, 'releaseBooking must not release another booking')
    local releasedAgain = reservationService:releaseBooking(bookingId)
    check(releasedAgain.ok and releasedAgain.value.idempotent == true, 'releaseBooking must be idempotent')
    local numeric = reservationService:reserve(17, {
        { type = 'LOCATION', id = 'room-numeric', ttlSeconds = 60 }
    })
    check(numeric.ok and reservationService:release(17).ok, 'numeric booking IDs must release their string-normalized locks')
end

local function newMemoryBookingRepository()
    local repo = { rows = {}, nextId = 1, forcedConflict = false }
    function repo:findById(id)
        local row = self.rows[tonumber(id)]
        if not row then return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'booking not found') end
        return result(copy(row))
    end
    function repo:findByIdempotencyKey(key)
        for _, row in pairs(self.rows) do if row.idempotencyKey == key then return result(copy(row)) end end
        return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'booking not found')
    end
    function repo:create(booking)
        local row = copy(booking)
        row.id = self.nextId; self.nextId = self.nextId + 1
        row.version = 1; self.rows[row.id] = row
        return result({ insertId = row.id })
    end
    function repo:updateExpectedVersion(id, version, changes)
        local row = self.rows[tonumber(id)]
        if not row then return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'booking not found') end
        if self.forcedConflict or row.version ~= version then
            self.forcedConflict = false
            return NightShift.Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'stale booking version')
        end
        local nextRow = copy(row)
        for key, value in pairs(changes) do nextRow[key] = copy(value) end
        nextRow.version = version + 1
        self.rows[row.id] = nextRow
        return result({ id = row.id, version = nextRow.version })
    end
    return repo
end

do
    local repo = newMemoryBookingRepository()
    local timelineEvents = {}
    local timeline = {
        record = function(_, booking, oldState, newState, metadata)
            timelineEvents[#timelineEvents + 1] = { bookingId = booking.id, oldState = oldState, newState = newState, metadata = copy(metadata) }
            return result({ id = #timelineEvents })
        end
    }
    local service = assert(BookingService.new({
        repository = repo,
        timelineService = timeline,
        catalogResolver = function(id)
            check(id == 'standard', 'catalog resolver must receive only the package identifier')
            return result({ id = id, priceMinor = 10000, durationMinutes = 30, currency = 'USD' })
        end,
        quoteResolver = function() return result({ amountMinor = 12000, currency = 'USD' }) end,
        clock = { timestamp = function() return '2026-08-29T12:00:00Z' end }
    }))
    local draft = service:createDraft({ type = 'PLAYER', ref = 'identity:worker-1' }, bookingInput({ priceMinor = 1 }))
    check(draft.ok and draft.value.servicePackage.priceMinor == 10000, 'server catalog must own the initial package price')
    local quoted = service:applyQuote({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, { amountMinor = 1 }, 1)
    check(quoted.ok and quoted.value.quote.amountMinor == 12000, 'server quote resolver must own the agreed quote')
    local offered = service:offer({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 2)
    check(offered.ok and offered.value.status == 'OFFERED', 'booking offer must use the state machine')
    local accepted = service:accept({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 3)
    check(accepted.ok and accepted.value.status == 'ACCEPTED', 'booking accept must use expected version')

    local expiredDraft = service:createDraft({ type = 'PLAYER', ref = 'identity:worker-1' }, bookingInput({ idempotencyKey = 's05-booking-expired-quote' }))
    local expiredQuoted = service:applyAuthoritativeQuote({ type = 'PLAYER', ref = 'identity:worker-1' }, expiredDraft.value.id, { amountMinor = 12000, currency = 'USD', quotedAt = '2026-08-29T11:00:00Z', expiresAt = '2026-08-29T11:01:00Z' }, 1)
    local expiredOffered = service:offer({ type = 'PLAYER', ref = 'identity:worker-1' }, expiredDraft.value.id, expiredQuoted.value.version)
    local expiredAccepted = service:accept({ type = 'PLAYER', ref = 'identity:worker-1' }, expiredDraft.value.id, expiredOffered.value.version)
    check(not expiredAccepted.ok and expiredAccepted.error.code == NightShift.Errors.Codes.QUOTE_EXPIRED, 'expired booking quotes must return a quote error instead of crashing')

    local permissionCalls = 0
    local permissionService = {
        authorize = function(_, source, permission)
            permissionCalls = permissionCalls + 1
            check(source == 42 and permission == 'booking.manage', 'booking permission service must receive the player source and capability')
            return result({ allowed = true })
        end
    }
    local permissionedService = assert(BookingService.new({
        repository = repo,
        timelineService = timeline,
        permissionService = permissionService,
        catalogResolver = function(id)
            return result({ id = id, priceMinor = 10000, durationMinutes = 30, currency = 'USD' })
        end
    }))
    local permissionedDraft = permissionedService:createDraft(
        { type = 'PLAYER', ref = 'identity:permissioned', source = 42 },
        bookingInput({
            idempotencyKey = 's05-booking-permission-service',
            workerRef = 'identity:another-worker'
        })
    )
    check(permissionedDraft.ok and permissionCalls == 1, 'booking creation must use the injected permission service without a method collision')

    local stale = service:cancel({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 3, 'client-request')
    check(not stale.ok and stale.error.code == NightShift.Errors.Codes.VERSION_CONFLICT, 'stale booking version must be rejected')
    local cancelled = service:cancel({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 4, 'client-request')
    check(cancelled.ok and cancelled.value.status == 'CANCELLED', 'cancel must persist through the state machine')

    local terminal = service:complete({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 5, function() return true end)
    check(not terminal.ok and terminal.error.code == NightShift.Errors.Codes.BOOKING_STATE_INVALID, 'double completion or terminal completion must fail')

    local unauthorized = service:createDraft({ type = 'PLAYER', ref = 'identity:other' }, bookingInput({ idempotencyKey = 's05-booking-unauthorized' }))
    check(not unauthorized.ok and unauthorized.error.code == NightShift.Errors.Codes.BOOKING_OWNERSHIP_DENIED, 'unrelated player cannot create a booking for another actor')

    local noCatalog = assert(BookingService.new({ repository = repo, timelineService = timeline }))
    local untrustedCatalog = noCatalog:createDraft({ type = 'PLAYER', ref = 'identity:worker-1' }, bookingInput({ idempotencyKey = 's05-booking-no-catalog' }))
    check(not untrustedCatalog.ok and untrustedCatalog.error.code == NightShift.Errors.Codes.BOOKING_INVALID, 'booking creation must fail closed without a server catalog resolver')

    local guarded = service:markArrival({ type = 'PLAYER', ref = 'identity:worker-1' }, draft.value.id, 5, function()
        return NightShift.Result.ok({ allowed = false })
    end)
    check(not guarded.ok and guarded.error.code == NightShift.Errors.Codes.BOOKING_GUARD_FAILED, 'trusted arrival verifier must reject an explicit denial result')
end

print('NS-050..NS-054 tests passed: unified booking, state machine, timeline, service, and atomic reservations')
