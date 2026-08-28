NightShift = NightShift or {}

-- Safe development configuration. Integrations are deliberately deferred;
-- adapters may be supplied by later stages without changing this contract.
NightShift.DefaultConfig = {
    environment = 'development',
    provider = { mode = 'explicit', name = 'standalone' },
    features = { physicalNpc = false, deposits = false, demand = false, heat = false },
    servicePackages = {
        { id = 'standard', price = 100, duration = 30, locationIds = { 'configured_default' } }
    },
    locations = { { id = 'configured_default', category = 'configured' } },
    npcProfiles = { { id = 'default_profile', availability = 'deferred' } },
    demand = { min = 0, max = 100 },
    heat = { min = 0, max = 100 }
}
