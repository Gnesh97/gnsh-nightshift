NightShift = NightShift or {}

-- Worker-mode negotiation is intentionally abstract. Prices are server-owned
-- minor units and the customer response is deterministic for a given profile,
-- demand snapshot, and package.
NightShift.NegotiationConfig = NightShift.NegotiationConfig or {
    enabled = true,
    maxRounds = 3,
    expirySeconds = 300,
    minimumOfferFactor = 0.75,
    maximumOfferFactor = 1.25,
    counterStepFactor = 0.05,
    counterPatienceCost = 10,
    budgetMultipliers = { [1] = 0.90, [2] = 0.95, [3] = 1.00, [4] = 1.10, [5] = 1.20 },
    demandMultipliers = { LOW = 0.95, NORMAL = 1.00, HIGH = 1.10 }
}

NightShift.AppointmentSessionConfig = NightShift.AppointmentSessionConfig or {
    enabled = true,
    minimumDurationSeconds = 30,
    tokenTtlSeconds = 900,
    maxProximityMeters = 8.0
}
