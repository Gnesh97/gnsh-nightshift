NightShift = NightShift or {}

-- Safe development configuration. Integrations are deliberately deferred;
-- adapters may be supplied by later stages without changing this contract.
NightShift.DefaultConfig = {
    environment = 'development',
    provider = { mode = 'explicit', name = 'standalone' },
    features = { serviceCatalog = true, pricing = true, payments = false, refunds = true, physicalNpc = false, deposits = false, demand = true, heat = false, persistence = false },
    servicePackages = {
        { id = 'standard', price = 100, duration = 30, locationIds = { 'configured_default' } }
    },
    locations = NightShift.LocationConfig,
    npcProfiles = { { id = 'default_profile', availability = 'deferred' } },
    npcProfileConfig = NightShift.NpcProfileConfig,
    npcStreaming = NightShift.NpcStreamingConfig,
    serviceCatalog = NightShift.ServiceCatalogConfig,
    pricing = NightShift.PricingConfig,
    cancellation = NightShift.CancellationConfig,
    demand = NightShift.DemandConfig,
    heat = { min = 0, max = 100 }
}
