NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

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
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value ~= math.floor(value) then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPUTATION_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function projectionKey(kind, bookingId, eventKey)
    local value = ('%s:%s:%s'):format(kind, tostring(bookingId), tostring(eventKey))
    local hash = 2166136261
    for index = 1, #value do
        hash = ((hash ~ string.byte(value, index)) * 16777619) & 0xffffffff
    end
    return ('projection:%s:%08x'):format(kind, hash)
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function outcomeFor(booking, event)
    local metadata = type(event) == 'table' and (event.metadata or event.details) or {}
    local target = type(event) == 'table' and (event.newState or event.status) or nil
    target = type(target) == 'string' and target:upper() or type(booking) == 'table' and tostring(booking.status or ''):upper() or ''
    local reason = tostring((type(event) == 'table' and (event.reason or metadata.reason)) or ''):lower()
    local noShow = metadata.noShow == true or metadata.outcome == 'NO_SHOW' or reason:find('no%-show', 1, false) ~= nil
    -- SETTLED is the canonical successful outcome. COMPLETED is an
    -- intermediate appointment state and must not award reputation before the
    -- settlement transition (otherwise one booking would score twice).
    local success = target == 'SETTLED'
    local cancelled = target == 'CANCELLED' or target == 'EXPIRED' or target == 'INTERRUPTED'
    if not success and not cancelled and not noShow then return nil end
    return {
        key = (type(event) == 'table' and (event.eventKey or event.key)) or ('state:%s:%s'):format(tostring(booking and booking.id), target),
        target = target,
        reason = reason,
        noShow = noShow,
        success = success,
        cancelled = cancelled,
        paymentSucceeded = metadata.paymentSucceeded == true or metadata.paymentStatus == 'SUCCEEDED' or metadata.paymentStatus == 'COMMITTED'
    }
end

local function profileId(profile)
    return type(profile) == 'table' and (profile.id or profile.profileId) or nil
end

local function updatedCopy(profile, changes, version)
    local nextProfile = copy(profile)
    for key, value in pairs(changes) do nextProfile[key] = copy(value) end
    nextProfile.version = version or ((tonumber(profile.version) or 1) + 1)
    return nextProfile
end

function Service.new(options)
    options = options or {}
    local config = copy(options.config or NightShift.ReputationConfig or {})
    if config.enabled == nil then config.enabled = true end
    if type(config.enabled) ~= 'boolean' then return nil, invalid('reputation enabled flag must be boolean') end
    local minimum = tonumber(config.min or 0)
    local maximum = tonumber(config.max or 100)
    local initial = tonumber(config.initial or 50)
    if not minimum or not maximum or minimum < 0 or maximum > 100 or maximum < minimum or not initial or initial < minimum or initial > maximum then
        return nil, invalid('reputation bounds are invalid')
    end
    local threshold = integer(config.regularThreshold or 3, 1, 1000)
    if not threshold then return nil, invalid('regular threshold is invalid') end
    local worker = type(config.worker) == 'table' and config.worker or {}
    local client = type(config.client) == 'table' and config.client or {}
    local review = type(config.review) == 'table' and config.review or {}
    return setmetatable({
        _config = {
            enabled = config.enabled,
            min = minimum, max = maximum, initial = initial,
            regularThreshold = threshold, worker = copy(worker), client = copy(client),
            review = { minimum = tonumber(review.minimum) or 1, maximum = tonumber(review.maximum) or 5, textMaxLength = tonumber(review.textMaxLength) or 1000 }
        },
        _workerRepository = options.workerProfileRepository or options.workerRepository,
        _clientRepository = options.clientProfileRepository or options.clientRepository,
        _npcProfileRepository = options.npcProfileRepository or options.npcRepository,
        _npcWorkerService = options.npcWorkerService or options.workerService,
        _identity = options.identityService or options.identity,
        _projectionRepository = options.projectionRepository or options.bookingEventRepository,
        _clock = options.clock,
        _processed = {},
        _results = {},
        _subscription = nil
    }, Service)
