local function check(value, message) assert(value, message) end

do
    local config = NightShift.Validators.copy(NightShift.DefaultConfig)
    check(config.recovery and config.recovery.apply == false, 'recovery apply must default to false')
    local normalized, err = NightShift.Validators.validateConfig(config)
    check(normalized and normalized.recovery.apply == false and not err, 'recovery config should normalize')
    config.recovery.apply = 'true'
    normalized, err = NightShift.Validators.validateConfig(config)
    check(not normalized and err and err.code == 'INVALID_CONFIG', 'non-boolean recovery apply must fail')
end

local now = 1700000000
local rows = {
    { id = 1, version = 2, status = 'RESERVED' },
    { id = 2, version = 3, status = 'ARRIVED' },
    { id = 3, version = 1, status = 'COMPLETED' }
}
local repository = {}
function repository:findAll(options)
    local output = {}
    local start = (options.offset or 0) + 1
    local stop = math.min(#rows, start + (options.limit or 100) - 1)
    for index = start, stop do output[#output + 1] = rows[index] end
    return NightShift.Result.ok(output)
end
function repository:findById(id)
    for _, row in ipairs(rows) do if tostring(row.id) == tostring(id) then return NightShift.Result.ok(row) end end
    return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing')
end

local recovery, recoveryError = NightShift.RecoveryService.new({
    bookingRepository = repository,
    clock = { now = function() return now end },
    config = { enabled = true, required = false, apply = false, pageSize = 2, maxPages = 3 }
})
check(recovery and not recoveryError, 'recovery service must initialize')

do
    local productionDefault, productionDefaultError = NightShift.RecoveryService.new({
        bookingRepository = repository,
        environment = 'production',
        clock = { now = function() return now end },
        config = { enabled = true, required = true }
    })
    check(not productionDefault and productionDefaultError and productionDefaultError.error
        and productionDefaultError.error.code == NightShift.Errors.Codes.RECOVERY_REQUIRED,
        'production recovery must reject construction without explicit apply=true')
    local productionApply = NightShift.RecoveryService.new({
        bookingRepository = repository,
        environment = 'production',
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true }
    })
    check(productionApply and productionApply:status().ok and productionApply:status().value.apply == true,
        'production recovery must honor explicit apply=true')
    local productionDisabled, productionDisabledError = NightShift.RecoveryService.new({
        bookingRepository = repository,
        environment = 'production',
        clock = { now = function() return now end },
        config = { enabled = false, required = true, apply = true }
    })
    check(not productionDisabled and productionDisabledError and productionDisabledError.error
        and productionDisabledError.error.code == NightShift.Errors.Codes.RECOVERY_REQUIRED,
        'production recovery must not be disabled before READY')
end

do
    local reserved = recovery:classify(rows[1], now)
    check(reserved.ok and reserved.value.action == 'INTERRUPT_AND_RELEASE', 'reserved policy must interrupt and release')
    local arrived = recovery:classify(rows[2], now)
    check(arrived.ok and arrived.value.action == 'WAIT_FOR_NO_SHOW', 'arrived policy must wait for no-show')
    local completed = recovery:classify(rows[3], now)
    check(completed.ok and completed.value.action == 'RETRY_SETTLEMENT', 'completed policy must retry settlement')
    local invalid = recovery:classify({ id = 4, version = 1, status = 'UNKNOWN' }, now)
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.RECOVERY_INVALID, 'unknown state must fail closed')
end

do
    local settlementCalls = 0
    local guarded = NightShift.RecoveryService.new({
        bookingRepository = repository,
        settlementService = {
            settle = function()
                settlementCalls = settlementCalls + 1
                return NightShift.Result.ok({})
            end
        },
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true }
    })
    local completed = guarded:reconcileBooking(rows[3], { now = now, apply = true, dryRun = false })
    check(completed.ok and completed.value.pending and completed.value.settlementPending and settlementCalls == 0,
        'completed recovery must not invoke settlement without an explicit provider actor resolver')
