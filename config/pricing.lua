NightShift = NightShift or {}

NightShift.PricingConfig = NightShift.PricingConfig or {
    enabled = true,
    currency = 'USD',
    quoteTtlSeconds = 300,
    minAmountMinor = 1,
    maxAmountMinor = 100000000000,
    npcPriceClasses = { STANDARD = 1.0, PREMIUM = 1.2, VIP = 1.5 },
    districtModifiers = {},
    timeModifiers = {},
    demandModifiers = { LOW = 0.95, NORMAL = 1.0, HIGH = 1.2 },
    reputationModifiers = { LOW = 1.1, NORMAL = 1.0, TRUSTED = 0.95 },
    fees = { travelMinor = 0, locationMinor = 0 }
}

NightShift.PricingSettings = NightShift.PricingSettings or NightShift.PricingConfig
