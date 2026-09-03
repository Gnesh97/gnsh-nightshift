NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Relationship

local Service = {}
Service.__index = Service

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
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160) and value:find('%z') == nil
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function clamp(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 100 then return 100 end
    return math.floor(value)
end

local function invalid(message, details)
    return Result.err(Codes.RELATIONSHIP_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and
        result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function projectionKey(kind, bookingId, state)
    local value = ('%s:%s:%s'):format(kind, tostring(bookingId), tostring(state))
    local hash = 2166136261
    for index = 1, #value do
        hash = ((hash ~ string.byte(value, index)) * 16777619) & 0xffffffff
    end
    return ('projection:%s:%08x'):format(kind, hash)
end

local function actor(service, source)
    if type(service._identity) ~= 'table' or type(service._identity.resolve) ~= 'function' then
        return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'relationship identity service is unavailable')
    end
    local ok, resolved = pcall(service._identity.resolve, service._identity, source)
    if not ok or type(resolved) ~= 'table' or not resolved.ok or type(resolved.value) ~= 'table' then
        return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'relationship identity could not be resolved')
    end
    local identity = resolved.value
    local reference = identity.identityKey or identity.key
    if not text(reference, 160) then return nil, Result.err(Codes.IDENTITY_INVALID, 'relationship identity has no safe reference') end
    return { type = 'PLAYER', ref = reference, source = source, identity = identity }
end

local function unwrap(result, fallback)
    if type(result) ~= 'table' then return nil, Result.err(fallback or Codes.RELATIONSHIP_INVALID, 'relationship dependency returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function stateOf(booking, event)
    local state = type(event) == 'table' and (event.newState or event.status) or nil
    state = state or type(booking) == 'table' and booking.status
    return type(state) == 'string' and state:upper() or nil
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.relationshipRepository
    if type(repository) ~= 'table' or type(repository.findByPair) ~= 'function' or
        type(repository.create) ~= 'function' or type(repository.updateExpectedVersion) ~= 'function' then
        return nil, invalid('relationship service requires a relationship repository')
    end
    local config = copy(options.config or NightShift.ReputationConfig or {})
    local relationship = type(config.relationship) == 'table' and config.relationship or {}
    local threshold = integer(relationship.regularThreshold or config.regularThreshold or 3, 1, 1000)
    local settledTrust = integer(relationship.trustPerSettled or 10, -100, 100)
    local cancelledTrust = integer(relationship.trustPerCancelled or 0, -100, 100)
    if not threshold or settledTrust == nil or cancelledTrust == nil then
        return nil, invalid('relationship configuration is invalid')
    end
    return setmetatable({
        _repository = repository,
        _identity = options.identityService or options.identity,
        _clientProfileService = options.clientProfileService or options.clientProfile,
        _clientRepository = options.clientProfileRepository or options.clientRepository,
        _workerService = options.npcWorkerService or options.workerService,
        _bookingCommands = options.clientBookingCommandService or options.clientBookingCommands,
        _projectionRepository = options.projectionRepository or options.bookingEventRepository,
        _threshold = threshold,
        _settledTrust = settledTrust,
        _cancelledTrust = cancelledTrust,
        _processed = {},
        _subscription = nil
    }, Service)
end

function Service:_clientProfileFromBooking(booking)
    local explicit = integer(booking.clientProfileId or booking.client_profile_id, 1, 2147483647)
    if explicit then return { id = explicit } end
    local source = booking.clientSource or booking.source
    if source ~= nil and type(self._clientProfileService) == 'table' and type(self._clientProfileService.get) == 'function' then
        local result = self._clientProfileService:get(source)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    local reference = booking.clientRef
    local identity
    if type(self._identity) == 'table' and type(self._identity.get) == 'function' and text(reference, 160) then
        identity = self._identity:get(reference)
    end
    if type(identity) == 'table' and type(self._clientRepository) == 'table' and type(self._clientRepository.findByIdentity) == 'function' then
        local result = self._clientRepository:findByIdentity(identity.playerIdentifier or identity.identifier, identity.characterId)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    return nil, Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'client profile was not found')
end

function Service:_workerProfileFromBooking(booking)
    local explicit = integer(booking.workerProfileId or booking.worker_profile_id, 1, 2147483647)
    if explicit then return { id = explicit } end
    if tostring(booking.workerType or ''):upper() ~= 'NPC' then
        return nil, Result.err(Codes.RELATIONSHIP_INVALID, 'only NPC worker relationships are supported')
    end
    if type(self._workerService) ~= 'table' or type(self._workerService.get) ~= 'function' then
        return nil, Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'NPC worker service is unavailable')
    end
    local result = self._workerService:get(booking.workerRef)
    if type(result) ~= 'table' or not result.ok then return nil, result end
    local worker = result.value
    local profile = worker and worker.profile
    local id = integer(worker and (worker.profileId or worker.profile_id), 1, 2147483647) or
        integer(profile and (profile.id or profile.profileId), 1, 2147483647)
    if not id then return nil, Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'NPC worker profile is unavailable') end
    return { id = id, worker = worker, profile = profile }
