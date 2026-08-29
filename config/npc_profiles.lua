NightShift = NightShift or {}

-- Logical NPC descriptors only. They are deliberately independent from ped
-- models/entities; physical spawning is a later lifecycle concern.
NightShift.NpcProfileConfig = NightShift.NpcProfileConfig or {
    enabled = true,
    seed = 'nightshift-default',
    promotion = { completedBookings = 3 },
    workerPool = { targetSize = 5, maxSize = 50, reservationTtl = 300 },
    templates = {
        {
            id = 'worker_standard',
            role = 'WORKER',
            profileType = 'SEMI_PERSISTENT',
            weight = 4,
            aliases = { 'Maya', 'Lena', 'Nina', 'Aria' },
            appearanceProfileRefs = { 'appearance:default' },
            priceClass = { min = 1, max = 3 },
            rating = { min = 4.0, max = 4.8 },
            traits = {
                reliability = { min = 65, max = 90 },
                discretion = { min = 65, max = 95 },
                patience = { min = 45, max = 85 },
                negotiation = { min = 40, max = 80 }
            },
            districts = { 'vinewood', 'vespucci', 'rockford' },
            travelModes = { 'VEHICLE', 'WALK' },
            tags = { 'QUIET' }
        },
        {
            id = 'worker_premium',
            role = 'WORKER',
            profileType = 'PERSISTENT',
            weight = 1,
            aliases = { 'Sofia', 'Eva' },
            appearanceProfileRefs = { 'appearance:premium' },
            priceClass = { min = 3, max = 5 },
            rating = { min = 4.5, max = 5.0 },
            traits = {
                reliability = { min = 80, max = 100 },
                discretion = { min = 80, max = 100 },
                patience = { min = 60, max = 95 },
                negotiation = { min = 60, max = 95 }
            },
            districts = { 'rockford', 'vinewood' },
            travelModes = { 'VEHICLE' },
            tags = { 'PREMIUM' }
        },
        {
            id = 'customer_standard',
            role = 'CUSTOMER',
            profileType = 'SEMI_PERSISTENT',
            weight = 1,
            aliases = { 'Client' },
            budgetClass = { min = 1, max = 3 },
            districts = { 'vinewood', 'vespucci' },
            travelModes = { 'WALK', 'VEHICLE' }
        }
    }
}

NightShift.NPCProfileConfig = NightShift.NpcProfileConfig
