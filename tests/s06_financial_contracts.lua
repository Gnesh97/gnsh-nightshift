local function check(value, message) assert(value, message) end

local Result = NightShift.Result
local Clock = NightShift.Clock
local Catalog = NightShift.ServiceCatalog
local Pricing = NightShift.PricingService
local PriceQuote = NightShift.Domain.PriceQuote
local Deposit = NightShift.Domain.Deposit
local DepositService = NightShift.DepositService
local SettlementService = NightShift.SettlementService
local RefundService = NightShift.RefundService
local BookingService = NightShift.BookingService
local Booking = NightShift.Domain.Booking

check(type(Catalog) == 'table', 'S06 service catalog must be loaded')
check(type(Pricing) == 'table', 'S06 pricing service must be loaded')
check(type(PriceQuote) == 'table', 'S06 price quote domain must be loaded')
check(type(Deposit) == 'table', 'S06 deposit domain must be loaded')
check(type(DepositService) == 'table', 'S06 deposit service must be loaded')
check(type(SettlementService) == 'table', 'S06 settlement service must be loaded')
check(type(RefundService) == 'table', 'S06 refund service must be loaded')

do
    local normalized, configError = NightShift.Validators.validateConfig(NightShift.Validators.copy(NightShift.DefaultConfig))
    check(normalized and normalized.serviceCatalog and normalized.pricing and normalized.cancellation and not configError, 'S06 config sections must survive normalization')
    local invalidCatalog = NightShift.Validators.copy(NightShift.DefaultConfig)
    invalidCatalog.serviceCatalog.packages[1].basePriceMinor = 0
    normalized, configError = NightShift.Validators.validateConfig(invalidCatalog)
    check(not normalized and configError.code == NightShift.Errors.Codes.INVALID_PRICE, 'invalid catalog price must fail closed')
    local invalidPricing = NightShift.Validators.copy(NightShift.DefaultConfig)
    invalidPricing.pricing.quoteTtlSeconds = 0
    normalized, configError = NightShift.Validators.validateConfig(invalidPricing)
    check(not normalized and configError.code == 'INVALID_CONFIG', 'invalid pricing TTL must fail closed')
end

local function result(value) return Result.ok(value) end

local function clock()
    return Clock.new({ now = function() return 1700000000 end })
end

local catalog = assert(Catalog.new({
    config = {
        enabled = true,
        currency = 'USD',
        packages = {
            {
                id = 'standard',
                basePriceMinor = 500,
                durationMinutes = 30,
                minClientReputation = 0,
                meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' },
                locationIds = { 'motel_room', 'configured_default' }
            },
            {
                id = 'premium',
                basePriceMinor = 1000,
                durationMinutes = 60,
                minClientReputation = 25,
                meetingModes = { 'COME_TO_ME' },
                locationIds = { 'motel_room' }
            }
        }
    }
}))

do
    local found = catalog:get('STANDARD')
    check(found.ok and found.value.id == 'standard', 'catalog lookup must normalize package IDs')
    local compatible = catalog:resolve('standard', { meetingMode = 'COME_TO_ME', locationId = 'motel_room' })
    check(compatible.ok and compatible.value.durationMinutes == 30, 'catalog must validate meeting/location compatibility')
    local blocked = catalog:resolve('premium', { meetingMode = 'PICKUP', locationId = 'motel_room' })
    check(not blocked.ok and blocked.error.code == NightShift.Errors.Codes.SERVICE_PACKAGE_INCOMPATIBLE, 'incompatible package must fail closed')
    local unknown = catalog:get('client-supplied-price')
    check(not unknown.ok and unknown.error.code == NightShift.Errors.Codes.SERVICE_PACKAGE_NOT_FOUND, 'unknown package must fail closed')
    local disabled = assert(Catalog.new({ config = { enabled = false, currency = 'USD', packages = {} } }))
    check(not disabled:isEnabled() and disabled:list().error.code == NightShift.Errors.Codes.SERVICE_CATALOG_INVALID, 'disabled catalog may omit package definitions without enabling untrusted fallback')