end

do
    local completedRow = {
        id = 8, version = 4, status = 'COMPLETED',
        agreedPrice = { amountMinor = 481, currency = 'USD' }, clientRef = 'citizen:client-8'
    }
    local settlementCalls = 0
    local explicitRepository = {
        findAll = function() return NightShift.Result.ok({}) end,
        findById = function(_, id)
            return tostring(id) == '8' and NightShift.Result.ok(NightShift.Validators.copy(completedRow))
                or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing')
        end
    }
    local explicit = NightShift.RecoveryService.new({
        bookingRepository = explicitRepository,
        settlementService = {
            settle = function(_, actor, booking, request)
                settlementCalls = settlementCalls + 1
                check(actor.source == 12 and request.payerSource == 12 and request.payeeSource == 13
                    and booking.id == 8, 'recovery settlement must receive explicit actor-bound sources')
                return NightShift.Result.ok({ status = 'SETTLED', booking = { id = 8, status = 'SETTLED' } })
            end
        },
        settlementRecoveryResolver = function(booking)
            check(booking.id == 8, 'recovery resolver must receive the completed booking')
            return { approved = true, actor = { type = 'PLAYER', ref = 'citizen:client-8', source = 12 },
                request = { payerSource = 12, payeeSource = 13 } }
        end,
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true }
    })
    local settled = explicit:reconcileBooking(completedRow, { now = now, apply = true, dryRun = false })
    check(settled.ok and settled.value.recovered and settled.value.settled
        and not settled.value.pending and settlementCalls == 1,
        'explicit recovery resolver must reconcile completed settlement exactly once')
end

do
    local observed = recovery:reconcileBooking(rows[1], { now = now })
    check(observed.ok and observed.value.observed and observed.value.applyRequired, 'reconcile must be dry-run by default')
    check(rows[1].status == 'RESERVED', 'dry-run must not mutate booking')
    local run = recovery:runOnce(now, { pageSize = 2, maxPages = 3, apply = false })
    check(run.ok and run.value.scanned == 3 and run.value.pages == 2, 'bounded recovery scan must cover two pages')
    check(run.value.preserved == 1 and run.value.pending == 2, 'dry-run policy counts must be deterministic')
    local status = recovery:status()
    check(status.ok and status.value.lastRun.scanned == 3 and status.value.apply == false, 'recovery status must expose last run safely')
end

do
    local calls = 0
    local job, jobError = NightShift.StartupRecoveryJob.new({
        recoveryService = { runOnce = function(_, _, options)
            calls = calls + 1
            check(options.apply == false and options.dryRun == true, 'startup job must be observation-only')
            return NightShift.Result.ok({ scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0 })
        end },
        config = { enabled = true, required = false }
    })
    check(job and not jobError, 'startup recovery job must initialize')
    check(job:runOnce(now).ok and job:runOnce(now).metadata.idempotent == true and calls == 1, 'startup recovery job must be one-shot')
end

do
    local observedOptions
    local job, jobError = NightShift.StartupRecoveryJob.new({
        recoveryService = { runOnce = function(_, _, options)
            observedOptions = options
            return NightShift.Result.ok({ scanned = 1, pages = 1, recovered = 1, preserved = 0, pending = 0, failed = 0 })
        end },
        config = { enabled = true, required = true, apply = true },
        environment = 'production'
    })
    check(job and not jobError, 'production startup recovery job must initialize')
    check(job:runOnce(now).ok and observedOptions.apply == true and observedOptions.dryRun == false,
        'production startup recovery must apply policy before READY')
end

do
    local job = NightShift.StartupRecoveryJob.new({
        recoveryService = { runOnce = function(_, _, options)
            check(options.apply == true and options.dryRun == false,
                'prod alias must use the production apply policy')
            return NightShift.Result.ok({ scanned = 0, pages = 0, recovered = 0, preserved = 0, pending = 0, failed = 0 })
        end },
        config = { enabled = true, required = true, apply = true }, environment = 'prod'
    })
    check(job and job:status().value.production == true and job:runOnce(now).ok,
        'prod alias must be treated as production by startup recovery')