end

function Service:_pair(booking)
    if type(booking) ~= 'table' or booking.id == nil then return nil, invalid('relationship booking is required') end
    if tostring(booking.clientType or ''):upper() ~= 'PLAYER' then
        return nil, Result.err(Codes.RELATIONSHIP_INVALID, 'relationship booking client must be a player')
    end
    local client, clientError = self:_clientProfileFromBooking(booking)
    if not client then return nil, clientError end
    local worker, workerError = self:_workerProfileFromBooking(booking)
    if not worker then return nil, workerError end
    local clientId = integer(client.id or client.profileId, 1, 2147483647)
    local workerId = integer(worker.id or worker.profileId, 1, 2147483647)
    if not clientId or not workerId then return nil, Result.err(Codes.RELATIONSHIP_INVALID, 'relationship profile IDs are invalid') end
    return { clientProfileId = clientId, workerProfileId = workerId, client = client, worker = worker }
end

function Service:_find(pair)
    local result = self._repository:findByPair(pair.clientProfileId, pair.workerProfileId, 'REGULAR')
    if type(result) ~= 'table' then return nil, Result.err(Codes.RELATIONSHIP_INVALID, 'relationship lookup returned an invalid result') end
    if result.ok then return result.value end
    if notFound(result) then return nil end
    return nil, result
end

function Service:_safe(value)
    if type(value) ~= 'table' then return nil end
    local count = integer(value.interactionCount or value.interaction_count or 0, 0, 2147483647) or 0
    return {
        id = value.id,
        clientProfileId = value.clientProfileId or value.client_profile_id,
        workerProfileId = value.workerProfileId or value.worker_profile_id,
        relationshipType = tostring(value.relationshipType or value.relationship_type or 'REGULAR'):upper(),
        interactionCount = count,
        trustScore = clamp(value.trustScore or value.trust_score),
        regular = count >= self._threshold,
        regularThreshold = self._threshold,
        lastBookingId = value.lastBookingId or value.last_booking_id,
        version = value.version
    }
end

function Service:_projectionApplied(booking, state)
    local repository = self._projectionRepository
    local bookingId = integer(booking and booking.id, 1, 2147483647)
    if type(repository) ~= 'table' or type(repository.findByKey) ~= 'function' or not bookingId then
        return false, nil
    end
    local key = projectionKey('relationship', bookingId, state)
    local found = repository:findByKey(bookingId, key)
    if type(found) ~= 'table' then
        return nil, Result.err(Codes.RELATIONSHIP_CONFLICT, 'relationship projection ledger lookup returned an invalid result')
    end
    if found.ok then return true, key end
    if not notFound(found) then return nil, found end
    return false, key
end

function Service:_recordProjection(booking, state, key)
    local repository = self._projectionRepository
    local bookingId = integer(booking and booking.id, 1, 2147483647)
    if type(repository) ~= 'table' or type(repository.create) ~= 'function' or not bookingId or not key then
        return true
    end
    local created = repository:create({
        bookingId = bookingId,
        eventKey = key,
        eventType = 'RELATIONSHIP_APPLIED',
        metadata = { outcome = state, projection = 'relationship' }
    })
    if type(created) == 'table' and created.ok then return true end
    local raced = type(repository.findByKey) == 'function' and repository:findByKey(bookingId, key) or nil
    if type(raced) == 'table' and raced.ok then return true end
    return nil, Result.err(Codes.RELATIONSHIP_CONFLICT, 'relationship projection ledger could not be committed', {
        bookingId = bookingId, eventKey = key, cause = created and created.error and created.error.code
    })
end

