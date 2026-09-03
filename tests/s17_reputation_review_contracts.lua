local function s17Check(value, message)
    assert(value, message)
end

local function s17Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[s17Copy(key, seen)] = s17Copy(item, seen) end
    return output
end

local Codes = NightShift.Errors.Codes

do
    local config, errorResult = NightShift.Validators.validateConfig(NightShift.Validators.copy(NightShift.DefaultConfig))
    s17Check(config and not errorResult and config.reputation.favorite.persistentOnly == true, 'S17 reputation config should normalize favorite policy')
    local invalid = NightShift.Validators.copy(NightShift.DefaultConfig)
    invalid.reputation.relationship.trustPerSettled = 101
    local _, invalidError = NightShift.Validators.validateConfig(invalid)
    s17Check(invalidError and invalidError.field == 'reputation.relationship.trustPerSettled', 'relationship trust bounds must fail closed')
end

do
    local worker = { id = 11, version = 1, professionalism = 99, discretion = 99, reliability = 99, completedBookings = 0, cancelledBookings = 0, noShowBookings = 0 }
    local client = { id = 22, version = 1, reliability = 1, completedBookings = 0, cancelledBookings = 0, noShowBookings = 0 }
    local workerRepository = {
        findById = function(_, id) return tonumber(id) == worker.id and NightShift.Result.ok(s17Copy(worker)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        updateExpectedVersion = function(_, id, version, changes)
            s17Check(id == worker.id and version == worker.version, 'worker reputation update should be versioned')
            for key, value in pairs(changes) do worker[key] = s17Copy(value) end
            worker.version = worker.version + 1
            return NightShift.Result.ok({ id = id, version = worker.version })
        end
    }
    local clientRepository = {
        findById = function(_, id) return tonumber(id) == client.id and NightShift.Result.ok(s17Copy(client)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        updateExpectedVersion = function(_, id, version, changes)
            s17Check(id == client.id and version == client.version, 'client reputation update should be versioned')
            for key, value in pairs(changes) do client[key] = s17Copy(value) end
            client.version = client.version + 1
            return NightShift.Result.ok({ id = id, version = client.version })
        end
    }
    local reputation = assert(NightShift.ReputationService.new({
        workerProfileRepository = workerRepository,
        clientProfileRepository = clientRepository,
        config = { enabled = true, min = 0, max = 100, initial = 50, worker = { completion = 2, cancellation = -1, noShow = -12, paymentReliability = 1 }, client = { completion = 2, cancellation = -1, noShow = -12, paymentReliability = 1 } }
    }))
    local booking = { id = 'booking:s17:reputation', status = 'SETTLED', workerType = 'PLAYER', workerProfileId = worker.id, clientType = 'PLAYER', clientProfileId = client.id }
    local intermediate = reputation:apply(booking, { newState = 'COMPLETED', eventKey = 'event:completed:1' })
    s17Check(intermediate.ok and intermediate.metadata and intermediate.metadata.skipped == true and worker.completedBookings == 0, 'intermediate completed state must not score before settlement')
    local settled = reputation:apply(booking, { newState = 'SETTLED', eventKey = 'event:settled:1', metadata = { paymentSucceeded = true } })
    s17Check(settled.ok and worker.completedBookings == 1 and worker.professionalism == 100 and worker.reliability == 100 and client.completedBookings == 1 and client.reliability == 4, 'settled reputation should update bounded worker/client traits')
    local replay = reputation:apply(booking, { newState = 'SETTLED', eventKey = 'event:settled:1', metadata = { paymentSucceeded = true } })
    s17Check(replay.ok and replay.metadata and replay.metadata.idempotent == true and worker.completedBookings == 1, 'reputation replay must be idempotent')
    local noShow = reputation:apply({ id = 'booking:s17:no-show', status = 'CANCELLED', workerType = 'PLAYER', workerProfileId = worker.id, clientType = 'PLAYER', clientProfileId = client.id }, { newState = 'CANCELLED', eventKey = 'event:no-show:1', metadata = { noShow = true } })
    s17Check(noShow.ok and worker.noShowBookings == 1 and worker.reliability == 88 and client.noShowBookings == 1, 'no-show outcome should use the configured bounded penalty')
end

do
    local markers = {}
    local ledger = {
        findByKey = function(_, bookingId, key)
            local marker = markers[tostring(bookingId) .. ':' .. key]
            return marker and NightShift.Result.ok(marker) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing')
        end,
        create = function(_, value)
            markers[tostring(value.bookingId) .. ':' .. value.eventKey] = s17Copy(value)
            return NightShift.Result.ok({ insertId = 1 })
        end
    }
    local worker, client = { id = 111, version = 1, professionalism = 50, discretion = 50, reliability = 50, completedBookings = 0 }, { id = 222, version = 1, reliability = 50, completedBookings = 0 }
    local workerRepository = {
        findById = function() return NightShift.Result.ok(s17Copy(worker)) end,
        updateExpectedVersion = function(_, id, version, changes)
            if version ~= worker.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            for key, value in pairs(changes) do worker[key] = s17Copy(value) end
            worker.version = worker.version + 1
            return NightShift.Result.ok({ id = id, version = worker.version })
        end
    }
    local clientRepository = {
        findById = function() return NightShift.Result.ok(s17Copy(client)) end,
        updateExpectedVersion = function(_, id, version, changes)
            if version ~= client.version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'version') end
            for key, value in pairs(changes) do client[key] = s17Copy(value) end
            client.version = client.version + 1
            return NightShift.Result.ok({ id = id, version = client.version })
        end
    }
    local options = {
        workerProfileRepository = workerRepository,
        clientProfileRepository = clientRepository,
        projectionRepository = ledger,
        config = { enabled = true, min = 0, max = 100, initial = 50, worker = { completion = 2, cancellation = -1, noShow = -12, paymentReliability = 1 }, client = { completion = 2, cancellation = -1, noShow = -12, paymentReliability = 1 } }
    }
    local booking = { id = 909, status = 'SETTLED', workerType = 'PLAYER', workerProfileId = worker.id, clientType = 'PLAYER', clientProfileId = client.id }
    local first = assert(NightShift.ReputationService.new(options)):apply(booking, { newState = 'SETTLED', eventKey = 'restart:event' })
    s17Check(first.ok and worker.completedBookings == 1, 'first reputation projection should commit its ledger marker')
    local second = assert(NightShift.ReputationService.new(options)):apply(booking, { newState = 'SETTLED', eventKey = 'restart:event' })
    s17Check(second.ok and second.metadata and second.metadata.persistent == true and second.metadata.idempotent == true and worker.completedBookings == 1, 'reputation replay after service restart must use the persistent ledger')
end

do
    local booking = { id = 'booking:s17:review', status = 'SETTLED', clientType = 'PLAYER', clientRef = 'player:one', workerType = 'NPC', workerRef = 'npc:one', workerProfileId = 31 }
    local clientProfile = { id = 41, version = 1 }
    local workerProfile = { id = 31, version = 1, rating = 4, reviewCount = 1, profileType = 'PERSISTENT' }
    local stored
    local identity = { resolve = function(_, source) return NightShift.Result.ok({ identityKey = source == 42 and 'player:one' or 'player:other', playerIdentifier = 'license:one' }) end }
    local bookingService = { get = function() return NightShift.Result.ok(s17Copy(booking)) end }
    local reviews = {
        findByBooking = function() return stored and NightShift.Result.ok(s17Copy(stored)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        create = function(_, value) stored = s17Copy(value); stored.id = 7; return NightShift.Result.ok({ insertId = 7 }) end
    }
    local npcRepository = {
        findProfileById = function(_, id) return tonumber(id) == workerProfile.id and NightShift.Result.ok(s17Copy(workerProfile)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        updateProfileExpectedVersion = function(_, id, version, changes)
            s17Check(id == workerProfile.id and version == workerProfile.version, 'review aggregate should use optimistic version')
            for key, value in pairs(changes) do workerProfile[key] = value end
            workerProfile.version = workerProfile.version + 1
            return NightShift.Result.ok({ id = id, version = workerProfile.version })
        end
    }
    local reviewsService = assert(NightShift.ReviewService.new({
        repository = reviews, bookingService = bookingService, identityService = identity,
        clientProfileService = { get = function() return NightShift.Result.ok(clientProfile) end },
        npcProfileRepository = npcRepository,
        npcWorkerService = { get = function() return NightShift.Result.ok({ profile = workerProfile }) end }
    }))
    local created = reviewsService:submit(42, { bookingId = booking.id, rating = 5, reviewText = 'clear and professional' })
    s17Check(created.ok and created.value.review.rating == 5 and created.value.booking == nil and workerProfile.reviewCount == 2 and workerProfile.rating == 4.5, 'settled review should persist, aggregate worker rating, and return no raw booking')
    local replay = reviewsService:submit(42, { bookingId = booking.id, rating = 1 })
    s17Check(replay.ok and replay.metadata and replay.metadata.idempotent == true and workerProfile.reviewCount == 2, 'duplicate review should not double aggregate')
    booking.status = 'CANCELLED'
    local rejected = reviewsService:submit(42, { bookingId = booking.id, rating = 5 })
    s17Check(not rejected.ok and rejected.error.code == Codes.REVIEW_NOT_ELIGIBLE, 'cancelled bookings cannot be reviewed')
end

do
    local client = { id = 51 }
    local worker = { workerKey = 'npc:persistent', state = 'AVAILABLE', profile = { id = 61, profileKey = 'profile:persistent', profileType = 'PERSISTENT', alias = 'Night Worker', rating = 4.8 } }
    local relation
    local favorites = {
        findByPair = function() return relation and NightShift.Result.ok(s17Copy(relation)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        create = function(_, value) relation = s17Copy(value); relation.id, relation.version = 8, 1; return NightShift.Result.ok({ insertId = 8 }) end,
        deleteExpectedVersion = function() relation = nil; return NightShift.Result.ok({ deleted = true }) end,
        findByClient = function() return NightShift.Result.ok(relation and { s17Copy(relation) } or {}) end
    }
    local favorite = assert(NightShift.FavoriteService.new({
        repository = favorites,
        identityService = { resolve = function() return NightShift.Result.ok({ identityKey = 'player:one' }) end },
        clientProfileService = { get = function() return NightShift.Result.ok(client) end },
        workerService = { get = function(_, key) return key == worker.workerKey and NightShift.Result.ok(s17Copy(worker)) or NightShift.Result.err(Codes.NPC_WORKER_NOT_FOUND, 'missing') end,
            listAvailable = function() return NightShift.Result.ok({ items = { s17Copy(worker) } }) end }
    }))
    local added = favorite:add(42, worker.workerKey)
    s17Check(added.ok and relation and added.value.favorite.persistent == true, 'persistent NPC workers should be favoritable')
    local replay = favorite:add(42, worker.workerKey)
    s17Check(replay.ok and replay.metadata and replay.metadata.idempotent == true, 'favorite add should be idempotent')
    local listed = favorite:list(42, {})
    s17Check(listed.ok and #listed.value.items == 1 and listed.value.items[1].favorite.workerKey == worker.workerKey, 'favorite list should return safe worker DTO')
    local removed = favorite:remove(42, worker.workerKey)
    s17Check(removed.ok and removed.value.removed == true, 'favorite remove should delete the versioned relation')

    local ensuredClient = { id = 52 }
    local ensured = false
    local lazyFavorite = assert(NightShift.FavoriteService.new({
        repository = {
            findByPair = function() return NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
            create = function() return NightShift.Result.ok({ insertId = 1 }) end,
            deleteExpectedVersion = function() return NightShift.Result.ok({ deleted = true }) end,
            findByClient = function(_, clientProfileId) s17Check(clientProfileId == ensuredClient.id, 'favorite list should use the ensured client profile'); return NightShift.Result.ok({}) end
        },
        identityService = { resolve = function() return NightShift.Result.ok({ identityKey = 'player:two' }) end },
        clientProfileService = {
            get = function() return NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
            ensure = function() ensured = true; return NightShift.Result.ok(ensuredClient) end
        },
        workerService = { get = function() return NightShift.Result.err(Codes.NPC_WORKER_NOT_FOUND, 'missing') end }
    }))
    local empty = lazyFavorite:list(43, {})
    s17Check(empty.ok and ensured and #empty.value.items == 0, 'favorite list should ensure a first-use client profile and return an empty list')
end

do
    local previousRegister = rawget(_G, 'RegisterCommand')
    local previousConvar = rawget(_G, 'GetConvar')
    local previousPrint = rawget(_G, 'print')
    local server = NightShift.Server
    local previousInstance = server.instance
    local previousLoaded = server._s17SmokeCommandsLoaded
    local commands, output = {}, {}
    RegisterCommand = function(name, callback) commands[name] = callback end
    GetConvar = function() return '' end
    print = function(message) output[#output + 1] = tostring(message) end
    server.instance = {
        results = {
            config = { config = { environment = 'development' } },
            services = {
                favorite = {
                    list = function()
                        return NightShift.Result.ok({ items = {
                            { favorite = { workerKey = 'npc:persistent' } }
                        } })
                    end
                },
                marketplace = {
                    list = function()
                        return NightShift.Result.ok({ items = {
                            { workerId = 'npc:persistent', profileType = 'PERSISTENT' }
                        } })
                    end
                }
            }
        }
    }
    server._s17SmokeCommandsLoaded = nil
    local loaded, loadError = pcall(dofile, 'server/dev/s17_smoke.lua')
    local invoked, invokeError = false, nil
    local workersInvoked, workersInvokeError = false, nil
    if loaded and commands.nightshift_s17_favorite_list then
        invoked, invokeError = pcall(commands.nightshift_s17_favorite_list, 42, {})
    end
    if loaded and commands.nightshift_s17_worker_list then
        workersInvoked, workersInvokeError = pcall(commands.nightshift_s17_worker_list, 42, {})
    end
    RegisterCommand, GetConvar, print = previousRegister, previousConvar, previousPrint
    server.instance, server._s17SmokeCommandsLoaded = previousInstance, previousLoaded
    local favoriteOutput
    local workerOutput
    for _, line in ipairs(output) do
        if line:find('S17 favorite-list ok:', 1, true) then favoriteOutput = line end
        if line:find('S17 worker-list ok:', 1, true) then workerOutput = line end
    end
    s17Check(loaded, 'S17 smoke command module should load in the command harness: ' .. tostring(loadError))
    s17Check(invoked, 'S17 favorite-list smoke command should invoke: ' .. tostring(invokeError))
    s17Check(workersInvoked, 'S17 worker-list smoke command should invoke: ' .. tostring(workersInvokeError))
    s17Check(favoriteOutput and favoriteOutput:find('count=1', 1, true) and favoriteOutput:find('workers=npc:persistent', 1, true), 'favorite-list smoke output should report count and worker keys')
    s17Check(workerOutput and workerOutput:find('count=1', 1, true) and workerOutput:find('workers=npc:persistent', 1, true), 'worker-list smoke output should report available worker keys')
end

do
    local relationship
    local markers = {}
    local ledger = {
        findByKey = function(_, bookingId, key)
            local marker = markers[tostring(bookingId) .. ':' .. key]
            return marker and NightShift.Result.ok(marker) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing')
        end,
        create = function(_, value)
            markers[tostring(value.bookingId) .. ':' .. value.eventKey] = s17Copy(value)
            return NightShift.Result.ok({ insertId = 99 })
        end
    }
    local repository = {
        findByPair = function() return relationship and NightShift.Result.ok(s17Copy(relationship)) or NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        create = function(_, value) relationship = s17Copy(value); relationship.id, relationship.version = 71, 1; return NightShift.Result.ok({ insertId = 71 }) end,
        updateExpectedVersion = function(_, id, version, changes)
            s17Check(id == relationship.id and version == relationship.version, 'relationship update should be versioned')
            for key, value in pairs(changes) do
                if key == 'interactionCount' then relationship.interactionCount = value end
                if key == 'trustScore' then relationship.trustScore = value end
                if key == 'lastBookingId' then relationship.lastBookingId = value end
            end
            relationship.version = relationship.version + 1
            return NightShift.Result.ok({ id = id, version = relationship.version })
        end
    }
    local service = assert(NightShift.RelationshipService.new({
        repository = repository,
        projectionRepository = ledger,
        config = { relationship = { regularThreshold = 2, trustPerSettled = 10, trustPerCancelled = 0 } }
    }))
    local first = service:record({ id = 171, status = 'SETTLED', clientType = 'PLAYER', clientProfileId = 81, workerType = 'NPC', workerProfileId = 91 }, { newState = 'SETTLED', eventKey = 'settled:one' })
    s17Check(first.ok and first.value.relationship.interactionCount == 1 and not first.value.relationship.regular, 'first settled booking should create an acquaintance relation')
    local second = service:record({ id = 172, status = 'SETTLED', clientType = 'PLAYER', clientProfileId = 81, workerType = 'NPC', workerProfileId = 91 }, { newState = 'SETTLED', eventKey = 'settled:two' })
    s17Check(second.ok and second.value.relationship.interactionCount == 2 and second.value.relationship.regular == true, 'repeated settled booking should promote a regular relationship')
    local cancel = service:record({ id = 173, status = 'CANCELLED', clientType = 'PLAYER', clientProfileId = 81, workerType = 'NPC', workerProfileId = 91 }, { newState = 'CANCELLED', eventKey = 'cancelled:one' })
    s17Check(cancel.ok and cancel.value.relationship.interactionCount == 2, 'cancelled booking must not increment relationship count')
    local replay = service:record({ id = 172, status = 'SETTLED', clientType = 'PLAYER', clientProfileId = 81, workerType = 'NPC', workerProfileId = 91 }, { newState = 'SETTLED', eventKey = 'settled:two' })
    s17Check(replay.ok and replay.metadata and replay.metadata.idempotent == true and relationship.interactionCount == 2, 'relationship settlement replay should be idempotent')
    local restarted = assert(NightShift.RelationshipService.new({
        repository = repository,
        projectionRepository = ledger,
        config = { relationship = { regularThreshold = 2, trustPerSettled = 10, trustPerCancelled = 0 } }
    })):record({ id = 172, status = 'SETTLED', clientType = 'PLAYER', clientProfileId = 81, workerType = 'NPC', workerProfileId = 91 }, { newState = 'SETTLED', eventKey = 'settled:two' })
    s17Check(restarted.ok and restarted.metadata and restarted.metadata.persistent == true and relationship.interactionCount == 2, 'relationship replay after service restart must use the persistent ledger')
end

do
    local seen
    local worker = { get = function(_, key) return NightShift.Result.ok({ workerKey = key, state = 'AVAILABLE' }) end }
    local commands = {
        quote = function(_, source, payload) seen = s17Copy(payload); return NightShift.Result.ok({ quoteId = 'fresh:quote', amount = 700, currency = 'USD' }) end,
        confirm = function(_, source, payload) return NightShift.Result.ok({ bookingId = 'fresh:booking', status = 'RESERVED', quoteId = payload.quoteId }) end
    }
    local again = assert(NightShift.BookAgainService.new({
        clientBookingCommandService = commands,
        npcWorkerService = worker,
        bookingService = { get = function() return NightShift.Result.ok({ workerRef = 'npc:again', status = 'SETTLED' }) end }
    }))
    local quoted = again:quote(42, { workerId = 'npc:again', packageId = 'standard', meetingMode = 'come_to_me', locationId = 'configured_default', previousBookingId = 'old:booking' })
    s17Check(quoted.ok and quoted.metadata.newQuote == true and seen.previousBookingId == nil and seen.amount == nil, 'Book Again must request a fresh quote without old price data')
    worker.get = function() return NightShift.Result.ok({ workerKey = 'npc:again', state = 'RESERVED' }) end
    local unavailable = again:quote(42, { workerId = 'npc:again', packageId = 'standard', meetingMode = 'come_to_me', locationId = 'configured_default' })
    s17Check(not unavailable.ok and unavailable.error.code == Codes.BOOK_AGAIN_NOT_AVAILABLE, 'Book Again must recheck worker availability')
    local confirmed = again:confirm(42, { quoteId = 'fresh:quote' })
    s17Check(confirmed.ok and confirmed.value.bookingId == 'fresh:booking', 'Book Again confirmation must use normal booking confirmation')
end

print('NS-170..NS-174 tests passed: bounded reputation, settled reviews, favorites, relationships, and fresh Book Again quotes')
