local function check(value, message)
    assert(value, message)
end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

do
    local state = {
        id = 77,
        version = 1,
        status = 'DRAFT',
        workerRef = 'npc-1',
        locationRef = 'configured_default'
    }
    local reservationCalls = 0
    local draftKeys = {}
    local function nextState(changes)
        local value = copy(state)
        for key, item in pairs(changes or {}) do value[key] = copy(item) end
        value.version = state.version + 1
        state = value
        return NightShift.Result.ok(copy(value))
    end
    local booking = {
        createDraft = function(_, actor, input)
            check(actor.type == 'PLAYER' and (actor.ref == 'license:test|cid:1' or actor.ref == 'license:other|cid:9'), 'quote must use the resolved player actor')
            check(input.clientType == 'PLAYER' and input.workerType == 'NPC', 'quote must create a player-to-NPC booking')
            draftKeys[#draftKeys + 1] = input.idempotencyKey
            if state.status == 'DRAFT' then
                state.clientType, state.clientRef = input.clientType, input.clientRef
                state.workerRef, state.locationRef = input.workerRef, input.locationRef
                state.servicePackage = { id = input.servicePackageId }
                state.meetingMode = input.meetingMode
            end
            return NightShift.Result.ok(copy(state))
        end,
        applyAuthoritativeQuote = function(_, _, id, quote, expected)
            check(id == state.id and expected == 1, 'quote must be applied with the draft version')
            return nextState({ status = 'QUOTED', quote = copy(quote) })
        end,
        get = function(_, id)
            check(id == state.id, 'confirm must look up the persisted booking')
            return NightShift.Result.ok(copy(state))
        end,
        offer = function(_, _, id, expected)
            check(id == state.id and expected == state.version, 'confirm must offer with the current version')
            return nextState({ status = 'OFFERED' })
        end,
        accept = function(_, _, id, expected)
            check(id == state.id and expected == state.version, 'confirm must accept with the current version')
            return nextState({ status = 'ACCEPTED', agreedPrice = copy(state.quote) })
        end,
        reserve = function(_, _, id, expected, resources)
            check(id == state.id and expected == state.version and #resources == 2, 'confirm must reserve worker and location atomically')
            reservationCalls = reservationCalls + 1
            return nextState({ status = 'RESERVED' })
        end
    }
    local repository = {
        findByQuoteId = function(_, quoteId)
            if state.quote and state.quote.quoteId == quoteId then return NightShift.Result.ok(copy(state)) end
            return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'booking not found')
        end
    }
    local identity = {
        resolve = function(_, source) return NightShift.Result.ok({ identityKey = 'license:test|cid:1', source = source }) end
    }
    local workers = {
        get = function(_, key)
            return NightShift.Result.ok({ workerKey = key, state = 'AVAILABLE', activeDistrict = 'vinewood', priceClass = 2 })
        end
    }
    local pricing = {
        quote = function(_, request)
            check(request.servicePackageId == 'standard' and request.meetingMode == 'COME_TO_ME', 'pricing must receive normalized server-owned inputs')
            check(request.locationId == 'configured_default' and request.district == 'vinewood', 'pricing must receive the selected server location and worker district')
            return NightShift.Result.ok({
                quoteId = 'quote-77',
                amountMinor = 650,
                currency = 'USD',
                expiresAt = '2030-01-01T00:01:00Z'
            })
        end
    }
    local reservation = { reserve = function() return NightShift.Result.ok({}) end }
    local service, err = NightShift.ClientBookingCommandService.new({
        bookingService = booking,
        pricingService = pricing,
        identityService = identity,
        workerService = workers,
        repository = repository,
        reservationService = reservation,
        reservationTtlSeconds = 600
    })
    check(service and not err, 'client booking command service should construct')

    local quote = service:quote(42, {
        workerId = 'npc-1',
        packageId = 'standard',
        meetingMode = 'come_to_me',
        locationId = 'configured_default'
    })
    check(quote.ok and quote.value.quoteId == 'quote-77' and quote.value.amount == 650, 'quote should return the server-authoritative public DTO')
    check(state.status == 'QUOTED' and state.quote.quoteId == 'quote-77', 'quote should persist its binding before confirmation')

    local quoteRetry = service:quote(42, {
        workerId = 'npc-1',
        packageId = 'standard',
        meetingMode = 'come_to_me',
        locationId = 'configured_default'
    })
    check(quoteRetry.ok and quoteRetry.value.quoteId == 'quote-77' and draftKeys[1] == draftKeys[2], 'repeated quote requests should reuse the same idempotency key and persisted quote')

    local confirm = service:confirm(42, { quoteId = 'quote-77' })
    check(confirm.ok and confirm.value.bookingId == '77' and confirm.value.status == 'RESERVED', 'confirm should complete offer, acceptance, and reservation')
    check(reservationCalls == 1, 'confirm should reserve resources exactly once')

    local retry = service:confirm(42, { quoteId = 'quote-77' })
    check(retry.ok and retry.value.bookingId == '77' and reservationCalls == 1, 'reserved confirmation should be idempotent')

    local otherIdentity = {
        resolve = function(_, source)
            return NightShift.Result.ok({ identityKey = source == 99 and 'license:other|cid:9' or 'license:test|cid:1', source = source })
        end
    }
    local guarded, guardedError = NightShift.ClientBookingCommandService.new({
        bookingService = booking,
        pricingService = pricing,
        identityService = otherIdentity,
        workerService = workers,
        repository = repository,
        reservationService = reservation,
        reservationTtlSeconds = 600
    })
    check(guarded and not guardedError, 'ownership guard service should construct')
    local unauthorized = guarded:confirm(99, { quoteId = 'quote-77' })
    check(not unauthorized.ok and unauthorized.error.code == NightShift.Errors.Codes.BOOKING_OWNERSHIP_DENIED, 'another player cannot confirm this booking')

    local reuseIdentity = {
        resolve = function(_, source) return NightShift.Result.ok({ identityKey = 'license:other|cid:9', source = source }) end
    }
    local reuseService, reuseError = NightShift.ClientBookingCommandService.new({
        bookingService = booking,
        pricingService = pricing,
        identityService = reuseIdentity,
        workerService = workers,
        repository = repository,
        reservationService = reservation,
        reservationTtlSeconds = 600
    })
    check(reuseService and not reuseError, 'source reuse guard service should construct')
    local sourceReuse = reuseService:quote(42, {
        workerId = 'npc-1',
        packageId = 'standard',
        meetingMode = 'come_to_me',
        locationId = 'configured_default'
    })
    check(not sourceReuse.ok and sourceReuse.error.code == NightShift.Errors.Codes.BOOKING_OWNERSHIP_DENIED and draftKeys[3] ~= draftKeys[1], 'reused source numbers must not share another player quote idempotency key')

    local invalid = service:quote(42, {
        workerId = 'npc-1',
        packageId = 'standard',
        meetingMode = 'come_to_me',
        locationId = 'configured_default',
        amount = 1
    })
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.CLIENT_BOOKING_COMMAND_INVALID, 'unallowlisted quote input must fail closed')
end

print('NS-122 tests passed: server-authoritative quote, quote-bound confirm, atomic reservation, and idempotent retry')
