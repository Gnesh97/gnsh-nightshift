local function check(value, message) assert(value, message) end

local Codes = NightShift.Errors.Codes
local Booking = NightShift.Domain and NightShift.Domain.Booking
local StateMachine = NightShift.BookingStateMachine
local BookingRepository = NightShift.Repositories and NightShift.Repositories.Booking
local BookingService = NightShift.BookingService
local ConflictService = NightShift.ScheduleConflictService
local ScheduledJob = NightShift.ScheduledBookingJob
local NoShowJob = NightShift.NoShowJob

check(type(Booking) == 'table', 'S18 booking domain must be loaded')
check(type(StateMachine) == 'table', 'S18 booking state machine must be loaded')
check(type(BookingRepository) == 'table', 'S18 booking repository must be loaded')
check(type(BookingService) == 'table', 'S18 booking service must be loaded')
check(type(ConflictService) == 'table', 'S18 schedule conflict service must be loaded')
check(type(ScheduledJob) == 'table', 'S18 scheduled booking job must be loaded')
check(type(NoShowJob) == 'table', 'S18 no-show job must be loaded')

do
    local normalized, configError = NightShift.Validators.validateConfig(NightShift.Validators.copy(NightShift.DefaultConfig))
    check(normalized and not configError and normalized.scheduling.batchSize == 50, 'default scheduling config must pass root validation')
    local invalidConfig = NightShift.Validators.copy(NightShift.DefaultConfig)
    invalidConfig.scheduling = NightShift.Validators.copy(invalidConfig.scheduling)
    invalidConfig.scheduling.tickSeconds = 0
    normalized, configError = NightShift.Validators.validateConfig(invalidConfig)
    check(not normalized and configError.code == Codes.INVALID_CONFIG and configError.field == 'scheduling.tickSeconds', 'unsafe scheduling settings must fail closed')
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

local function ok(value, metadata) return NightShift.Result.ok(value, metadata) end

