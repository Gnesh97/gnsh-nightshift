NightShift = NightShift or {}

-- Recovery is intentionally bounded. It reconciles only a finite page window
-- before READY and leaves unresolved financial effects visible for retry.
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