end

local pricing = assert(Pricing.new({
    catalog = catalog,
    clock = clock(),
    config = {
        enabled = true,
        currency = 'USD',
        quoteTtlSeconds = 60,
        minAmountMinor = 1,
        maxAmountMinor = 100000,
        npcPriceClasses = { STANDARD = 1.2 },
        districtModifiers = { ROCKFORD = 1.15 },
        timeModifiers = { LATE_NIGHT = 1.1 },
        demandModifiers = { HIGH = 1.2 },
        reputationModifiers = { LOW = 1.1, TRUSTED = 0.95 },
        fees = { travelMinor = 80, locationMinor = 20 }
    }
}))

do
    local request = {
        servicePackageId = 'standard',
        meetingMode = 'COME_TO_ME',
        locationId = 'motel_room',
        npcPriceClass = 'STANDARD',
        district = 'ROCKFORD',
        timeBand = 'LATE_NIGHT',
        demand = 'HIGH',
        clientReputation = 5,
        travelFeeMinor = 80,
        locationFeeMinor = 20,
        amountMinor = 1
    }
    local first = pricing:quote(request)
    local second = pricing:quote(request)
    check(first.ok and second.ok and first.value.amountMinor == second.value.amountMinor, 'same pricing inputs must be deterministic')
    check(first.value.amountMinor > 1 and first.value.lineItems and #first.value.lineItems > 0, 'quote must include server line items')
    check(first.value.expiresAt ~= nil and first.value.amountMinor ~= request.amountMinor, 'client total must be ignored and quote must expire')
    local clamped = assert(Pricing.new({ catalog = catalog, clock = clock(), config = { maxAmountMinor = 10, minAmountMinor = 5, quoteTtlSeconds = 60 } }))
    local limited = clamped:quote({ servicePackageId = 'standard', meetingMode = 'COME_TO_ME', locationId = 'motel_room', travelFeeMinor = 999999 })
    check(limited.ok and limited.value.amountMinor == 10, 'quote must clamp to configured maximum')
end

do
    local quote = assert(PriceQuote.new({
        id = 'quote:s06:1',
        bookingId = 7,
        amountMinor = 900,
        currency = 'USD',
        issuedAt = '2026-08-29T10:00:00Z',
        expiresAt = '2026-08-29T10:01:00Z'
    }))
    local accepted = quote:accept('2026-08-29T10:00:30Z')
    check(accepted.ok and accepted.value.accepted == true, 'price quote acceptance must freeze a snapshot')
    local changed = accepted.value:withAmount(1)
    check(not changed.ok and changed.error.code == NightShift.Errors.Codes.QUOTE_IMMUTABLE, 'accepted quote cannot be recalculated')
    local expired = assert(PriceQuote.new({ id = 'quote:s06:expired', bookingId = 7, amountMinor = 900, currency = 'USD', issuedAt = '2026-08-29T10:00:00Z', expiresAt = '2026-08-29T10:01:00Z' }))
    check(expired:isExpired('2026-08-29T10:02:00Z'), 'quote expiry must use the server clock')
    local invalidExpiry = PriceQuote.new({ id = 'quote:s06:invalid-expiry', bookingId = 7, amountMinor = 900, currency = 'USD', issuedAt = '2026-08-29T10:00:00Z', expiresAt = 'not-a-timestamp' })
    check(not invalidExpiry, 'unparseable quote expiry must fail closed')
end

do
    local persisted = assert(Booking.new({
        idempotencyKey = 's06-snapshot-row', initiatorType = 'PLAYER',
        clientType = 'PLAYER', clientRef = 'identity:client', workerType = 'NPC', workerRef = 'npc-worker',
        servicePackage = { id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD' },
        meetingMode = 'COME_TO_ME', locationType = 'CONFIGURED', locationRef = 'configured_default',
        quote = { quoteId = 'quote:s06:row', amountMinor = 600, currency = 'USD', quotedAt = '2026-08-29T10:00:00Z', expiresAt = '2026-08-29T10:01:00Z' },
        agreedPrice = { quoteId = 'quote:s06:row', amountMinor = 600, currency = 'USD', agreedAt = '2026-08-29T10:00:30Z' }
    }))
    local row = assert(Booking.toRow(persisted))
    check(row.quote_id == 'quote:s06:row' and row.quote_expires_at == '2026-08-29T10:01:00Z' and row.agreed_quote_id == 'quote:s06:row', 'quote ID and expiry must be persisted with the booking snapshot')
    local roundTrip = assert(Booking.fromRow({
        id = 1, idempotency_key = persisted.idempotencyKey, initiator_type = 'PLAYER', client_type = 'PLAYER', client_ref = persisted.clientRef,
        worker_type = 'NPC', worker_ref = persisted.workerRef, service_package_id = 'standard', price_minor = 500, currency = 'USD',
        mode = 'COME_TO_ME', location_type = 'CONFIGURED', location_ref = 'configured_default', quote_minor = 600, quote_currency = 'USD', quoted_at = row.quoted_at,
        quote_id = row.quote_id, quote_expires_at = row.quote_expires_at, agreed_price_minor = 600, agreed_currency = 'USD', agreed_at = row.agreed_at,
        agreed_quote_id = row.agreed_quote_id, status = 'ACCEPTED', version = 2
    }))
    check(roundTrip.quote.quoteId == persisted.quote.quoteId and roundTrip.quote.expiresAt == persisted.quote.expiresAt and roundTrip.agreedPrice.quoteId == persisted.agreedPrice.quoteId, 'persisted quote snapshot must round-trip without losing the binding')
end

local booking = {
    id = 7,
    status = 'COMPLETED',
    version = 4,
    clientType = 'PLAYER',
    clientRef = 'identity:client',
    workerType = 'PLAYER',
    workerRef = 'identity:worker',
    servicePackage = { id = 'standard', priceMinor = 500, durationMinutes = 30, currency = 'USD' },
    quote = { amountMinor = 600, currency = 'USD', quotedAt = '2026-08-29T10:00:00Z' },
    agreedPrice = { amountMinor = 600, currency = 'USD', agreedAt = '2026-08-29T10:01:00Z' },
    meetingMode = 'COME_TO_ME',
    locationType = 'CONFIGURED',
    locationRef = 'configured_default',
    correlationId = 's06-correlation'
}

local function financialRepository()
    local rows = {}
    local sequence = 0
    return {
        rows = rows,
        findByIdempotencyKey = function(self, key)
            local row = rows[key]
            if row then return result(row) end
            return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found')
        end,
        findByKey = function(self, key) return self:findByIdempotencyKey(key) end,
        findByBooking = function(self, bookingId)
            local out = {}
            for _, row in pairs(rows) do if tostring(row.bookingId) == tostring(bookingId) then out[#out + 1] = row end end
            return result(out)
        end,
        create = function(self, row)
            sequence = sequence + 1
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            copy.id = sequence
            copy.version = 1
            rows[copy.idempotencyKey] = copy
            return result({ insertId = sequence })
        end,
        updateExpectedVersion = function(self, id, expectedVersion, changes)
            for _, row in pairs(rows) do
                if row.id == id then
                    if row.version ~= expectedVersion then return Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'version conflict') end
                    for key, value in pairs(changes) do row[key] = value end
                    row.version = row.version + 1
                    return result({ id = id, version = row.version, affectedRows = 1 })
                end
            end
            return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found')
        end
    }
end

local money = {
    removes = 0,
    adds = 0,
    transfers = 0,
    balance = true,
    has = function(self) return result(self.balance) end,
    remove = function(self, source, account, amount) self.removes = self.removes + 1; return result({ source = source, account = account, amount = amount }) end,
    add = function(self, source, account, amount) self.adds = self.adds + 1; return result({ source = source, account = account, amount = amount }) end,
    transfer = function(self, fromSource, toSource, account, amount) self.transfers = self.transfers + 1; return result({ atomic = true, fromSource = fromSource, toSource = toSource, account = account, amount = amount }) end,
    getCapabilities = function() return { available = true, accounts = { cash = true }, atomicTransfer = true, idempotency = true } end
}

do
    local repository = financialRepository()
    local deposits = assert(DepositService.new({
        repository = repository,
        money = money,
        clock = clock(),
        config = { enabled = true, percentage = 50, account = 'cash' }
    }))
    local held = deposits:hold({ source = 1, account = 'cash' }, booking, { amountMinor = 1 })
    check(held.ok and held.value.amountMinor == 300 and held.value.status == 'HELD', 'deposit amount must be server-derived and persisted as HELD')
    local replay = deposits:hold({ source = 1, account = 'cash' }, booking, { amountMinor = 999 })
    check(replay.ok and replay.metadata and replay.metadata.idempotent and money.removes == 1, 'deposit capture must be exactly-once')
    local released = deposits:release(booking, { source = 1, account = 'cash' })
    check(released.ok and released.value.status == 'REFUNDED' and money.adds == 1, 'deposit release must refund once')
    local replayRelease = deposits:release(booking, { source = 1, account = 'cash' })
    check(replayRelease.ok and money.adds == 1, 'deposit release retry must not add money twice')
end

do
    local poorMoney = {
        has = function() return result(false) end,
        remove = function() error('remove must not run for insufficient funds') end,
        add = function() return result(true) end,
        getCapabilities = function() return { idempotency = true } end
    }
    local deposits = assert(DepositService.new({
        repository = financialRepository(), money = poorMoney,
        config = { enabled = true, percentage = 50, account = 'cash' }
    }))
    local insufficient = deposits:hold({ source = 1 }, booking)
    check(not insufficient.ok and insufficient.error.code == NightShift.Errors.Codes.DEPOSIT_INSUFFICIENT_FUNDS, 'insufficient deposit funds must fail before debit')
end

do
    local repository = financialRepository()
    local bookingTransitions = 0
    local bookingService = {
        get = function() return result(booking) end,
        settle = function() bookingTransitions = bookingTransitions + 1; return result({ status = 'SETTLED' }) end
    }
    local settlement = assert(SettlementService.new({
        bookingService = bookingService,
        repository = repository,
        money = money,
        clock = clock(),
        config = { enabled = true, account = 'cash' }
    }))
    local settled = settlement:settle({ source = 1, account = 'cash' }, booking, { payerSource = 1, payeeSource = 2, amountMinor = 1 })
    check(settled.ok and settled.value.status == 'SETTLED' and money.transfers == 1 and bookingTransitions == 1, 'settlement must use frozen price and transition only after payment')
    local replay = settlement:settle({ source = 1, account = 'cash' }, booking, { payerSource = 1, payeeSource = 2, amountMinor = 999 })
    check(replay.ok and replay.metadata and replay.metadata.idempotent and money.transfers == 1 and bookingTransitions == 1, 'settlement replay must not charge or transition twice')
end

do
    local repository = financialRepository()
    local commissionCalls = 0
    local settlement = assert(SettlementService.new({
        bookingService = { settle = function() return result({ status = 'SETTLED' }) end },
        repository = repository,
        money = money,
        commissionHook = function(_, payment)
            commissionCalls = commissionCalls + 1
            return { feeMinor = math.floor(payment.amountMinor * 0.1) }
        end,
        config = { enabled = true, account = 'cash' }
    }))
    local settled = settlement:settle({ source = 1 }, booking, { payerSource = 1, payeeSource = 2 })
    check(settled.ok and settled.value.commission.feeMinor == 60 and commissionCalls == 1, 'settlement must expose the optional commission hook after financial commit')
end

do
    local repository = financialRepository()
    local commissionCalls, bookingTransitions = 0, 0
    local settlement = assert(SettlementService.new({
        bookingService = { settle = function() bookingTransitions = bookingTransitions + 1; return result({ status = 'SETTLED' }) end },
        repository = repository,
        money = money,
        commissionHook = function()
            commissionCalls = commissionCalls + 1
            if commissionCalls == 1 then return false end
            return { feeMinor = 60 }
        end,
        config = { enabled = true, account = 'cash' }
    }))
    local first = settlement:settle({ source = 1 }, booking, { payerSource = 1, payeeSource = 2 })
    local retry = settlement:settle({ source = 1 }, booking, { payerSource = 1, payeeSource = 2 })
    check(not first.ok and first.error.details.paymentCommitted and retry.ok and bookingTransitions == 1 and commissionCalls == 2, 'post-commit settlement failures must resume from the durable payment intent without charging twice')
end

do
    local settlement = assert(SettlementService.new({
        repository = financialRepository(), money = money,
        config = { enabled = true, account = 'cash' }
    }))
    local rejected = settlement:settle({ source = 1 }, booking, { payerSource = 1, payeeSource = 2 })
    check(not rejected.ok and rejected.error.code == NightShift.Errors.Codes.SETTLEMENT_NOT_READY, 'settlement must require a canonical booking transition service')
end

do
    local repository = financialRepository()
    local failedMoney = {
        transfer = function() return Result.err(NightShift.Errors.Codes.MONEY_OPERATION_FAILED, 'provider failed') end,
        getCapabilities = function() return { atomicTransfer = true, idempotency = true } end
    }
    local bookingTransitions = 0
    local settlement = assert(SettlementService.new({
        bookingService = { settle = function() bookingTransitions = bookingTransitions + 1; return result({ status = 'SETTLED' }) end },
        repository = repository, money = failedMoney, config = { enabled = true, account = 'cash' }
    }))
    local failed = settlement:settle({ source = 1 }, booking, { payeeSource = 2 })
    check(not failed.ok and failed.error.code == NightShift.Errors.Codes.SETTLEMENT_OPERATION_FAILED and failed.error.details.status == 'UNKNOWN' and bookingTransitions == 0, 'settlement provider failure must keep booking unsettled and mark uncertainty')
end

do
    local repository = financialRepository()
    local refunds = assert(RefundService.new({ repository = repository, money = money, clock = clock(), config = { enabled = true, account = 'cash', percentages = { DRAFT = 100, ACCEPTED = 90, EN_ROUTE = 75, TRAVELLING = 75, ARRIVED = 50, ACTIVE = 0 } } }))
    local draft = {}
    for key, value in pairs(booking) do draft[key] = value end
    draft.id, draft.status = 8, 'DRAFT'
    local before = refunds:calculate(draft)
    check(before.ok and before.value.amountMinor == 600, 'pre-assignment cancellation must refund the frozen amount')
    local active = {}
    for key, value in pairs(booking) do active[key] = value end
    active.id, active.status = 9, 'ACTIVE'
    local none = refunds:calculate(active)
    check(none.ok and none.value.amountMinor == 0, 'active cancellation must not auto-refund')
    local enRoute = {}
    for key, value in pairs(booking) do enRoute[key] = value end
    enRoute.id, enRoute.status = 11, 'EN_ROUTE'
    local enRoutePolicy = refunds:calculate(enRoute)
    check(enRoutePolicy.ok and enRoutePolicy.value.percentage == 75, 'en-route cancellation policy must use the configured state alias')
    local applied = refunds:refund({ source = 1, account = 'cash' }, draft, { amountMinor = 1 })
    check(applied.ok and applied.value.amountMinor == 600, 'refund amount must be server-computed')
    local replay = refunds:refund({ source = 1, account = 'cash' }, draft, { amountMinor = 999 })
    check(replay.ok and replay.metadata and replay.metadata.idempotent, 'refund must be idempotent')
end

do
    local retained = false
    local refunds = assert(RefundService.new({
        repository = financialRepository(), money = money,
        depositService = { retain = function() retained = true; return result({ status = 'RETAINED' }) end },
        config = { enabled = true, account = 'cash', percentages = { ACTIVE = 0 } }
    }))
    local active = {}
    for key, value in pairs(booking) do active[key] = value end
    active.id, active.status = 10, 'ACTIVE'
    local noEffect = refunds:refund({ source = 1 }, active, { amountMinor = 999 })
    check(noEffect.ok and noEffect.value.amountMinor == 0 and retained, 'active cancellation must retain the deposit without minting a refund')
end

do
    local rows, byKey, sequence = {}, {}, 0
    local function clone(value, seen)
        if type(value) ~= 'table' then return value end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local output = {}
        seen[value] = output
        for key, item in pairs(value) do output[clone(key, seen)] = clone(item, seen) end
        return output
    end
    local repository = {}
    function repository:findById(id)
        local row = rows[tonumber(id)]
        return row and result(clone(row)) or Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found')
    end
    function repository:findByIdempotencyKey(key)
        local row = byKey[key]
        return row and result(clone(row)) or Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found')
    end
    function repository:create(value)
        sequence = sequence + 1
        local row = clone(value)
        row.id, row.version = sequence, 1
        rows[row.id], byKey[row.idempotencyKey] = row, row
        return result({ insertId = row.id })
    end
    function repository:updateExpectedVersion(id, expectedVersion, changes)
        local row = rows[tonumber(id)]
        if not row then return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found') end
        if row.version ~= expectedVersion then return Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'version conflict') end
        local nextRow = clone(row)
        for key, value in pairs(changes or {}) do nextRow[key] = clone(value) end
        nextRow.version = row.version + 1
        rows[row.id], byKey[row.idempotencyKey] = nextRow, nextRow
        return result({ id = row.id, version = nextRow.version })
    end
    local timeline = { record = function() return result({ id = 1 }) end }
    local service = assert(BookingService.new({
        repository = repository,
        timelineService = timeline,
        catalogResolver = catalog,
        quoteResolver = pricing,
        clock = clock()
    }))
    local actor = { type = 'PLAYER', ref = 'identity:worker' }
    local draft = service:createDraft(actor, {
        idempotencyKey = 's06-booking-integration',
        initiatorType = 'PLAYER', clientType = 'NPC', clientRef = 'npc-client',
        workerType = 'PLAYER', workerRef = actor.ref,
        servicePackage = { id = 'standard', priceMinor = 1, durationMinutes = 1, currency = 'USD' },
        meetingMode = 'COME_TO_ME', locationType = 'CONFIGURED', locationRef = 'configured_default'
    })
    check(draft.ok and draft.value.servicePackage.priceMinor == 500, 'BookingService must resolve the catalog package server-side')
    local quoted = service:applyQuote(actor, draft.value.id, { amountMinor = 1, npcPriceClass = 'STANDARD' }, draft.value.version)
    check(quoted.ok and quoted.value.quote.quoteId and quoted.value.quote.amountMinor ~= 1, 'BookingService must attach an authoritative quote snapshot')
    local offered = service:offer(actor, draft.value.id, quoted.value.version)
    check(offered.ok, 'BookingService must expose the offer transition before acceptance')
    local accepted = service:accept(actor, draft.value.id, offered.value.version)
    check(accepted.ok and accepted.value.agreedPrice.amountMinor == quoted.value.quote.amountMinor and accepted.value.agreedPrice.quoteId == quoted.value.quote.quoteId, 'acceptance must freeze the quote amount and ID')
    local idDraft = service:createDraft(actor, {
        idempotencyKey = 's06-booking-package-id',
        initiatorType = 'PLAYER', clientType = 'NPC', clientRef = 'npc-client',
        workerType = 'PLAYER', workerRef = actor.ref,
        servicePackageId = 'standard', meetingMode = 'COME_TO_ME',
        locationType = 'CONFIGURED', locationRef = 'configured_default'
    })
    check(idDraft.ok and idDraft.value.servicePackage.id == 'standard', 'BookingService must accept a package ID while retaining catalog authority')
end

print('NS-060/NS-061/NS-062/NS-063/NS-064/NS-065 tests passed: catalog, quotes, price freeze, deposits, settlement, and refunds')