function Service:record(booking, event)
    if type(booking) ~= 'table' or booking.id == nil then return invalid('relationship booking is required') end
    local state = stateOf(booking, event)
    if state ~= 'SETTLED' and state ~= 'CANCELLED' and state ~= 'EXPIRED' and state ~= 'INTERRUPTED' then
        return Result.ok({ skipped = true, bookingId = booking.id }, { skipped = true })
    end
    local key = tostring(booking.id) .. ':' .. state
    if self._processed[key] then return Result.ok(copy(self._processed[key]), { idempotent = true }) end
    local applied, projectionKeyValue = self:_projectionApplied(booking, state)
    if applied == nil then return projectionKeyValue end
    if applied then
        local result = { skipped = true, bookingId = booking.id }
        self._processed[key] = copy(result)
        return Result.ok(result, { idempotent = true, persistent = true })
    end
    local pair, pairError = self:_pair(booking)
    if not pair then return pairError end
    local current, lookupError = self:_find(pair)
    if lookupError then return lookupError end
    if state ~= 'SETTLED' then
        if not current or self._cancelledTrust == 0 then
            local value = { skipped = true, bookingId = booking.id, relationship = current and self:_safe(current) }
            local committed, commitError = self:_recordProjection(booking, state, projectionKeyValue)
            if not committed then return commitError end
            self._processed[key] = copy(value)
            return Result.ok(value, { skipped = true, idempotent = current ~= nil, persistent = projectionKeyValue ~= nil })
        end
        local nextTrust = clamp((tonumber(current.trustScore) or 0) + self._cancelledTrust)
        if nextTrust == tonumber(current.trustScore or 0) then
            local value = { bookingId = booking.id, relationship = self:_safe(current) }
            local committed, commitError = self:_recordProjection(booking, state, projectionKeyValue)
            if not committed then return commitError end
            self._processed[key] = copy(value)
            return Result.ok(value, { idempotent = true, persistent = projectionKeyValue ~= nil })
        end
        local updated = self._repository:updateExpectedVersion(current.id, current.version, { trustScore = nextTrust })
        if type(updated) ~= 'table' or not updated.ok then
            return Result.err(Codes.RELATIONSHIP_CONFLICT, 'relationship cancellation update failed', { cause = updated and updated.error and updated.error.code })
        end
        local relationship = copy(current)
        relationship.trustScore, relationship.version = nextTrust, updated.value and updated.value.version or current.version + 1
        local value = { bookingId = booking.id, relationship = self:_safe(relationship) }
        local committed, commitError = self:_recordProjection(booking, state, projectionKeyValue)
        if not committed then return commitError end
        self._processed[key] = copy(value)
        return Result.ok(value, { updated = true, persistent = projectionKeyValue ~= nil })
    end
    if current and tostring(current.lastBookingId or '') == tostring(booking.id) then
        local value = { bookingId = booking.id, relationship = self:_safe(current) }
        self._processed[key] = copy(value)
        return Result.ok(value, { idempotent = true })
    end
    local count = current and integer(current.interactionCount or current.interaction_count, 0, 2147483647) or 0
    local trust = clamp((current and current.trustScore or 0) + self._settledTrust)
    local relationship
    if current then
        local updated = self._repository:updateExpectedVersion(current.id, current.version, {
            interactionCount = count + 1, trustScore = trust, lastBookingId = booking.id
        })
        if type(updated) ~= 'table' or not updated.ok then
            return Result.err(Codes.RELATIONSHIP_CONFLICT, 'relationship update failed', { cause = updated and updated.error and updated.error.code })
        end
        relationship = copy(current)
        relationship.interactionCount = count + 1
        relationship.trustScore = trust
        relationship.lastBookingId = booking.id
        relationship.version = updated.value and updated.value.version or current.version + 1
    else
        local created = self._repository:create({
            clientProfileId = pair.clientProfileId, workerProfileId = pair.workerProfileId,
            relationshipType = 'REGULAR', interactionCount = 1, trustScore = trust, lastBookingId = booking.id
        })
        if type(created) ~= 'table' or not created.ok then
            local raced = self:_find(pair)
            if raced then
                local value = { bookingId = booking.id, relationship = self:_safe(raced) }
                self._processed[key] = copy(value)
                return Result.ok(value, { idempotent = true })
            end
            return Result.err(Codes.RELATIONSHIP_CONFLICT, 'relationship could not be created', { cause = created and created.error and created.error.code })
        end
        relationship = copy(created.value or {})
        relationship.id = relationship.id or created.value and (created.value.insertId or created.value.id)
        relationship.clientProfileId = pair.clientProfileId
        relationship.workerProfileId = pair.workerProfileId
        relationship.relationshipType = 'REGULAR'
        relationship.interactionCount = 1
        relationship.trustScore = trust
        relationship.lastBookingId = booking.id
        relationship.version = relationship.version or 1
    end
    local value = { bookingId = booking.id, relationship = self:_safe(relationship) }
    local committed, commitError = self:_recordProjection(booking, state, projectionKeyValue)
    if not committed then return commitError end
    self._processed[key] = copy(value)
    return Result.ok(value, { updated = current ~= nil, regular = value.relationship.regular, serverAuthoritative = true, persistent = projectionKeyValue ~= nil })
end