end

function Service:isEnabled()
    return self._config.enabled == true
end

function Service:_identityProfile(repository, reference)
    if type(repository) ~= 'table' or not text(reference, 160) then return nil end
    if type(self._identity) == 'table' and type(self._identity.get) == 'function' then
        local identity = self._identity:get(reference)
        if type(identity) == 'table' then
            local result = repository:findByIdentity(identity.playerIdentifier or identity.identifier, identity.characterId)
            if type(result) == 'table' and result.ok then return result.value end
            if type(result) == 'table' and notFound(result) then return nil end
            return nil, result
        end
    end
    if type(repository.findByKey) == 'function' then
        local result = repository:findByKey(reference)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    return nil
end

function Service:_playerProfile(kind, booking)
    local repository = kind == 'worker' and self._workerRepository or self._clientRepository
    local reference = kind == 'worker' and booking.workerRef or booking.clientRef
    local explicitId = kind == 'worker' and booking.workerProfileId or booking.clientProfileId
    if type(repository) ~= 'table' then return nil end
    if explicitId ~= nil and type(repository.findById) == 'function' then
        local result = repository:findById(explicitId)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    if type(repository.findByIdentity) == 'function' then
        local profile, errorResult = self:_identityProfile(repository, reference)
        if profile then return profile end
        if errorResult then return nil, errorResult end
    end
    return nil
end

function Service:_npcProfile(booking)
    if type(self._npcProfileRepository) ~= 'table' then return nil end
    local worker
    if type(self._npcWorkerService) == 'table' and type(self._npcWorkerService.get) == 'function' then
        local result = self._npcWorkerService:get(booking.workerRef)
        if type(result) == 'table' and result.ok then worker = result.value end
    end
    local profile = worker and worker.profile
    if type(profile) == 'table' and profile.id ~= nil and type(self._npcProfileRepository.findProfileById) == 'function' then
        local result = self._npcProfileRepository:findProfileById(profile.id)
        if type(result) == 'table' and result.ok then return result.value end
    end
    local key = profile and (profile.profileKey or profile.key) or booking.workerRef
    if type(self._npcProfileRepository.findProfileByKey) == 'function' and text(key, 96) then
        local result = self._npcProfileRepository:findProfileByKey(key)
        if type(result) == 'table' and result.ok then return result.value end
        if type(result) == 'table' and notFound(result) then return nil end
        return nil, result
    end
    return nil
end

function Service:_update(repository, profile, changes, kind)
    if type(profile) ~= 'table' or next(changes) == nil then return Result.ok({ skipped = true, kind = kind }) end
    local id, version = profileId(profile), integer(profile.version, 1, 2147483647)
    if not id or not version or type(repository) ~= 'table' or type(repository.updateExpectedVersion) ~= 'function' then
        return Result.err(Codes.REPUTATION_NOT_READY, ('%s reputation persistence is unavailable'):format(kind))
    end
    local updated = repository:updateExpectedVersion(id, version, changes)
    if type(updated) ~= 'table' or not updated.ok then
        local cause = updated and updated.error and updated.error.code
        if cause == Codes.VERSION_CONFLICT then
            return Result.err(Codes.REPUTATION_CONFLICT, ('%s reputation update conflicted'):format(kind), {
                cause = cause, id = id, expectedVersion = version
            })
        end
        return Result.err(Codes.REPUTATION_UPDATE_FAILED, ('%s reputation update failed'):format(kind), {
            cause = cause
        })
    end
    return Result.ok(updatedCopy(profile, changes, updated.value and updated.value.version), { kind = kind })
end

