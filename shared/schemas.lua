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
    district = {
        id = 'string', baselineDemand = 'bounded_number', priceModifier = 'bounded_number',
        riskModifier = 'bounded_number', heatModifier = 'bounded_number',
        allowedZones = 'string_array', timeCurve = 'number_map', dayCurve = 'number_map',
        maxActiveCustomers = 'bounded_integer', available = 'boolean'
    },
    demand = {
        min = 'bounded_number', max = 'bounded_number', window = 'positive_number',
        generationIntervalSeconds = 'positive_integer', candidateCooldownSeconds = 'bounded_integer',
        opportunityTtlSeconds = 'positive_integer', maxConcurrentOpportunities = 'positive_integer',
        maxActiveLogicalCustomers = 'positive_integer', districts = 'district_map'
    },
    workerAvailability = { state = 'enum', available = 'boolean', bookingId = 'string' },
    customerOpportunity = {
        opportunityKey = 'string', district = 'string', zone = 'string', state = 'enum',
        demandScore = 'bounded_number', demandBand = 'enum', createdAt = 'number', expiresAt = 'number'
    },
    heat = {
        enabled = 'boolean', playerEnabled = 'boolean',
        min = 'bounded_number', max = 'bounded_number',
        playerIncrement = 'bounded_number', districtIncrement = 'bounded_number',
        decayIntervalSeconds = 'positive_integer', playerDecay = 'bounded_number',
        districtDecay = 'bounded_number', maxEventKeys = 'positive_integer',
        eventIncrements = 'number_map', decay = 'bounded_number'
    },
    vice = {
        enabled = 'boolean', riskThreshold = 'bounded_number',
        dispatchThreshold = 'bounded_number', districtPressureWeight = 'bounded_number',
        archetypeWeight = 'bounded_number', bookingWeight = 'bounded_number'
    },
    demandHeatFeedback = {
        enabled = 'boolean', streetPressureThreshold = 'bounded_number',
        streetOpportunityPenalty = 'bounded_number',
        privateAvailabilityModifier = 'bounded_number',
        pricingDemandWeight = 'bounded_number', pricingHeatWeight = 'bounded_number',
        pricingOversupplyPenalty = 'bounded_number',
        minMultiplier = 'bounded_number', maxMultiplier = 'bounded_number'
    }
}
