NightShift = NightShift or {}

NightShift.Schemas = {
    servicePackage = {
        id = 'string', price = 'positive_integer', duration = 'positive_number',
        locationIds = 'string_array'
    },
    location = {
        id = 'string', locationRef = 'string', locationType = 'enum',
        category = 'string', worldTarget = 'world_target',
        accessRequirements = 'access_requirements', meetingModes = 'string_array',
        maxTravelDistance = 'bounded_number', blockedTags = 'string_array',
        available = 'boolean', reservable = 'boolean'
    },
    npcProfile = { id = 'string' },
    demand = { min = 'bounded_number', max = 'bounded_number', window = 'positive_number' },
    heat = { min = 'bounded_number', max = 'bounded_number', decay = 'bounded_number' }
}
