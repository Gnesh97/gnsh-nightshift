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
    travelPlan = {
        travelKey = 'string', bookingId = 'string', workerKey = 'string',
        profileKey = 'string', origin = 'travel_endpoint',
        destination = 'travel_endpoint', mode = 'enum',
        etaSeconds = 'positive_number', startedAt = 'number',
        expectedArrivalAt = 'number', progress = 'bounded_number',
        spawnThreshold = 'bounded_number', state = 'enum',
        recoveryState = 'enum', generation = 'positive_integer'
    },
    npcEntity = {
        profileKey = 'string', travelKey = 'string', bookingId = 'string',
        generation = 'positive_integer', generationToken = 'string',
        entity = 'entity_handle', networkId = 'entity_handle',
        owner = 'player_source', state = 'enum'
    },
    demand = { min = 'bounded_number', max = 'bounded_number', window = 'positive_number' },
    heat = { min = 'bounded_number', max = 'bounded_number', decay = 'bounded_number' }
}
