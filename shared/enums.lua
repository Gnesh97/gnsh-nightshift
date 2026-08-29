NightShift = NightShift or {}

NightShift.Enums = NightShift.Enums or {}
NightShift.Enums.Readiness = NightShift.Enums.Readiness or {
    STARTING = 'STARTING',
    READY = 'READY',
    FAILED = 'FAILED',
    STOPPED = 'STOPPED'
}

NightShift.Enums.LocationTypes = NightShift.Enums.LocationTypes or {
    MOTEL_ROOM = true,
    HOTEL_ROOM = true,
    PROPERTY = true,
    VENUE_ROOM = true,
    VEHICLE = true,
    CONFIG_LOCATION = true,
    SAFE_ROADSIDE = true,
    CUSTOM_PROVIDER = true
}

NightShift.Enums.MeetingModes = NightShift.Enums.MeetingModes or {
    COME_TO_ME = true,
    PICKUP = true,
    MEET_THERE = true
}

NightShift.Enums.NpcRoles = NightShift.Enums.NpcRoles or {
    CUSTOMER = true,
    WORKER = true
}

NightShift.Enums.NpcProfileTypes = NightShift.Enums.NpcProfileTypes or {
    PERSISTENT = true,
    SEMI_PERSISTENT = true
}

NightShift.Enums.NpcAvailability = NightShift.Enums.NpcAvailability or {
    AVAILABLE = true,
    RESERVED = true,
    OCCUPIED = true,
    AWAY = true,
    OFFLINE = true,
    EXPIRED = true
}

NightShift.Enums.NpcWorkerStates = NightShift.Enums.NpcWorkerStates or {
    AVAILABLE = true,
    RESERVED = true,
    OCCUPIED = true,
    EXPIRED = true
}

NightShift.Enums.NpcTravelModes = NightShift.Enums.NpcTravelModes or {
    WALK = true,
    VEHICLE = true,
    TRANSIT = true,
    UNKNOWN = true
}

NightShift.Enums.NpcTravelStates = NightShift.Enums.NpcTravelStates or {
    PLANNED = true,
    TRAVELLING = true,
    ARRIVAL_PENDING = true,
    ARRIVED = true,
    STUCK = true,
    RECOVERING = true,
    RETURNING = true,
    COMPLETED = true,
    CANCELLED = true,
    EXPIRED = true
}

NightShift.Enums.NpcTravelRecoveryStates = NightShift.Enums.NpcTravelRecoveryStates or {
    NONE = true,
    STUCK = true,
    PLAYER_AWAY = true,
    ENTITY_DELETED = true,
    TIMEOUT = true,
    RETURNING = true
}

NightShift.Enums.NpcEntityStates = NightShift.Enums.NpcEntityStates or {
    AUTHORIZED = true,
    BOUND = true,
    DELETED = true,
    DESPAWNED = true
}

NightShift.Enums.NpcPriceClasses = NightShift.Enums.NpcPriceClasses or {
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true
}
