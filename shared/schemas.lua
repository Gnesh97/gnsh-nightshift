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
    npcProfile = {
        id = 'positive_integer', profileKey = 'string', role = 'enum',
        profileType = 'enum', alias = 'string', appearanceProfileRef = 'string',
        budgetClass = 'bounded_integer', priceClass = 'bounded_integer',
        rating = 'bounded_number', traits = 'trait_map', tags = 'string_array',
        homeDistrict = 'string', activeDistrict = 'string',
        availability = 'enum', travelMode = 'enum', generationSeed = 'string',
        completedBookings = 'bounded_integer', cancelledBookings = 'bounded_integer',
        noShowBookings = 'bounded_integer', version = 'positive_integer'
    },
    demand = { min = 'bounded_number', max = 'bounded_number', window = 'positive_number' },
    heat = { min = 'bounded_number', max = 'bounded_number', decay = 'bounded_number' }
}
