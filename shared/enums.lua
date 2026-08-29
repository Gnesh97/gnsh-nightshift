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