end

do
    local applyRow = {
        id = 5, version = 1, status = 'RESERVED', clientRef = 'player:12',
        workerType = 'NPC', workerRef = 'npc:recovery:5', locationRef = 'location:5'
    }
    local interruptCalls, reservationReleases, locationReleases, workerReleases, depositReleases = 0, 0, 0, 0, 0
    local applyRepository = {
        findById = function(_, id)
            return tostring(id) == '5' and NightShift.Result.ok(NightShift.Validators.copy(applyRow))
                or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing')
        end,
        findAll = function() return NightShift.Result.ok({}) end
    }
    local applyService = NightShift.RecoveryService.new({
        bookingRepository = applyRepository,
        bookingService = {
            interrupt = function(_, _, id, version)
                check(tostring(id) == '5' and version == 1, 'apply recovery must use the booking version')
                interruptCalls = interruptCalls + 1
                applyRow.status, applyRow.version = 'INTERRUPTED', 2
                return NightShift.Result.ok(NightShift.Validators.copy(applyRow))
            end
        },
        bookingReservationService = { releaseBooking = function() reservationReleases = reservationReleases + 1; return NightShift.Result.ok({}) end },
        locationReservationService = { recoverBooking = function() locationReleases = locationReleases + 1; return NightShift.Result.ok({ failed = 0 }) end },
        npcWorkerService = { release = function(_, workerKey, bookingId) check(workerKey == 'npc:recovery:5' and tostring(bookingId) == '5', 'NPC cleanup must bind worker to booking'); workerReleases = workerReleases + 1; return NightShift.Result.ok({}) end },
        depositService = { release = function(_, actor, booking) check(actor.source == 12 and tostring(booking.id) == '5', 'deposit cleanup must bind client actor and booking'); depositReleases = depositReleases + 1; return NightShift.Result.ok({ status = 'REFUNDED' }) end },
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true, releaseReservations = true, releaseHeldDeposits = true }
    })
    local applied = applyService:reconcileBooking(applyRow, { now = now, apply = true, dryRun = false })
    check(applied.ok and applied.value.recovered and not applied.value.pending, 'apply recovery must reconcile booking resources')
    check(interruptCalls == 1 and reservationReleases == 1 and locationReleases == 1 and workerReleases == 1 and depositReleases == 1,
        'apply recovery must release booking, location, NPC, and deposit resources exactly once')
end

do
    local job = NightShift.StartupRecoveryJob.new({
        recoveryService = { runOnce = function() return NightShift.Result.ok({ scanned = 1, pages = 1, recovered = 0, preserved = 0, pending = 1, failed = 0 }) end },
        config = { enabled = true, required = false, apply = true }, environment = 'production'
    })
    local unresolved = job:runOnce(now)
    check(not unresolved.ok and unresolved.error.code == NightShift.Errors.Codes.RECOVERY_REQUIRED,
        'production startup must fail closed when recovery leaves pending work')
end

do
    local cleanupRow = {
        id = 6, version = 1, status = 'RESERVED', clientRef = 'player:12',
        workerType = 'NPC', workerRef = 'npc:recovery:6'
    }
    local cleanupRepository = {
        findById = function(_, id)
            return tostring(id) == '6' and NightShift.Result.ok(NightShift.Validators.copy(cleanupRow))
                or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing')
        end,
        findAll = function() return NightShift.Result.ok({}) end
    }
    local partial = NightShift.RecoveryService.new({
        bookingRepository = cleanupRepository,
        bookingService = {
            interrupt = function()
                cleanupRow.status, cleanupRow.version = 'INTERRUPTED', 2
                return NightShift.Result.ok(NightShift.Validators.copy(cleanupRow))
            end
        },
        bookingReservationService = {
            releaseBooking = function() return NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_OPERATION_FAILED, 'lock release timeout') end
        },
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true, releaseReservations = true }
    })
    local result = partial:reconcileBooking(cleanupRow, { now = now, apply = true, dryRun = false })
    check(result.ok and result.value.pending and result.value.cleanupPending and not result.value.recovered,
        'partial recovery cleanup must remain pending and never claim recovered')
