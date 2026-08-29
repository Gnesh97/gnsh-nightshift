local function check(value, message) assert(value, message) end

local Result = NightShift.Result
local Location = NightShift.Domain and NightShift.Domain.Location
local LocationRepository = NightShift.Repositories and NightShift.Repositories.Location
local LocationReservation = NightShift.Domain and NightShift.Domain.LocationReservation
local LocationReservationRepository = NightShift.Repositories and NightShift.Repositories.LocationReservation
local LocationService = NightShift.LocationService
local LocationReservationService = NightShift.LocationReservationService
local VehicleLocationService = NightShift.VehicleLocationService

check(type(Location) == 'table', 'S07 location domain must be loaded')
check(type(LocationRepository) == 'table', 'S07 location repository must be loaded')
check(type(LocationReservation) == 'table', 'S07 location reservation domain must be loaded')
check(type(LocationReservationRepository) == 'table', 'S07 location reservation repository must be loaded')
check(type(LocationService) == 'table', 'S07 location resolver must be loaded')
check(type(LocationReservationService) == 'table', 'S07 location reservation service must be loaded')
check(type(VehicleLocationService) == 'table', 'S07 vehicle location resolver must be loaded')

local function clockFixture()
    local current = 100
    return {
        clock = { now = function() return current end, timestamp = function() return '1970-01-01T00:01:40Z' end },
        set = function(value) current = value end
    }
end

do
    local location = Location.new({
        id = 'config-room',
        type = 'config_location',
        category = 'configured',
        worldTarget = { kind = 'coords', x = 100, y = 200, z = 30, heading = 90 },
        accessRequirements = { public = true },
        allowedMeetingModes = { 'COME_TO_ME', 'MEET_THERE' },
        maxTravelDistance = 500,
        blockedTags = { 'restricted' },
        reservable = true
    })
    check(location and location.locationRef == 'config-room' and location.locationType == 'CONFIG_LOCATION', 'typed location must normalize ref and type')
    check(location.worldTarget.x == 100 and location.meetingModes[1] == 'COME_TO_ME' and location.blockedTags[1] == 'RESTRICTED', 'typed location descriptors must normalize immutably')
    local changed = location.worldTarget
    changed.x = 999
    check(location.worldTarget.x == 100, 'location constructor must copy world targets')

    local invalidType, invalidTypeError = Location.new({ id = 'bad', type = 'ARBITRARY', category = 'configured' })
    check(not invalidType and invalidTypeError.error.code == NightShift.Errors.Codes.LOCATION_INVALID, 'unknown location type must fail closed')
    local invalidTarget, invalidTargetError = Location.new({ id = 'bad-target', type = 'CONFIG_LOCATION', category = 'configured', worldTarget = { kind = 'coords', x = math.huge, y = 0, z = 0 } })
    check(not invalidTarget and invalidTargetError.error.code == NightShift.Errors.Codes.LOCATION_TARGET_INVALID, 'non-finite target must fail closed')
    local invalidRef, invalidRefError = Location.new({ id = '', type = 'CONFIG_LOCATION', category = 'configured' })
    check(not invalidRef and invalidRefError.error.code == NightShift.Errors.Codes.LOCATION_INVALID, 'empty location reference must fail closed')
end

local fixture = clockFixture()
local locations = {
    {
        id = 'config-room', type = 'CONFIG_LOCATION', category = 'configured',
        worldTarget = { kind = 'coords', x = 100, y = 200, z = 30 },
        meetingModes = { 'COME_TO_ME', 'MEET_THERE' }, maxTravelDistance = 500,
        blockedTags = { 'RESTRICTED' }, reservable = true
    },
    {
        id = 'owner-property', type = 'PROPERTY', category = 'housing', provider = 'housing',
        worldTarget = { kind = 'coords', x = 110, y = 210, z = 30 },
        accessRequirements = { public = false, owner = true }, meetingModes = { 'MEET_THERE' }, reservable = true
    },
    {
        id = 'water-target', type = 'CONFIG_LOCATION', category = 'configured',
        worldTarget = { kind = 'coords', x = 999, y = 999, z = 0 }, meetingModes = { 'COME_TO_ME' }
    }
}

local locationService = assert(LocationService.new({
    locations = locations,
    clock = fixture.clock,
    accessCheck = function(source) return tonumber(source) == 7 end,
    waterCheck = function(target) return target.x == 999 end,
    routeCheck = function(_, target)
        return Result.ok({ reachable = true, distance = target.x == 100 and 50 or 10 })
    end
}))

