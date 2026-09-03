local function check(value, message) assert(value, message) end
local Result = NightShift.Result
local redactedValue = 'must-not-leak'

local database = { healthCheck = function() return Result.ok({ healthy = true }) end }
local bookingRepository = {
    findAll = function()
        return Result.ok({
            { id = 1, status = 'TRAVELLING', updatedAt = '2026-09-02T11:59:00Z', scheduledAt = nil },
            { id = 2, status = 'ACTIVE' },
            { id = 3, status = 'CANCELLED' }
        })
    end
}
local paymentRepository = {
    findAll = function()
        return Result.ok({ { status = 'FAILED' }, { status = 'SUCCEEDED' }, { status = 'UNKNOWN' } })
    end
}
local reservationRepository = {
    findExpired = function() return Result.ok({ { id = 'expired:1' } }) end
}
local diagnostics = assert(NightShift.DiagnosticsService.new({
    database = database,
    bookingRepository = bookingRepository,
    paymentRepository = paymentRepository,
    locationReservationRepository = reservationRepository,
    providers = {
        framework = 'standalone',
        money = { atomicTransfer = true, secret = redactedValue },
        token = redactedValue
    },
    analyticsService = { summary = function() return Result.ok({ totalBookings = 3 }) end },
    auditService = {}
    , adminCheck = function(source) return source == 8 end
}))
check(not diagnostics:snapshot(7).ok, 'diagnostics must reject unauthorized players')
local snapshot = diagnostics:snapshot(8)
check(snapshot.ok and snapshot.metadata.sensitiveFieldsRedacted == true,
    'authorized diagnostics should return a redacted snapshot')
check(snapshot.value.database.status == 'HEALTHY'
    and snapshot.value.activeBookings.count == 2
    and snapshot.value.activeBookings.byStatus.TRAVELLING == 1
    and snapshot.value.activeBookings.stuckTravelPlans.count == 1,
    'diagnostics should expose active and stuck travel state')
check(snapshot.value.failedSettlements.count == 2
    and snapshot.value.expiredReservations.count == 1,
    'diagnostics should expose failed settlements and expired reservations')
check(snapshot.value.providers.token == nil and snapshot.value.providers.money.secret == nil,
    'diagnostics must not expose capability secrets')
check(snapshot.value.analytics.totalBookings == 3 and snapshot.value.auditAvailable == true,
    'diagnostics should include optional analytics and audit availability')
check(diagnostics:snapshot(0).ok, 'server console should always be allowed')

print('NS-242 tests passed: permission-gated health, active/stuck state, failures, and secret redaction')