end

do
    local productionRow = {
        id = 7, version = 1, status = 'RESERVED', clientRef = 'player:12',
        workerType = 'NPC', workerRef = 'npc:recovery:7', locationRef = 'location:7'
    }
    local productionRepository = {
        findById = function(_, id)
            return tostring(id) == '7' and NightShift.Result.ok(NightShift.Validators.copy(productionRow))
                or NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing')
        end,
        findAll = function() return NightShift.Result.ok({}) end
    }
    local production = NightShift.RecoveryService.new({
        bookingRepository = productionRepository,
        environment = 'production',
        bookingService = {
            interrupt = function()
                productionRow.status, productionRow.version = 'INTERRUPTED', 2
                return NightShift.Result.ok(NightShift.Validators.copy(productionRow))
            end
        },
        clock = { now = function() return now end },
        config = { enabled = true, required = true, apply = true }
    })
    local missing = production:reconcileBooking(productionRow, { now = now, apply = true, dryRun = false })
    check(missing.ok and missing.value.pending and missing.value.cleanupPending and not missing.value.recovered,
        'production recovery must not claim success when required cleanup dependencies are missing')
end

do
    local reset, workerDisconnect, clientDisconnect = 0, 0, 0
    local disconnectService = NightShift.RecoveryService.new({
        bookingRepository = repository,
        workerModeService = { disconnect = function() workerDisconnect = workerDisconnect + 1; return NightShift.Result.ok({ interrupted = 1, idempotent = 0 }) end },
        clientModeService = { disconnect = function() clientDisconnect = clientDisconnect + 1; return NightShift.Result.ok({ interrupted = 0, idempotent = 1 }) end },
        workerAvailabilityService = { reset = function() reset = reset + 1; return NightShift.Result.ok({}) end },
        clock = { now = function() return now end }
    })
    local disconnected = disconnectService:disconnect(12)
    check(disconnected.ok and disconnected.value.interrupted == 1 and disconnected.value.idempotent == 1, 'disconnect recovery must aggregate idempotent cleanup')
    check(reset == 1 and workerDisconnect == 1 and clientDisconnect == 1, 'disconnect hooks must run once')
    local invalid = disconnectService:disconnect(0)
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.RECOVERY_INVALID, 'invalid disconnect source must fail closed')
end

do
    local deleted, marked = 0, 0
    local registry = {
        get = function() return NightShift.Result.ok({ profileKey = 'npc-1', generationToken = 'npc:npc-1:1', state = 'BOUND', travelKey = 'travel-1' }) end,
        markDeleted = function() deleted = deleted + 1; return NightShift.Result.ok({ state = 'DELETED' }) end
    }
    local entityRecovery = NightShift.RecoveryService.new({
        bookingRepository = repository,
        npcEntityRegistry = registry,
        npcTravelService = { markRecovery = function(_, key, state) check(key == 'travel-1' and state == 'ENTITY_DELETED', 'entity loss must mark travel'); marked = marked + 1; return NightShift.Result.ok({}) end },
        clock = { now = function() return now end }
    })
    local lost = entityRecovery:entityLost('npc-1', 'npc:npc-1:1')
    check(lost.ok and lost.value.deleted and lost.value.travelMarked, 'entity loss must be deterministic')
    check(deleted == 1 and marked == 1, 'entity loss handlers must run once')
end

print('NS-260..NS-266 tests passed: recovery policy, bounded dry-run, explicit settlement resolver, disconnect, entity-loss, and startup job contracts')
