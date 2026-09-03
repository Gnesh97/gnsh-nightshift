NightShift = NightShift or {}

-- Safe development configuration. Integrations are deliberately deferred;
-- adapters may be supplied by later stages without changing this contract.
NightShift.DefaultConfig = {
    environment = 'development',
    provider = { mode = 'explicit', name = 'standalone' },
    framework = 'standalone',
    moneyProvider = 'standalone',
    features = { serviceCatalog = true, pricing = true, payments = false, developmentSettlement = true, refunds = true, physicalNpc = false, deposits = false, demand = true, heat = true, vice = false, demandHeatFeedback = true, persistence = false, scheduling = true, safety = true, blacklist = true, incidents = true, disputes = true, agencies = true, venues = true, audit = true, analytics = true, diagnostics = true, idempotency = true, domainEvents = true, recovery = true, security = true },
    servicePackages = {
        { id = 'standard', price = 100, duration = 30, locationIds = { 'configured_default' } }
    },
    locations = NightShift.LocationConfig,
    pickupLocations = NightShift.PickupLocationConfig,
    npcProfiles = { { id = 'default_profile', availability = 'deferred' } },
    npcProfileConfig = NightShift.NpcProfileConfig,
    npcStreaming = NightShift.NpcStreamingConfig,
    analyticsCache = NightShift.AnalyticsCacheConfig,
    serviceCatalog = NightShift.ServiceCatalogConfig,
    pricing = NightShift.PricingConfig,
    negotiation = NightShift.NegotiationConfig,
    appointmentSession = NightShift.AppointmentSessionConfig,
    cancellation = NightShift.CancellationConfig,
    demand = NightShift.DemandConfig,
    heat = NightShift.HeatConfig,
    vice = NightShift.ViceConfig,
    demandHeatFeedback = NightShift.DemandHeatFeedbackConfig,
    reputation = NightShift.ReputationConfig,
    scheduling = NightShift.SchedulingConfig,
    recovery = NightShift.RecoveryConfig,
    security = NightShift.SecurityConfig
}