do
    local resolved = locationService:resolve(7, {
        locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME',
        worldTarget = { kind = 'coords', x = 50000, y = 50000, z = 5000 }
    })
    check(resolved.ok and resolved.value.locationType == 'CONFIG_LOCATION' and resolved.value.locationRef == 'config-room', 'registered location must resolve by typed reference')
    check(resolved.value.worldTarget.x == 100 and resolved.value.route.distance == 50, 'resolver must use server target and route hint, not client coordinates')

    local unknown = locationService:resolve(7, { locationType = 'CONFIG_LOCATION', locationRef = 'not-registered', meetingMode = 'COME_TO_ME' })
    check(not unknown.ok and unknown.error.code == NightShift.Errors.Codes.LOCATION_NOT_FOUND, 'unregistered location must fail closed')
    local incompatible = locationService:resolve(7, { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'PICKUP' })
    check(not incompatible.ok and incompatible.error.code == NightShift.Errors.Codes.LOCATION_INCOMPATIBLE, 'meeting mode mismatch must fail closed')
    local blocked = locationService:resolve(7, { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME', zoneTags = { 'restricted' } })
    check(not blocked.ok and blocked.error.code == NightShift.Errors.Codes.LOCATION_BLOCKED, 'blocked zone tags must fail closed')
    local water = locationService:resolve(7, { locationType = 'CONFIG_LOCATION', locationRef = 'water-target', meetingMode = 'COME_TO_ME' })
    check(not water.ok and water.error.code == NightShift.Errors.Codes.LOCATION_TARGET_INVALID, 'water target must fail closed')
    local denied = locationService:resolve(1, { locationType = 'PROPERTY', locationRef = 'owner-property', meetingMode = 'MEET_THERE' })
    check(not denied.ok and denied.error.code == NightShift.Errors.Codes.LOCATION_ACCESS_DENIED, 'protected location access must be server-authorized')
    check(locationService:resolve(7, { locationType = 'PROPERTY', locationRef = 'owner-property', meetingMode = 'MEET_THERE' }).ok, 'authorized property access must resolve')
end

do
    local providerCalls = {}
    local motel = {
        validate = function(_, source, ref)
            providerCalls.validate = { source = source, ref = ref }
            return Result.ok({ valid = true, category = 'motel' })
        end,
        resolveWorldTarget = function(_, ref)
            providerCalls.target = ref
            return Result.ok({ worldTarget = { kind = 'coords', x = 300, y = 400, z = 30 } })
        end
    }
    local providerService = assert(LocationService.new({ locations = {}, providers = { motel = motel }, clock = fixture.clock }))
    local resolved = providerService:resolve(12, { locationType = 'MOTEL_ROOM', locationRef = 'pinkcage:7', meetingMode = 'COME_TO_ME' })
    check(resolved.ok and resolved.value.locationType == 'MOTEL_ROOM' and resolved.value.worldTarget.x == 300, 'provider locations must resolve through the registered provider')
    check(providerCalls.validate and providerCalls.validate.source == 12 and providerCalls.target == 'pinkcage:7', 'provider route must receive server source and typed ref')
end

local locks = assert(NightShift.Reservations.new({ clock = fixture.clock, defaultTtl = 60 }))
local reservationService = assert(LocationReservationService.new({ locationService = locationService, locks = locks, clock = fixture.clock, defaultTtl = 60 }))

do
    local first = reservationService:reserve('booking-1', { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME' })
    check(first.ok and first.value.status == 'RESERVED' and first.value.locationRef == 'config-room', 'location reservation must create a held typed reservation')
    local retry = reservationService:reserve('booking-1', { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME' })
    check(retry.ok and retry.value.idempotent == true, 'location reservation retry must be idempotent')
    local conflict = reservationService:reserve('booking-2', { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME' })
    check(not conflict.ok and conflict.error.code == NightShift.Errors.Codes.RESERVATION_CONFLICT, 'same location must not be reserved by two bookings')
    local occupied = reservationService:occupy('booking-1', first.value.reservationKey)
    check(occupied.ok and occupied.value.status == 'OCCUPIED', 'reservation owner must be able to occupy a location')
    local released = reservationService:release('booking-1', first.value.reservationKey)
    check(released.ok and released.value.status == 'RELEASED', 'reservation owner must be able to release a location')
    local releasedAgain = reservationService:release('booking-1', first.value.reservationKey)
    check(releasedAgain.ok and releasedAgain.value.idempotent == true, 'location release must be idempotent')

    local expiring = reservationService:reserve('booking-expiring', { locationType = 'CONFIG_LOCATION', locationRef = 'config-room', meetingMode = 'COME_TO_ME', ttlSeconds = 10 })
    check(expiring.ok, 'location must be reusable after release')
    fixture.set(111)
    local expired = reservationService:expire()
    check(expired.ok and expired.value.expired >= 1, 'expired location holds must be marked expired')
    fixture.set(100)
end

do
    local failingProvider = {
        reserve = function() return false end,
        release = function() return true end
    }
    local motelLocationService = assert(LocationService.new({
        locations = { { id = 'motel-room', type = 'MOTEL_ROOM', category = 'motel', provider = 'motel', meetingModes = { 'COME_TO_ME' }, worldTarget = { kind = 'coords', x = 250, y = 250, z = 30 } } },
        providers = { motel = { validate = function() return Result.ok({ valid = true }) end, resolveWorldTarget = function() return Result.ok({ worldTarget = { kind = 'coords', x = 250, y = 250, z = 30 } }) end, reserve = failingProvider.reserve, release = failingProvider.release } },
        clock = fixture.clock
    }))
    local failingService = assert(LocationReservationService.new({ locationService = motelLocationService, locks = assert(NightShift.Reservations.new({ clock = fixture.clock })), clock = fixture.clock }))
    local failed = failingService:reserve('booking-provider-fail', { locationType = 'MOTEL_ROOM', locationRef = 'motel-room', meetingMode = 'COME_TO_ME' })
    check(not failed.ok and failed.error.code == NightShift.Errors.Codes.RESERVATION_PROVIDER_FAILED, 'provider reservation failure must roll back the local hold')
    check(not failingService:isReserved('motel-room').value.reserved, 'provider failure must not leave a local location lock')
end

do
    local vehicle = { id = 42, serverVisible = true, ownerSource = 7, private = true, speed = 0.1, zone = 'allowed', coords = { x = 50, y = 60, z = 30, heading = 180 } }
    local vehicleService = assert(VehicleLocationService.new({
        getVehicle = function(id) return tonumber(id) == 42 and vehicle or nil end,
        hasAccess = function(source, value) return tonumber(source) == value.ownerSource end,
        isAllowedZone = function(_, value) return value.zone == 'allowed' end,
        clock = fixture.clock
    }))
    local resolved = vehicleService:resolve(7, { vehicleId = 42, worldTarget = { kind = 'coords', x = 99999, y = 99999, z = 9999 } })
    check(resolved.ok and resolved.value.locationType == 'VEHICLE' and resolved.value.locationRef == 'vehicle:42', 'vehicle resolver must return a typed server-bound location')
    check(resolved.value.worldTarget.x == 50, 'vehicle resolver must ignore client-supplied coordinates')
    local delegatedService = assert(LocationService.new({ locations = {}, vehicleService = vehicleService }))
    local delegated = delegatedService:resolve(7, { locationType = 'VEHICLE', vehicleId = 42 })
    check(delegated.ok and delegated.value.locationRef == 'vehicle:42', 'location resolver must delegate vehicle references before requiring a locationRef')
    local denied = vehicleService:resolve(1, { vehicleId = 42 })
    check(not denied.ok and denied.error.code == NightShift.Errors.Codes.VEHICLE_ACCESS_DENIED, 'vehicle access must be server-authorized')
    vehicle.speed = 10
    local moving = vehicleService:resolve(7, { vehicleId = 42 })
    check(not moving.ok and moving.error.code == NightShift.Errors.Codes.LOCATION_INCOMPATIBLE, 'moving vehicle must be rejected')
    vehicle.speed = 0.1
    vehicle.zone = 'restricted'
    local restricted = vehicleService:resolve(7, { vehicleId = 42 })
    check(not restricted.ok and restricted.error.code == NightShift.Errors.Codes.LOCATION_BLOCKED, 'vehicle outside an allowed zone must be rejected')
end

do
    local encoded = {}
    local fakeDb = {
        insert = function(_, sql, parameters) encoded.sql, encoded.parameters = sql, parameters; return Result.ok({ insertId = 19 }) end,
        single = function() return Result.ok(nil) end,
        query = function() return Result.ok({}) end,
        update = function() return Result.ok({ affectedRows = 1 }) end
    }
    local locationRepository = assert(LocationRepository.new({ db = fakeDb, encode = function(value) return 'encoded:' .. (value.kind or 'list') end, decode = function() return {} end }))
    local location = assert(Location.new({ id = 'repo-location', type = 'CONFIG_LOCATION', category = 'configured', worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 } }))
    local created = locationRepository:create(location)
    check(created.ok and encoded.sql:find('location_key', 1, true) and encoded.parameters, 'location repository must persist typed location fields parametrically')

    local reservationRepository = assert(LocationReservationRepository.new({ db = fakeDb }))
    local reservation = assert(LocationReservation.new({ reservationKey = 'location:repo:1', locationRef = 'repo-location', bookingId = 'booking-repo', status = 'RESERVED', holdUntil = 160 }))
    local reservationCreated = reservationRepository:create(reservation)
    check(reservationCreated.ok, 'location reservation repository must persist reservation rows')
end

print('NS-070..NS-073 tests passed: typed locations, server resolver, atomic reservations, and vehicle validation')
