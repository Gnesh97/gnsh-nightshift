NightShift = NightShift or {}

NightShift.Schemas = {
    servicePackage = {
        id = 'string', price = 'positive_integer', duration = 'positive_number',
        locationIds = 'string_array'
    },
    location = { id = 'string', category = 'string' },
    npcProfile = { id = 'string' },
    demand = { min = 'bounded_number', max = 'bounded_number', window = 'positive_number' },
    heat = { min = 'bounded_number', max = 'bounded_number', decay = 'bounded_number' }
}
