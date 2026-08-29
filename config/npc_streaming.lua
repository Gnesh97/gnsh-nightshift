NightShift = NightShift or {}

-- Server-safe streaming defaults. World models and spawn coordinates are
-- resolved by server services; this section only contains bounded policy.
NightShift.NpcStreamingConfig = {
    enabled = true,
    spawnThreshold = 0.65,
    arrivalRadius = 4.0,
    navigationTimeout = 120,
    stuckTimeout = 15,
    playerAwayDistance = 120,
    maxPlausibleArrivalDistance = 12,
    defaultEtaSeconds = 60,
    returnCooldownSeconds = 15,
    modelAllowlist = {},
    defaultModel = nil
}
