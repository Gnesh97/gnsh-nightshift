NightShift = NightShift or {}

-- Bounded market feedback. The service clamps every runtime input and output;
-- this config only controls the strength of the response.
NightShift.DemandHeatFeedbackConfig = NightShift.DemandHeatFeedbackConfig or {
    enabled = true,
    streetPressureThreshold = 70,
    streetOpportunityPenalty = 0.6,
    privateAvailabilityModifier = 0.35,
    pricingDemandWeight = 0.2,
    pricingHeatWeight = 0.15,
    pricingOversupplyPenalty = 0.3,
    minMultiplier = 0.25,
    maxMultiplier = 1.75
}
