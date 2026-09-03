NightShift = NightShift or {}

-- Recovery is intentionally bounded. Development keeps an observation-only
-- default; production bootstrap promotes this policy to apply=true unless an
-- explicit runtime override disables it (which then fails readiness).
NightShift.RecoveryConfig = NightShift.RecoveryConfig or {
    enabled = true,
    required = false,
    apply = false,
    pageSize = 100,
    maxPages = 20,
    disconnectGraceSeconds = 30,
    interruptReserved = true,
    interruptTravelling = true,
    interruptActive = true,
    retryCompletedSettlement = true,
    releaseHeldDeposits = true,
    releaseReservations = true
}