function Service:_projectionApplied(booking, outcome)
    local repository = self._projectionRepository
    local bookingId = integer(booking and booking.id, 1, 2147483647)
    if type(repository) ~= 'table' or type(repository.findByKey) ~= 'function' or not bookingId then
        return false, nil
    end
    local key = projectionKey('reputation', bookingId, outcome.key)
    local found = repository:findByKey(bookingId, key)
    if type(found) ~= 'table' then
        return nil, Result.err(Codes.REPUTATION_NOT_READY, 'reputation projection ledger lookup returned an invalid result')
    end
    if found.ok then return true, key end
    if not notFound(found) then return nil, found end
    return false, key
end

function Service:_recordProjection(booking, outcome, key)
    local repository = self._projectionRepository
    local bookingId = integer(booking and booking.id, 1, 2147483647)
    if type(repository) ~= 'table' or type(repository.create) ~= 'function' or not bookingId or not key then
        return true
    end
    local created = repository:create({
        bookingId = bookingId,
        eventKey = key,
        eventType = 'REPUTATION_APPLIED',
        metadata = { outcome = outcome.target, projection = 'reputation' }
    })
    if type(created) == 'table' and created.ok then return true end
    local raced = type(repository.findByKey) == 'function' and repository:findByKey(bookingId, key) or nil
    if type(raced) == 'table' and raced.ok then return true end
    return nil, Result.err(Codes.REPUTATION_UPDATE_FAILED, 'reputation projection ledger could not be committed', {
        bookingId = bookingId, eventKey = key, cause = created and created.error and created.error.code
    })
end

function Service:_workerChanges(profile, outcome)
    local delta = outcome.noShow and self._config.worker.noShow or outcome.success and self._config.worker.completion or self._config.worker.cancellation
    delta = tonumber(delta) or 0
    local paymentDelta = outcome.paymentSucceeded and (tonumber(self._config.worker.paymentReliability) or 0) or 0
    local changes = {
        professionalism = clamp((tonumber(profile.professionalism) or self._config.initial) + delta, self._config.min, self._config.max),
        discretion = clamp((tonumber(profile.discretion) or self._config.initial) + delta, self._config.min, self._config.max),
        reliability = clamp((tonumber(profile.reliability) or self._config.initial) + delta + paymentDelta, self._config.min, self._config.max)
    }
    if outcome.success then changes.completedBookings = (tonumber(profile.completedBookings) or 0) + 1
    elseif outcome.noShow then changes.noShowBookings = (tonumber(profile.noShowBookings) or 0) + 1
    elseif outcome.cancelled then changes.cancelledBookings = (tonumber(profile.cancelledBookings) or 0) + 1 end
    return changes
end

function Service:_npcChanges(profile, outcome)
    local delta = outcome.noShow and self._config.worker.noShow or outcome.success and self._config.worker.completion or self._config.worker.cancellation
    delta = tonumber(delta) or 0
    local traits = copy(profile.traits or {})
    traits.reliability = clamp((tonumber(traits.reliability) or self._config.initial) + delta, self._config.min, self._config.max)
    traits.discretion = clamp((tonumber(traits.discretion) or self._config.initial) + delta, self._config.min, self._config.max)
    local changes = { traits = traits }
    if outcome.success then changes.completedBookings = (tonumber(profile.completedBookings) or 0) + 1
    elseif outcome.noShow then changes.noShowBookings = (tonumber(profile.noShowBookings) or 0) + 1
    elseif outcome.cancelled then changes.cancelledBookings = (tonumber(profile.cancelledBookings) or 0) + 1 end
    return changes
end

function Service:_clientChanges(profile, outcome)
    local delta = outcome.noShow and self._config.client.noShow or outcome.success and self._config.client.completion or self._config.client.cancellation
    delta = tonumber(delta) or 0
    local paymentDelta = outcome.paymentSucceeded and (tonumber(self._config.client.paymentReliability) or 0) or 0
    local changes = {
        reliability = clamp((tonumber(profile.reliability) or self._config.initial) + delta + paymentDelta, self._config.min, self._config.max)
    }
    if outcome.success then changes.completedBookings = (tonumber(profile.completedBookings) or 0) + 1
    elseif outcome.noShow then changes.noShowBookings = (tonumber(profile.noShowBookings) or 0) + 1
    elseif outcome.cancelled then changes.cancelledBookings = (tonumber(profile.cancelledBookings) or 0) + 1 end
    return changes
