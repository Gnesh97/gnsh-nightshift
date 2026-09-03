NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local POLICY = {
    SCHEDULED = { category = 'SCHEDULED', action = 'PRESERVE' },
    RESERVED = { category = 'RESERVED', action = 'INTERRUPT_AND_RELEASE' },
    TRAVELLING = { category = 'TRAVELLING', action = 'INTERRUPT_AND_RELEASE' },
    ARRIVED = { category = 'ARRIVED', action = 'WAIT_FOR_NO_SHOW' },
    ACTIVE = { category = 'ACTIVE', action = 'INTERRUPT_AND_RELEASE' },
    COMPLETED = { category = 'COMPLETED', action = 'RETRY_SETTLEMENT' }
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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.RECOVERY_INVALID, message, details)
end

local function errorValue(result, fallbackCode, fallbackMessage)
    local value = type(result) == 'table' and (result.error or result) or {}
    return {
        code = value.code or fallbackCode or Codes.RECOVERY_OPERATION_FAILED,
        message = value.message or fallbackMessage or 'recovery operation failed'
    }
end

local function unwrap(result, fallbackCode, fallbackMessage)
    if type(result) ~= 'table' then return nil, Result.err(fallbackCode, fallbackMessage or 'recovery dependency returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value, nil end
    return result, nil
end

local function nowValue(clock, supplied)
    if supplied ~= nil then
        supplied = tonumber(supplied)
        if finite(supplied) and supplied >= 0 then return math.floor(supplied) end
        return nil
    end
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and finite(value) and value >= 0 then return math.floor(value) end
    end
    return os.time()
end

local function sourceValue(value)
    return integer(value, 1, 65535)
end

local function normalizeId(value)
    if type(value) == 'table' then value = value.id end
    if integer(value, 1) then return tostring(math.floor(tonumber(value))) end
    if text(value, 160) then return tostring(value) end
    return nil
end

local function activeStatus(status)
    status = type(status) == 'string' and status:upper() or ''
    return status == 'RESERVED' or status == 'TRAVELLING' or status == 'ARRIVED' or status == 'ACTIVE'
end

local function notFound(result)
    local code = errorValue(result).code
    return code == Codes.REPOSITORY_NOT_FOUND or code == Codes.BOOKING_NOT_FOUND
        or code == Codes.NPC_WORKER_NOT_FOUND
end

local function items(value)
    if type(value) ~= 'table' then return nil end
    if type(value.items) == 'table' then return value.items end
    if type(value.bookings) == 'table' then return value.bookings end
    return value
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('recovery options must be a table') end
    local repository = options.bookingRepository or options.repository
    if type(repository) ~= 'table' or type(repository.findAll) ~= 'function' then
        return nil, Result.err(Codes.RECOVERY_NOT_READY, 'recovery service requires a booking repository with findAll')
    end
    local configured = options.config or NightShift.RecoveryConfig or {}
    if type(configured) ~= 'table' then return nil, invalid('recovery configuration must be a table') end
    local defaults = NightShift.RecoveryConfig or {}
    local function flag(name, fallback)
        local value = configured[name]
        if value == nil then value = defaults[name] end
        if value == nil then value = fallback end
        if type(value) ~= 'boolean' then return nil end
        return value
    end
    local function setting(name, fallback, minimum, maximum)
        local value = configured[name]
        if value == nil then value = defaults[name] end
        value = value == nil and fallback or tonumber(value)
        return integer(value, minimum, maximum)
    end
    local enabled, required, apply = flag('enabled', true), flag('required', false), flag('apply', false)
    local pageSize, maxPages = setting('pageSize', 100, 1, 1000), setting('maxPages', 20, 1, 100)
    local grace = setting('disconnectGraceSeconds', 30, 0, 86400)
    if enabled == nil or required == nil or apply == nil or not pageSize or not maxPages or not grace then
        return nil, invalid('recovery configuration contains an invalid setting')
    end
    local systemActor = copy(options.systemActor or { type = 'SYSTEM', ref = 'nightshift:recovery' })
    if type(systemActor) ~= 'table' or not text(systemActor.ref, 200) then return nil, invalid('recovery system actor is invalid') end
    systemActor.type = type(systemActor.type) == 'string' and systemActor.type:upper() or 'SYSTEM'
    if systemActor.type ~= 'SYSTEM' and systemActor.type ~= 'ADMIN' then return nil, invalid('recovery system actor type is invalid') end
    return setmetatable({
        _repository = repository, _booking = options.bookingService or options.booking,
        _bookingReservation = options.bookingReservationService or options.bookingReservation,
        _locationReservation = options.locationReservationService or options.locationReservation,
        _locationRepository = options.locationReservationRepository,
        _npcProfileRepository = options.npcProfileRepository or options.npcProfilesRepository,
        _workerAvailability = options.workerAvailabilityService or options.workerAvailability,
        _clientMode = options.clientModeService or options.clientMode,
        _workerMode = options.workerModeService or options.workerMode,
        _travel = options.npcTravelService or options.npcTravel,
        _entityRegistry = options.npcEntityRegistry or options.npcEntityService,
        _settlement = options.settlementService or options.settlement,
        _eventBus = options.eventBus, _audit = options.auditService or options.audit,
        _actorResolver = options.actorResolver or options.recoveryActorResolver,
        _clock = options.clock or (NightShift.Clock and NightShift.Clock.new and NightShift.Clock.new() or nil),
        _systemActor = systemActor,
        _config = {
            enabled = enabled, required = required, apply = apply, pageSize = pageSize, maxPages = maxPages,
            disconnectGraceSeconds = grace, interruptReserved = flag('interruptReserved', true),
            interruptTravelling = flag('interruptTravelling', true), interruptActive = flag('interruptActive', true),
            retryCompletedSettlement = flag('retryCompletedSettlement', true),
            releaseHeldDeposits = flag('releaseHeldDeposits', true), releaseReservations = flag('releaseReservations', true)
        },
        _running = false, _lastRun = nil
    }, Service)
end

function Service:config()
    return copy(self._config)
end

function Service:classify(booking, suppliedNow)
    if type(booking) ~= 'table' then return invalid('booking must be a table') end
    local id, version = normalizeId(booking), integer(booking.version, 1)
    local status = type(booking.status) == 'string' and booking.status:upper() or nil
    if not id or not version or not status then return invalid('booking recovery identity is invalid', { id = id, status = status }) end
    if NightShift.Domain and NightShift.Domain.Booking and NightShift.Domain.Booking.statuses
        and not NightShift.Domain.Booking.statuses[status] then
        return invalid('booking recovery status is unknown', { status = status })
    end
    local policy = POLICY[status] or { category = 'OTHER', action = 'PRESERVE' }
    if status == 'RESERVED' and self._config.interruptReserved ~= true then policy = { category = 'RESERVED', action = 'PRESERVE' } end
    if status == 'TRAVELLING' and self._config.interruptTravelling ~= true then policy = { category = 'TRAVELLING', action = 'PRESERVE' } end
    if status == 'ACTIVE' and self._config.interruptActive ~= true then policy = { category = 'ACTIVE', action = 'PRESERVE' } end
    if status == 'COMPLETED' and self._config.retryCompletedSettlement ~= true then policy = { category = 'COMPLETED', action = 'PRESERVE' } end
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('recovery clock returned an invalid timestamp') end
    return Result.ok({
        bookingId = id, version = version, status = status, category = policy.category, action = policy.action,
        releaseReservations = policy.action == 'INTERRUPT_AND_RELEASE',
        retrySettlement = policy.action == 'RETRY_SETTLEMENT', waitForNoShow = policy.action == 'WAIT_FOR_NO_SHOW', now = now
    })
end

Service.classifyBooking = Service.classify

function Service:_load(value)
    local id = normalizeId(value)
    if not id then return nil, invalid('booking recovery ID is invalid') end
    if type(value) == 'table' then return copy(value) end
    if type(self._repository.findById) ~= 'function' then return nil, Result.err(Codes.RECOVERY_NOT_READY, 'booking lookup is unavailable') end
    local result = self._repository:findById(id)
    local booking, errorResult = unwrap(result, Codes.RECOVERY_OPERATION_FAILED, 'booking lookup returned an invalid result')
    if not booking then return nil, errorResult end
    return copy(booking)
end

function Service:_publish(booking, summary, classification)
    if type(self._eventBus) == 'table' and type(self._eventBus.publishCommitted) == 'function' then
        pcall(self._eventBus.publishCommitted, self._eventBus, 'booking.recovery_reconciled', {
            bookingId = tostring(booking.id), status = classification.status, category = classification.category,
            action = classification.action, recovered = summary.recovered == true, pending = summary.pending == true
        }, { correlationId = booking.correlationId })
    end
    if type(self._audit) == 'table' and type(self._audit.record) == 'function' then
        pcall(self._audit.record, self._audit, {
            actor = { actorType = 'SYSTEM', ref = self._systemActor.ref }, action = 'booking.recovery_reconcile',
            target = { type = 'BOOKING', ref = tostring(booking.id) }, result = Result.ok({ category = classification.category }),
            reason = 'recovery-observation', metadata = { category = classification.category, pending = summary.pending == true }
        })
    end
end

function Service:reconcileBooking(value, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('recovery reconcile options must be a table') end
    local booking, loadError = self:_load(value)
    if not booking then return loadError end
    local classified, classifyError = self:classify(booking, options.now)
    if not classified then return classifyError end
    local summary = copy(classified.value)
    summary.recovered, summary.preserved, summary.pending, summary.failed = false, false, false, false
    if options.dryRun ~= false and not (self._config.apply == true and options.apply == true) then
        summary.observed, summary.applyRequired = true, true
        summary.preserved = summary.action == 'PRESERVE' or summary.action == 'WAIT_FOR_NO_SHOW'
        -- Every non-preserved state needs an explicit operator decision in the
        -- safe observation pass, including completed rows whose settlement
        -- would be retried later.
        summary.pending = not summary.preserved
        return Result.ok(summary, { dryRun = true })
    end
    -- Applying recovery is an explicit, separately reviewable operation.  The
    -- default startup path never reaches this branch.
    if self._config.apply ~= true or options.apply ~= true then
        return Result.err(Codes.RECOVERY_REQUIRED, 'recovery apply mode is disabled; explicit activation is required')
    end
    if summary.action == 'PRESERVE' or summary.action == 'WAIT_FOR_NO_SHOW' then
        summary.preserved, summary.waitForNoShow = true, summary.action == 'WAIT_FOR_NO_SHOW'
        self:_publish(booking, summary, classified.value)
        return Result.ok(summary)
    end
    if summary.action == 'RETRY_SETTLEMENT' then
        if type(self._settlement) ~= 'table' or type(self._settlement.settle) ~= 'function' then
            summary.pending, summary.settlementPending = true, true
            return Result.ok(summary, { pending = true })
        end
        summary.pending, summary.settlementPending = true, true
        return Result.ok(summary, { pending = true, settlementRequiresExplicitActor = true })
    end
    if type(self._booking) ~= 'table' or type(self._booking.interrupt) ~= 'function' then
        return Result.err(Codes.RECOVERY_NOT_READY, 'booking interruption service is unavailable')
    end
    local interrupted = self._booking:interrupt(self._systemActor, booking.id, booking.version, ('recovery-%s'):format(summary.category:lower()))
    if type(interrupted) ~= 'table' or not interrupted.ok then
        if type(interrupted) == 'table' and interrupted.error and interrupted.error.code == Codes.VERSION_CONFLICT and type(self._repository.findById) == 'function' then
            local latest = self._repository:findById(booking.id)
            if type(latest) == 'table' and latest.ok and latest.value and latest.value.status == 'INTERRUPTED' then
                summary.recovered, summary.idempotent = true, true
                return Result.ok(summary, { idempotent = true })
            end
        end
        local errorResult = errorValue(interrupted)
        summary.failed, summary.error = true, errorResult
        return Result.ok(summary, { failed = true })
    end
    summary.recovered = true
    summary.interrupted = true
    self:_publish(interrupted.value or booking, summary, classified.value)
    return Result.ok(summary)
end

function Service:runOnce(suppliedNow, options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('recovery run options must be a table') end
    if self._running then return Result.err(Codes.RECOVERY_CONFLICT, 'recovery run is already in progress') end
    if self._config.enabled ~= true then
        local skipped = { scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0, skipped = true, errors = {} }
        self._lastRun = copy(skipped)
        return Result.ok(skipped, { disabled = true })
    end
    local now = nowValue(self._clock, suppliedNow)
    if not now then return invalid('recovery clock returned an invalid timestamp') end
    local pageSize = integer(options.pageSize, 1, 1000) or self._config.pageSize
    local maxPages = integer(options.maxPages, 1, 100) or self._config.maxPages
    self._running = true
    local summary = { now = now, scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0, idempotent = 0, categories = {}, errors = {} }
    local ok, runError = pcall(function()
        for page = 1, maxPages do
            local result = self._repository:findAll({ limit = pageSize, offset = (page - 1) * pageSize })
            local values, fetchError = unwrap(result, Codes.RECOVERY_OPERATION_FAILED, 'booking recovery query returned an invalid result')
            if not values then error(fetchError) end
            local list = items(values) or {}
            if type(list) ~= 'table' then error(Result.err(Codes.RECOVERY_OPERATION_FAILED, 'booking recovery rows are invalid')) end
            summary.pages = page
            for _, booking in ipairs(list) do
                summary.scanned = summary.scanned + 1
                local reconciled = self:reconcileBooking(booking, { now = now, dryRun = options.apply ~= true })
                if type(reconciled) == 'table' and reconciled.ok then
                    local value = reconciled.value or {}
                    local category = value.category or 'OTHER'
                    summary.categories[category] = (summary.categories[category] or 0) + 1
                    if value.recovered then summary.recovered = summary.recovered + 1
                    elseif value.preserved then summary.preserved = summary.preserved + 1
                    elseif value.pending then summary.pending = summary.pending + 1
                    else summary.idempotent = summary.idempotent + 1 end
                    if value.failed then summary.failed = summary.failed + 1 end
                else
                    summary.failed = summary.failed + 1
                    if #summary.errors < 20 then
                        local errorResult = errorValue(reconciled)
                        summary.errors[#summary.errors + 1] = { id = normalizeId(booking), code = errorResult.code, message = errorResult.message }
                    end
                end
            end
            local total = type(values) == 'table' and tonumber(values.total) or nil
            if #list < pageSize or (total and page * pageSize >= total) then break end
        end
    end)
    self._running = false
    if not ok then
        local errorResult = errorValue(runError)
        self._lastRun = copy(summary)
        return Result.err(errorResult.code, errorResult.message, { summary = summary })
    end
    self._lastRun = copy(summary)
    return Result.ok(summary, { now = now, pageSize = pageSize, maxPages = maxPages, dryRun = options.apply ~= true })
end

function Service:lastRun()
    return Result.ok(copy(self._lastRun or { scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0, categories = {}, errors = {} }))
end

function Service:status()
    return Result.ok({ enabled = self._config.enabled, apply = self._config.apply, running = self._running, lastRun = copy(self._lastRun) })
end

function Service:disconnect(playerSource, reason)
    local source = sourceValue(playerSource)
    if not source then return invalid('disconnect recovery source is invalid') end
    local summary = { source = source, reason = text(reason, 160) and reason or 'player-disconnected', graceSeconds = self._config.disconnectGraceSeconds, interrupted = 0, idempotent = 0, failures = {} }
    for _, dependency in ipairs({ { name = 'workerMode', value = self._workerMode }, { name = 'clientMode', value = self._clientMode } }) do
        if type(dependency.value) == 'table' and type(dependency.value.disconnect) == 'function' then
            local ok, result = pcall(dependency.value.disconnect, dependency.value, source, summary.reason)
            if not ok or type(result) ~= 'table' or result.ok ~= true then
                local errorResult = ok and errorValue(result) or { code = Codes.RECOVERY_OPERATION_FAILED, message = 'disconnect dependency raised an error' }
                summary.failures[#summary.failures + 1] = { dependency = dependency.name, code = errorResult.code, message = errorResult.message }
            else
                local value = result.value or {}
                summary.interrupted = summary.interrupted + (tonumber(value.interrupted) or 0)
                summary.idempotent = summary.idempotent + (tonumber(value.idempotent) or 0)
            end
        end
    end
    if type(self._workerAvailability) == 'table' and type(self._workerAvailability.reset) == 'function' then
        local ok, result = pcall(self._workerAvailability.reset, self._workerAvailability, source, summary.reason)
        if not ok or type(result) ~= 'table' or result.ok ~= true then
            local errorResult = ok and errorValue(result) or { code = Codes.RECOVERY_OPERATION_FAILED, message = 'availability reset raised an error' }
            summary.failures[#summary.failures + 1] = { dependency = 'workerAvailability', code = errorResult.code, message = errorResult.message }
        end
    end
    if #summary.failures > 0 then return Result.err(Codes.DISCONNECT_RECOVERY_REQUIRED, 'player disconnect cleanup requires recovery', summary) end
    return Result.ok(summary, { idempotent = summary.interrupted == 0 })
end

function Service:entityLost(profileKey, generationTokenValue, options)
    options = options or {}
    if type(options) ~= 'table' or not text(profileKey, 160) or not text(generationTokenValue, 200) then return invalid('NPC entity recovery identity is invalid') end
    if type(self._entityRegistry) ~= 'table' or type(self._entityRegistry.get) ~= 'function' or type(self._entityRegistry.markDeleted) ~= 'function' then
        return Result.err(Codes.RECOVERY_NOT_READY, 'NPC entity registry is unavailable')
    end
    local found = self._entityRegistry:get(profileKey)
    local binding = type(found) == 'table' and found.ok and found.value or nil
    if not binding then
        if notFound(found) then return Result.ok({ profileKey = profileKey, idempotent = true, recoveryRequired = false }) end
        return found
    end
    if binding.generationToken and binding.generationToken ~= generationTokenValue then return Result.err(Codes.RECOVERY_CONFLICT, 'NPC entity generation token does not match') end
    if tostring(binding.state or ''):upper() == 'DELETED' then return Result.ok({ profileKey = profileKey, bookingId = binding.bookingId, idempotent = true, recoveryRequired = false }) end
    local deleted = self._entityRegistry:markDeleted(profileKey, generationTokenValue)
    if type(deleted) ~= 'table' or not deleted.ok then return deleted end
    local summary = { profileKey = profileKey, bookingId = binding.bookingId, travelKey = binding.travelKey, deleted = true, travelMarked = false, recoveryRequired = false, observed = self._config.apply ~= true }
    if binding.travelKey and type(self._travel) == 'table' and type(self._travel.markRecovery) == 'function' then
        local marked = self._travel:markRecovery(binding.travelKey, 'ENTITY_DELETED')
        if type(marked) == 'table' and marked.ok then summary.travelMarked = true else summary.recoveryRequired = not notFound(marked) end
    end
    if binding.bookingId and self._config.apply == true and options.apply == true and type(self._repository.findById) == 'function' then
        local bookingResult = self._repository:findById(binding.bookingId)
        if type(bookingResult) == 'table' and bookingResult.ok and activeStatus(bookingResult.value.status) then
            local recovered = self:reconcileBooking(bookingResult.value, { now = options.now, apply = true, dryRun = false })
            summary.bookingRecovered = type(recovered) == 'table' and recovered.ok and recovered.value and recovered.value.recovered == true
            summary.recoveryRequired = summary.recoveryRequired or not summary.bookingRecovered
        end
    end
    return Result.ok(summary, { recoveryRequired = summary.recoveryRequired })
end

Service.recoverEntityLoss = Service.entityLost
NightShift.RecoveryPolicy = copy(POLICY)
NightShift.RecoveryService = Service
NightShift.Services.Recovery = Service