function Service:get(source, workerKey)
    local currentActor, actorError = actor(self, source)
    if not currentActor then return actorError end
    if not text(workerKey, 160) then return invalid('relationship worker key is required') end
    local worker = self._workerService and self._workerService.get and self._workerService:get(workerKey)
    if type(worker) ~= 'table' or not worker.ok then return worker or Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'worker was not found') end
    local profile = worker.value and worker.value.profile
    local workerId = integer(worker.value and (worker.value.profileId or worker.value.profile_id), 1, 2147483647) or integer(profile and profile.id, 1, 2147483647)
    if not workerId then return Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'worker profile was not found') end
    local client
    if self._clientProfileService and type(self._clientProfileService.get) == 'function' then
        local result = self._clientProfileService:get(source)
        if type(result) == 'table' and result.ok then client = result.value else return result end
    end
    local clientId = integer(client and client.id, 1, 2147483647)
    if not clientId then return Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'client profile was not found') end
    local found, findError = self:_find({ clientProfileId = clientId, workerProfileId = workerId })
    if findError then return findError end
    if not found then return Result.err(Codes.RELATIONSHIP_NOT_FOUND, 'relationship was not found') end
    return Result.ok(self:_safe(found))
end

function Service:onBookingEvent(envelope)
    local payload = type(envelope) == 'table' and envelope.payload or envelope
    local booking = type(payload) == 'table' and (payload.booking or payload) or nil
    local result = self:record(booking, payload)
    -- Relationship updates are a post-commit projection. A failed projection
    -- is reported to the EventBus but never rolls back the booking transition.
    return result
end

function Service:subscribe(eventBus)
    if type(eventBus) ~= 'table' or type(eventBus.subscribe) ~= 'function' then
        return Result.err(Codes.RELATIONSHIP_INVALID, 'relationship event bus is unavailable')
    end
    if self._subscription then return Result.ok({ subscription = self._subscription }, { idempotent = true }) end
    local handle, errorResult = eventBus:subscribe('booking.state_changed', function(envelope)
        return self:onBookingEvent(envelope)
    end)
    if not handle then return errorResult end
    self._subscription = handle
    return Result.ok({ subscription = handle })
end

function Service:rebuild(events)
    if type(events) ~= 'table' then return invalid('relationship rebuild events must be an array') end
    local output = {}
    for index, event in ipairs(events) do
        output[index] = self:onBookingEvent(event)
        if not output[index].ok then return output[index] end
    end
    return Result.ok(output)
end

function Service:bookAgain(source, payload)
    if type(self._bookingCommands) ~= 'table' or type(self._bookingCommands.quote) ~= 'function' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again quote pipeline is unavailable')
    end
    if type(payload) ~= 'table' then return Result.err(Codes.BOOK_AGAIN_INVALID, 'book again payload must be a table') end
    local allowed = { workerId = true, packageId = true, servicePackageId = true, meetingMode = true, locationId = true, locationRef = true, previousBookingId = true }
    for key in pairs(payload) do
        if not allowed[key] then return Result.err(Codes.BOOK_AGAIN_INVALID, 'book again field is not allowlisted', { field = tostring(key) }) end
    end
    local workerId = payload.workerId
    local packageId = payload.packageId or payload.servicePackageId
    local locationId = payload.locationId or payload.locationRef
    if not text(workerId, 160) or not text(packageId, 96) or not text(locationId, 160) or type(payload.meetingMode) ~= 'string' then
        return Result.err(Codes.BOOK_AGAIN_INVALID, 'book again requires worker, package, meeting mode and location')
    end
    if type(self._workerService) ~= 'table' or type(self._workerService.get) ~= 'function' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'worker availability service is unavailable')
    end
    local worker = self._workerService:get(workerId)
    if type(worker) ~= 'table' or not worker.ok then return worker end
    local state = worker.value and tostring(worker.value.state or ''):upper()
    if state ~= '' and state ~= 'AVAILABLE' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'worker is no longer available', { state = state })
    end
    local fresh = {
        workerId = workerId,
        packageId = packageId,
        meetingMode = payload.meetingMode,
        locationId = locationId
    }
    local quoted = self._bookingCommands:quote(source, fresh)
    if type(quoted) ~= 'table' then return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again quote pipeline returned an invalid result') end
    if not quoted.ok then return quoted end
    return Result.ok({ quote = quoted.value, workerId = workerId, packageId = packageId }, {
        bookAgain = true, newQuote = true, oldPriceIgnored = true
    })
end

function Service:confirmAgain(source, payload)
    if type(self._bookingCommands) ~= 'table' or type(self._bookingCommands.confirm) ~= 'function' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again confirmation pipeline is unavailable')
    end
    if type(payload) ~= 'table' or not text(payload.quoteId, 128) then
        return Result.err(Codes.BOOK_AGAIN_INVALID, 'book again quote ID is required')
    end
    return self._bookingCommands:confirm(source, { quoteId = payload.quoteId })
end

Service.recordBooking = Service.record
Service.recordSettled = Service.record
Service.recordOutcome = Service.record
Service.bookAgainQuote = Service.bookAgain
Service.quoteAgain = Service.bookAgain
Service.confirm = Service.confirmAgain
NightShift.RelationshipService = Service
NightShift.Services.Relationship = Service

return Service
