NightShift = NightShift or {}

-- District demand is logical and configuration-driven. Street zones are
-- discovery labels only; they never carry client-owned coordinates.
NightShift.DemandConfig = NightShift.DemandConfig or {
    enabled = true,
    min = 0,
    max = 100,
    window = 60,
    defaultDistrict = 'vinewood',
    generationIntervalSeconds = 60,
    candidateCooldownSeconds = 120,
    opportunityTtlSeconds = 600,
    maxConcurrentOpportunities = 3,
    maxActiveLogicalCustomers = 50,
    minimumDemandScore = 1,
    oversupplyPenalty = 0.5,
    recentActivityImpact = 0.15,
    policePressureImpact = 0.2,
    heatImpact = 0.2,
    districts = {
        vinewood = {
            baseline = 65,
            priceModifier = 1.1,
            riskModifier = 0.2,
            heatModifier = 0.15,
            allowedZones = { 'vinewood_hills', 'east_vinewood' },
            timeCurve = { [18] = 1.15, [19] = 1.2, [20] = 1.2, [21] = 1.1 },
            dayCurve = { FRIDAY = 1.2, SATURDAY = 1.15 },
            maxActiveCustomers = 8
        },
        vespucci = {
            baseline = 50,
            priceModifier = 1.0,
            riskModifier = 0.15,
            heatModifier = 0.1,
            allowedZones = { 'vespucci_beach', 'vespucci_canals' },
            timeCurve = { [20] = 1.1, [21] = 1.15 },
            dayCurve = { FRIDAY = 1.1, SATURDAY = 1.1 },
            maxActiveCustomers = 6
        },
        rockford = {
            baseline = 55,
            priceModifier = 1.2,
            riskModifier = 0.1,
            heatModifier = 0.05,
            allowedZones = { 'rockford_hills', 'rockford_center' },
            timeCurve = { [18] = 1.1, [19] = 1.15 },
            dayCurve = { THURSDAY = 1.05, FRIDAY = 1.15 },
            maxActiveCustomers = 5
        }
    }
}

NightShift.Demand = NightShift.Demand or NightShift.DemandConfig
