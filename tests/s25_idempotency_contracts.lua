local function check(value, message) assert(value, message) end

local now = 1000
local clock = NightShift.Clock.new({ now = function() return now end })
local store, storeError = NightShift.IdempotencyStore.new({ clock = clock, ttlSeconds = 10, maxEntries = 32 })
check(store and not storeError, 'idempotency store must initialize with bounded options')

do
    local claimed = store:claim('booking.confirm', 'request-1', { bookingId = 7, amount = 481 })
    check(claimed.ok and claimed.value.status == 'PENDING' and claimed.value.replayed == false, 'first idempotency claim must be pending')
    local pending = store:claim('booking.confirm', 'request-1', { bookingId = 7, amount = 481 })
    check(not pending.ok and pending.error.code == NightShift.Errors.Codes.IDEMPOTENCY_IN_PROGRESS, 'duplicate pending claim must be rejected')
    local conflict = store:claim('booking.confirm', 'request-1', { bookingId = 7, amount = 482 })
    check(not conflict.ok and conflict.error.code == NightShift.Errors.Codes.IDEMPOTENCY_CONFLICT, 'different payload must conflict')
    local completed = store:complete('booking.confirm', 'request-1', { bookingId = 7, amount = 481 }, { bookingId = 7, status = 'ACCEPTED' })
    check(completed.ok and completed.value.status == 'COMPLETED', 'claimed operation must complete')
    local replay = store:claim('booking.confirm', 'request-1', { bookingId = 7, amount = 481 })
    check(replay.ok and replay.value.replayed == true and replay.value.value.status == 'ACCEPTED', 'completed claim must replay safely')
    local fetched = store:get('booking.confirm', 'request-1')
    check(fetched.ok and fetched.value.status == 'COMPLETED', 'completed entry must be readable')
end

do
    now = 1011
    local expired = store:get('booking.confirm', 'request-1')
    check(not expired.ok and expired.error.code == NightShift.Errors.Codes.IDEMPOTENCY_EXPIRED, 'expired entry must not replay')
    local fresh = store:claim('booking.confirm', 'request-1', { bookingId = 7, amount = 482 })
    check(fresh.ok and fresh.value.replayed == false, 'expired key may be claimed again')
end

do
    local invalid = store:claim('not allowed', 'key', {})
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.IDEMPOTENCY_INVALID, 'scope allowlist must reject unsafe values')
    local completedWithoutClaim = store:complete('booking.confirm', 'missing', {}, {})
    check(not completedWithoutClaim.ok and completedWithoutClaim.error.code == NightShift.Errors.Codes.IDEMPOTENCY_INVALID,
        'completion must require an existing claim')
end

local purged = store:purge(now + 20, 10)
check(purged.ok and purged.value.removed >= 1, 'purge must remove expired bounded entries')
print('NS-253..NS-256 tests passed: idempotency claim, replay, conflict, expiry, and bounded purge')