local function bookingInput(overrides)
    local value = {
        id = 1,
        idempotencyKey = 's18-booking-1',
        initiatorType = 'PLAYER',
        clientType = 'PLAYER',
        clientRef = 'identity:client-1',
        workerType = 'NPC',
        workerRef = 'npc-worker-1',
        servicePackage = { id = 'standard', priceMinor = 10000, durationMinutes = 30, currency = 'USD' },
        meetingMode = 'IN_PERSON',
        locationType = 'CONFIGURED',
        locationRef = 'room-1',
        scheduledAt = 2000,
        status = 'ACCEPTED',
        version = 1
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

do
    check(Booking.statuses.SCHEDULED == true, 'S18 must add a SCHEDULED booking state')
    check(StateMachine.new():canTransition('ACCEPTED', 'SCHEDULED').ok, 'accepted bookings must be schedulable')
    check(StateMachine.new():canTransition('SCHEDULED', 'RESERVED').ok, 'scheduled bookings must activate to reserved')
    check(StateMachine.new():canTransition('ARRIVED', 'EXPIRED').ok, 'arrived bookings must support no-show expiration')
end

do
    local calls = {}
    local row = {
        id = 11, idempotency_key = 's18-db-1', initiator_type = 'PLAYER',
        client_type = 'PLAYER', client_ref = 'identity:client-1',
        worker_type = 'NPC', worker_ref = 'npc-worker-1',
        service_package_id = 'standard', mode = 'IN_PERSON', meeting_mode = 'IN_PERSON',
        location_type = 'CONFIGURED', location_ref = 'room-1', price_minor = 10000,
        currency = 'USD', status = 'SCHEDULED', scheduled_at = '2026-09-02 12:00:00.000',
        version = 3
    }
    local db = {}
    function db:query(sql, params)
        calls[#calls + 1] = { sql = sql, params = copy(params) }
        return ok({ copy(row) })
    end
    local repository = assert(BookingRepository.new({ db = db }))
    local due = repository:findDueScheduled(1000, { leadTimeSeconds = 60, limit = 5 })
    check(due.ok and #due.value == 1 and due.value[1].status == 'SCHEDULED', 'scheduled due query must map database rows')
    check(calls[1].sql:find('status = ?', 1, true) ~= nil and calls[1].sql:find('scheduled_at <= ?', 1, true) ~= nil, 'scheduled due query must use bounded predicates')
    check(calls[1].sql:find('SCHEDULED', 1, true) == nil, 'scheduled due query must parameterize state values')
    check(calls[1].params[1] == 'SCHEDULED' and calls[1].params[#calls[1].params] == 5, 'scheduled due query parameters must include state and limit')

    row.status = 'ARRIVED'
    row.updated_at = '2026-09-02 11:00:00.000'
    local noShow = repository:findDueArrived(1000, { graceSeconds = 60, limit = 7 })
    check(noShow.ok and #noShow.value == 1 and noShow.value[1].status == 'ARRIVED', 'arrived due query must map database rows')
    check(calls[2].sql:find('updated_at <= ?', 1, true) ~= nil and calls[2].params[1] == 'ARRIVED', 'arrived due query must use the grace cutoff as a parameter')
end

do
    local conflict = assert(ConflictService.new({ bufferSeconds = 60, defaultDurationSeconds = 1800 }))
    local existing = assert(Booking.new(bookingInput({
        id = 41, idempotencyKey = 's18-existing', status = 'SCHEDULED',
        scheduledAt = 2000, workerRef = 'npc-worker-1', locationRef = 'room-1'
    })))
    local candidate = assert(Booking.new(bookingInput({
        id = 42, idempotencyKey = 's18-candidate', scheduledAt = 2030,
        workerRef = 'npc-worker-1', locationRef = 'room-2'
    })))
    local workerConflict = conflict:check(candidate, { existing })
    check(not workerConflict.ok and workerConflict.error.code == Codes.SCHEDULING_CONFLICT and workerConflict.error.details.conflictType == 'WORKER', 'worker overlap must be rejected with a typed conflict')

    candidate.locationRef = 'room-1'
    candidate.workerRef = 'npc-worker-2'
    local locationConflict = conflict:check(candidate, { existing })
    check(not locationConflict.ok and locationConflict.error.details.conflictType == 'LOCATION', 'location overlap must be rejected with a typed conflict')

    candidate.locationRef = 'room-2'
    candidate.scheduledAt = 4000
    local independent = conflict:check(candidate, { existing })
    check(independent.ok, 'non-overlapping worker and location windows must be accepted')
end

local function newMemoryRepository(initial)
    local repository = { rows = {}, nextId = 100, dueScheduled = {}, dueArrived = {} }
    for _, value in ipairs(initial or {}) do repository.rows[value.id] = copy(value) end
    function repository:findById(id)
        local value = self.rows[tonumber(id)]
        if not value then return NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking not found') end
        return ok(copy(value))
    end
    function repository:findByIdempotencyKey(key)
        for _, value in pairs(self.rows) do
            if value.idempotencyKey == key then return ok(copy(value)) end
        end
        return NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking not found')
    end
    function repository:create(value)
        local item = copy(value)
        item.id = self.nextId
        self.nextId = self.nextId + 1
        item.version = 1
        self.rows[item.id] = item
        return ok({ insertId = item.id })
    end
    function repository:updateExpectedVersion(id, version, changes)
        local value = self.rows[tonumber(id)]
        if not value then return NightShift.Result.err(Codes.REPOSITORY_NOT_FOUND, 'booking not found') end
        if value.version ~= version then return NightShift.Result.err(Codes.VERSION_CONFLICT, 'booking version does not match') end
        local nextValue = copy(value)
        for key, item in pairs(changes or {}) do nextValue[key] = copy(item) end
        nextValue.version = version + 1
        self.rows[nextValue.id] = nextValue
        return ok({ id = nextValue.id, version = nextValue.version })
    end
    function repository:findDueScheduled(_, options)
        self.lastScheduledOptions = copy(options)
        return ok(copy(self.dueScheduled))
    end
    function repository:findDueArrived(_, options)
        self.lastArrivedOptions = copy(options)
        return ok(copy(self.dueArrived))
    end
    return repository
end

do
    local scheduled = assert(Booking.new(bookingInput({ id = 51, idempotencyKey = 's18-scheduled', status = 'ACCEPTED', scheduledAt = 5000 })))
    local repository = newMemoryRepository({ scheduled })
    local events = {}
    local timeline = { record = function(_, booking, oldState, newState, metadata)
        events[#events + 1] = { id = booking.id, from = oldState, to = newState, metadata = copy(metadata) }
        return ok({ id = #events })
    end }
    local bookingService = assert(BookingService.new({
        repository = repository,
        timelineService = timeline,
        clock = { now = function() return 1000 end, timestamp = function() return '1970-01-01T00:16:40Z' end },
        scheduleConflictService = assert(ConflictService.new({ listBookings = function() return {} end }))
    }))
    local scheduledResult = bookingService:schedule({ type = 'SYSTEM', ref = 'nightshift:test' }, 51, 5000, 1)
    check(scheduledResult.ok and scheduledResult.value.status == 'SCHEDULED' and scheduledResult.value.scheduledAt == 5000, 'booking schedule must persist the scheduled timestamp')
    local activeResult = bookingService:activateScheduled({ type = 'SYSTEM', ref = 'nightshift:test' }, 51, scheduledResult.value.version)
    check(activeResult.ok and activeResult.value.status == 'RESERVED', 'scheduled booking must activate idempotently into reserved')
    local retry = bookingService:activateScheduled({ type = 'SYSTEM', ref = 'nightshift:test' }, 51, activeResult.value.version)
    check(retry.ok and retry.metadata and retry.metadata.idempotent == true, 'repeated scheduled activation must be idempotent')
    check(#events == 2 and events[1].to == 'SCHEDULED' and events[2].to == 'RESERVED', 'schedule and activation must write timeline events')
end

do
    local due = assert(Booking.new(bookingInput({ id = 61, idempotencyKey = 's18-job-due', status = 'SCHEDULED' })))
    local repository = newMemoryRepository()
    repository.dueScheduled = { due }
    local activated = 0
    local job = assert(ScheduledJob.new({
        repository = repository,
        bookingService = { activateScheduled = function(_, actor, id, version)
            activated = activated + 1
            check(actor.type == 'SYSTEM' and id == 61 and version == 1, 'scheduler must use a system actor and optimistic version')
            return ok({ status = 'RESERVED' })
        end },
        clock = { now = function() return 1000 end },
        config = { reservationLeadTimeSeconds = 120, batchSize = 10 }
    }))
    local result = job:runOnce()
    check(result.ok and result.value.scanned == 1 and result.value.activated == 1 and activated == 1, 'scheduler batch must activate due bookings')
    check(repository.lastScheduledOptions.leadTimeSeconds == 120 and repository.lastScheduledOptions.limit == 10, 'scheduler must pass bounded lead-time and batch options')
end

do
    local due = assert(Booking.new(bookingInput({ id = 71, idempotencyKey = 's18-no-show', status = 'ARRIVED' })))
    local repository = newMemoryRepository()
    repository.dueArrived = { due }
    local expired, refunded, reputation = 0, 0, 0
    local job = assert(NoShowJob.new({
        repository = repository,
        bookingService = { expire = function(_, actor, id, version, reason)
            expired = expired + 1
            check(actor.type == 'SYSTEM' and id == 71 and version == 1 and reason == 'client-no-show', 'no-show job must expire with a typed reason')
            return ok({ id = id, status = 'EXPIRED' })
        end },
        refundService = { refund = function(_, booking) refunded = refunded + 1; check(booking.id == 71); return ok({ refunded = true }) end },
        reputationService = { apply = function(_, booking, event) reputation = reputation + 1; check(booking.id == 71 and event.noShow == true); return ok({ applied = true }) end },
        clock = { now = function() return 2000 end },
        config = { noShowGraceSeconds = 300, batchSize = 4 }
    }))
    local result = job:runOnce()
    check(result.ok and result.value.scanned == 1 and result.value.expired == 1 and expired == 1 and refunded == 1 and reputation == 1, 'no-show batch must expire and run settlement hooks')
    repository.dueArrived = {}
    local retry = job:runOnce()
    check(retry.ok and retry.value.scanned == 0 and expired == 1, 'no-show processing must be restart-safe and idempotent')
end

do
    local repository = {
        findDueScheduled = function() return ok({}) end,
        findDueArrived = function() return ok({}) end
    }
    local bookingService = {
        activateScheduled = function() return ok({}) end,
        expire = function() return ok({}) end
    }
    local instance = NightShift.ServerBootstrap.new({
        startSchedulingJobs = false,
        stages = {
            config = function() return { ok = true, config = { features = { scheduling = true }, scheduling = NightShift.Validators.copy(NightShift.SchedulingConfig) } } end,
            db = function() return { ok = true } end,
            adapters = function() return { ok = true } end,
            repositories = function() return { ok = true, repositories = { booking = repository } } end,
            services = function() return { ok = true, services = { booking = bookingService } } end
        }
    })
    local booted, results = instance:boot()
    check(booted and results.jobs and results.jobs.jobs and results.jobs.jobs.scheduledBooking and results.jobs.jobs.noShow, 'bootstrap jobs stage must wire both restart-safe batch jobs')
    instance:stop('s18-test')
end

print('NS-180..NS-183 tests passed: scheduling, conflict policy, scheduler activation, and no-show processing')
