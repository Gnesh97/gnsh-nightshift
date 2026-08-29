NightShift = NightShift or {}

-- Location definitions are server-owned descriptors. Client coordinates are never
-- used to select a location; the resolver returns this registered target instead.
NightShift.LocationConfig = {
    {
        id = 'configured_default',
        type = 'CONFIG_LOCATION',
        category = 'configured',
        worldTarget = { kind = 'coords', x = 250.0, y = -1000.0, z = 29.0, heading = 0.0 },
        accessRequirements = { public = true },
        meetingModes = { 'COME_TO_ME', 'PICKUP', 'MEET_THERE' },
        maxTravelDistance = 5000,
        blockedTags = {},
        available = true,
        reservable = true
    }
}
NightShift.LocationsConfig = NightShift.LocationConfig
