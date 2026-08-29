NightShift = NightShift or {}

-- Abstract package definitions only. They contain no graphic or provider-specific
-- content; all prices are positive integer minor units and all authority stays
-- server-side.
NightShift.ServiceCatalogConfig = NightShift.ServiceCatalogConfig or {
    enabled = true,
    currency = 'USD',
    packages = {
        { id = 'short', basePriceMinor = 300, durationMinutes = 30, minClientReputation = 0, meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }, locationIds = { 'configured_default' } },
        { id = 'standard', basePriceMinor = 500, durationMinutes = 30, minClientReputation = 0, meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }, locationIds = { 'configured_default' } },
        { id = 'premium', basePriceMinor = 750, durationMinutes = 60, minClientReputation = 25, meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }, locationIds = { 'configured_default' } },
        { id = 'private', basePriceMinor = 1000, durationMinutes = 60, minClientReputation = 50, meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }, locationIds = { 'configured_default' } },
        { id = 'vip', basePriceMinor = 1500, durationMinutes = 90, minClientReputation = 75, meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' }, locationIds = { 'configured_default' } }
    }
}

NightShift.ServicesConfig = NightShift.ServicesConfig or NightShift.ServiceCatalogConfig
