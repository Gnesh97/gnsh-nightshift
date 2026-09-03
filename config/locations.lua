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
    },
    -- Pickup points are still ordinary server-owned locations. The pickup
    -- resolver selects among these references by district; clients never send
    -- arbitrary coordinates.
    {
        id = 'pickup:vinewood:1',
        type = 'SAFE_ROADSIDE',
        category = 'roadside',
        worldTarget = { kind = 'coords', x = 315.0, y = -1004.0, z = 29.3, heading = 180.0 },
        accessRequirements = { public = true },
        meetingModes = { 'PICKUP' },
        maxTravelDistance = 5000,
        blockedTags = {},
        available = true,
        reservable = true
    },
    {
        id = 'pickup:vinewood:2',
        type = 'SAFE_ROADSIDE',
        category = 'roadside',
        worldTarget = { kind = 'coords', x = 282.0, y = -938.0, z = 29.3, heading = 90.0 },
        accessRequirements = { public = true },
        meetingModes = { 'PICKUP' },
        maxTravelDistance = 5000,
        blockedTags = {},
        available = true,
        reservable = true
    },
    {
        id = 'pickup:los_santos:1',
        type = 'SAFE_ROADSIDE',
        category = 'roadside',
        worldTarget = { kind = 'coords', x = 216.0, y = -810.0, z = 30.7, heading = 0.0 },
        accessRequirements = { public = true },
        meetingModes = { 'PICKUP' },
        maxTravelDistance = 5000,
        blockedTags = {},
        available = true,
        reservable = true
    }
}
NightShift.LocationsConfig = NightShift.LocationConfig

NightShift.PickupLocationConfig = {
    { locationRef = 'pickup:vinewood:1', district = 'vinewood', priority = 1, roadSuitable = true, navSuitable = true },
    { locationRef = 'pickup:vinewood:2', district = 'vinewood', priority = 2, roadSuitable = true, navSuitable = true },
    { locationRef = 'pickup:los_santos:1', district = 'los_santos', priority = 1, roadSuitable = true, navSuitable = true }
}
