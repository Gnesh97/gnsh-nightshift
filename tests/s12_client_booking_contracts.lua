local function check(value, message)
    assert(value, message)
end

local function booking(id, status, workerRef)
    return {
        id = id,
        status = status,
        workerRef = workerRef,
        meetingMode = 'IN_PERSON',
        locationType = 'configured_default',
        servicePackage = { id = 'standard', priceMinor = 500, currency = 'USD' },
        agreedPrice = { amountMinor = 481, currency = 'USD' },
        scheduledAt = 1893456000,
        startAt = status == 'ACTIVE' and 1893455900 or nil,
        completedAt = status == 'SETTLED' and '2030-01-01T00:30:00Z' or nil
    }
end

do
    local calls = {}
    local repository = {
        findForClient = function(self, scope, options)
            calls[#calls + 1] = { scope = scope, options = options }
            local first = options.statuses[1]
            if first == 'TRAVELLING' then return NightShift.Result.ok({ items = { booking(1, 'ACTIVE', 'npc-1') }, total = 1 }) end
            if first == 'DRAFT' then return NightShift.Result.ok({ items = { booking(2, 'RESERVED', 'npc-2') }, total = 1 }) end
            return NightShift.Result.ok({ items = { booking(3, 'SETTLED', 'npc-3') }, total = 4 })
        end
    }
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = tostring(source) .. ':license|2:cid' }) end }
    local profile = { get = function() return NightShift.Result.ok({ id = 42 }) end }
    local workers = { get = function(_, key) return NightShift.Result.ok({ workerKey = key, alias = 'Maya', traits = { hidden = true }, reliability = 0.99 }) end }
    local service, err = NightShift.ClientBookingQueryService.new({
        repository = repository,
        identityService = identity,
        clientProfileService = profile,
        workerService = workers,
        etaResolver = function(item) return item.id == 1 and 8 or nil end,
        maxPageSize = 10
    })
    check(service and not err, 'client booking query service should construct')
    local result = service:list(17, { limit = 2, offset = 0 })
    check(result.ok and result.value.current.bookingId == '1', 'current booking should be exposed')
    check(result.value.current.workerName == 'Maya' and result.value.current.workerId == nil, 'worker identity should not expose internal worker references')
    check(result.value.current.etaMinutes == 8, 'current ETA should be exposed from resolver')
    check(result.value.current.traits == nil and result.value.current.reliability == nil, 'internal worker traits must not leak')
    check(result.value.upcoming[1].status == 'RESERVED' and result.value.history[1].status == 'SETTLED', 'booking groups should be mapped')
    check(result.value.total == 4 and result.value.limit == 2 and result.value.offset == 0, 'history pagination should be preserved')
    check(#calls == 3 and calls[1].scope.clientRef == '17:license|2:cid' and calls[1].scope.clientProfileId == 42, 'all queries must be identity scoped')
    local invalid = service:list(17, { limit = 0 })
    check(not invalid.ok and invalid.error.code == 'CLIENT_BOOKING_INVALID', 'invalid pagination should fail closed')
end

do
    local queries = {}
    local row = {
        id = 91, idempotency_key = 'booking-91', initiator_type = 'PLAYER', client_type = 'PLAYER',
        client_ref = '17:license|2:cid', worker_type = 'NPC', worker_ref = 'npc-1',
       client_profile_id = 42, service_package_id = 'standard', mode = 'IN_PERSON', meeting_mode = 'IN_PERSON',
        location_type = 'CONFIGURED', location_ref = 'configured_default', quote_minor = nil, quote_currency = nil, quoted_at = nil,
        quote_id = nil, quote_expires_at = nil, agreed_price_minor = 481, agreed_currency = 'USD',
        agreed_at = '2030-01-01 00:00:00', agreed_quote_id = 'quote-91', price_minor = 481, currency = 'USD',
        status = 'RESERVED', correlation_id = 'corr-91', external_reference = nil, scheduled_at = '2030-01-02 00:00:00',
        started_at = nil, ended_at = nil, completed_at = nil, version = 1, created_at = '2030-01-01 00:00:00',
        updated_at = '2030-01-01 00:00:00'
    }
    local db = {
        query = function(_, sql, params) queries[#queries + 1] = { sql = sql, params = params }; return NightShift.Result.ok({ row }) end,
        scalar = function(_, sql, params) queries[#queries + 1] = { sql = sql, params = params }; return NightShift.Result.ok(1) end
    }
    local repository, err = NightShift.Repositories.Booking.new({ db = db })
    check(repository and not err, 'booking repository should construct for read model')
    local result = repository:findForClient({ clientRef = '17:license|2:cid', clientProfileId = 42 }, { statuses = { 'RESERVED' }, limit = 5, offset = 0, order = 'ASC' })
    check(result.ok and result.value.total == 1 and result.value.items[1].id == 91, 'client booking repository should map rows')
    check(queries[1].sql:find('client_profile_id', 1, true) and queries[1].sql:find('client_ref', 1, true) and queries[1].sql:find('status IN', 1, true), 'client query should include safe scope predicates')
    local quoteResult = repository:findByQuoteId('quote-91')
    check(quoteResult.ok and quoteResult.value.id == 91, 'quote lookup should map the booking by its agreed quote ID')
    check(queries[#queries].sql:find('quote_id', 1, true) and queries[#queries].sql:find('agreed_quote_id', 1, true) and queries[#queries].sql:find('LIMIT 2', 1, true), 'quote lookup should inspect both quote columns and detect ambiguity')
    local ambiguousDb = {
        query = function() return NightShift.Result.ok({ row, row }) end
    }
    local ambiguousRepository = NightShift.Repositories.Booking.new({ db = ambiguousDb })
    local ambiguous = ambiguousRepository:findByQuoteId('quote-91')
    check(not ambiguous.ok and ambiguous.error.code == NightShift.Errors.Codes.REPOSITORY_STATE_UNKNOWN, 'ambiguous quote IDs must fail closed')
    local invalid = repository:findForClient({ clientRef = '17:license|2:cid' }, { statuses = { 'DROP_TABLE' } })
    check(not invalid.ok and invalid.error.code == 'REPOSITORY_INVALID', 'unsafe status filters must be rejected')
end

print('NS-123 tests passed: safe client booking read model, bounded history, identity scoping, and DTO privacy')