end

function Service:apply(booking, event)
    if type(booking) ~= 'table' or booking.id == nil then return invalid('reputation booking is required') end
    if not self:isEnabled() then return Result.err(Codes.REPUTATION_NOT_READY, 'reputation is disabled') end
    local outcome = outcomeFor(booking, event)
    if not outcome then return Result.ok({ bookingId = booking.id, skipped = true }, { skipped = true }) end
    local key = tostring(booking.id) .. ':' .. tostring(outcome.key)
    if self._processed[key] then return Result.ok(copy(self._results[key]), { idempotent = true, eventKey = key }) end
    local applied, projectionKeyValue = self:_projectionApplied(booking, outcome)
    if applied == nil then return projectionKeyValue end
    if applied then
        local result = { bookingId = booking.id, skipped = true }
        self._processed[key], self._results[key] = true, copy(result)
        return Result.ok(result, { idempotent = true, persistent = true, eventKey = key })
    end
    local workerResult, clientResult
    if tostring(booking.workerType or ''):upper() == 'PLAYER' then
        local worker, workerError = self:_playerProfile('worker', booking)
        if workerError then return workerError end
        if worker then
            workerResult = self:_update(self._workerRepository, worker, self:_workerChanges(worker, outcome), 'worker')
            if not workerResult.ok then return workerResult end
        end
    elseif tostring(booking.workerType or ''):upper() == 'NPC' then
        local worker, workerError = self:_npcProfile(booking)
        if workerError then return workerError end
        if worker then
            workerResult = self:_update(self._npcProfileRepository, worker, self:_npcChanges(worker, outcome), 'npc-worker')
            if not workerResult.ok then return workerResult end
        end
    end
    if tostring(booking.clientType or ''):upper() == 'PLAYER' then
        local client, clientError = self:_playerProfile('client', booking)
        if clientError then return clientError end
        if client then
            clientResult = self:_update(self._clientRepository, client, self:_clientChanges(client, outcome), 'client')
            if not clientResult.ok then return clientResult end
        end
    end
    local result = { bookingId = booking.id, outcome = outcome, worker = workerResult and workerResult.value, client = clientResult and clientResult.value }
    local committed, commitError = self:_recordProjection(booking, outcome, projectionKeyValue)
    if not committed then return commitError end
    self._processed[key], self._results[key] = true, copy(result)
    return Result.ok(result, { eventKey = key, serverAuthoritative = true, persistent = projectionKeyValue ~= nil })
end

function Service:onBookingEvent(envelope)
    local payload = type(envelope) == 'table' and envelope.payload or envelope
    local booking = type(payload) == 'table' and (payload.booking or payload) or nil
    local event = type(payload) == 'table' and payload or envelope
    local result = self:apply(booking, event)
    -- Reputation must not roll back a committed booking transition. The
    -- event bus records a typed failure for retry/observability instead.
    return result
end

function Service:subscribe(eventBus)
    if type(eventBus) ~= 'table' or type(eventBus.subscribe) ~= 'function' then
        return Result.err(Codes.REPUTATION_NOT_READY, 'reputation event bus is unavailable')
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
    if type(events) ~= 'table' then return invalid('reputation rebuild events must be an array') end
    local results = {}
    for index, event in ipairs(events) do
        local payload = type(event) == 'table' and (event.payload or event) or nil
        local booking = type(payload) == 'table' and (payload.booking or payload) or nil
        local result = self:apply(booking, payload)
        if not result.ok then return result end
        results[index] = result.value
    end
    return Result.ok(results)
end

Service.record = Service.apply
NightShift.ReputationService = Service
