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

print('NS-260..NS-263 tests passed: recovery policy, bounded dry-run, disconnect, entity-loss, and startup job contracts')
