NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Location = {}
local copy
Location.__index = function(self, key)
    if key == 'worldTarget' then
        local target = rawget(self, '_worldTarget')
        if type(target) ~= 'table' then return nil end
        return setmetatable({ kind = target.kind }, {
            __index = function(_, field) return target[field] end,
            __newindex = function() end,
            __pairs = function() return pairs(target) end
        })
    end
    return Location[key]
end
Location.__newindex = function(self, key, value)
    if key == 'worldTarget' or key == 'world_target' then
        rawset(self, '_worldTarget', copy(value))
    else
        rawset(self, key, value)
    end
end

local types = NightShift.Enums and NightShift.Enums.LocationTypes or {}
local modes = NightShift.Enums and NightShift.Enums.MeetingModes or {}
local categories = { configured=true, housing=true, motel=true, venue=true, vehicle=true, roadside=true, custom=true }

copy = function(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function token(value, maxLength)
    return text(value, maxLength) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.LOCATION_INVALID, message, details)
end

local function targetError(message, details)
    return Result.err(Codes.LOCATION_TARGET_INVALID, message, details)
end

local function normalizeTarget(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil, targetError('location world target must be a table') end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil, targetError('location world target kind is invalid') end
    local output = { kind = kind }
    if kind == 'coords' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local coordinate = tonumber(value[axis])
            local limit = axis == 'z' and 10000 or 100000
            if not finite(coordinate) or math.abs(coordinate) > limit then return nil, targetError('location world target coordinate is invalid', { axis = axis }) end
            output[axis] = coordinate
        end
        if value.heading ~= nil then
            local heading = tonumber(value.heading)
            if not finite(heading) or math.abs(heading) > 360 then return nil, targetError('location world target heading is invalid') end
            output.heading = heading
        end
    elseif value.provider ~= nil then
        if not token(value.provider, 64) then return nil, targetError('location world target provider is invalid') end
        output.provider = value.provider
    end
    return output
end

local function normalizeList(values, allow, field, uppercase)
    if values == nil then return {} end
    if type(values) ~= 'table' then return nil, invalid(field .. ' must be an array') end
    local output, seen, count = {}, {}, 0
    for index, value in ipairs(values) do
        count = count + 1
        local normalized = type(value) == 'string' and (uppercase and value:upper() or value) or nil
        if not normalized or (uppercase and next(allow) ~= nil and not allow[normalized]) or (not uppercase and not token(normalized, 64)) or seen[normalized] then
            return nil, invalid(field .. ' contains an invalid or duplicated value', { index = index })
        end
        seen[normalized] = true
        output[index] = normalized
    end
    for key in pairs(values) do
        if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then return nil, invalid(field .. ' must be contiguous') end
    end
    if count ~= #values then return nil, invalid(field .. ' must be contiguous') end
    return output
end

local function normalizeAccess(value)
    if value == nil then return {} end
    if type(value) ~= 'table' then return nil, invalid('location access requirements must be a table') end
    local output = {}
    local allowed = { public=true, owner=true, permission=true, ace=true, minGrade=true, min_grade=true }
    for key, item in pairs(value) do
        if not allowed[key] then return nil, invalid('location access requirement is not allowlisted', { field = tostring(key) }) end
        local normalizedKey = key == 'min_grade' and 'minGrade' or key
        if normalizedKey == 'public' or normalizedKey == 'owner' then
            if type(item) ~= 'boolean' then return nil, invalid('location access requirement must be boolean', { field = normalizedKey }) end
        elseif normalizedKey == 'minGrade' then
            item = tonumber(item)
            if not item or item < 0 or item ~= math.floor(item) then return nil, invalid('location minimum grade is invalid') end
        elseif not token(item, 96) then
            return nil, invalid('location access requirement value is invalid', { field = normalizedKey })
        end
        output[normalizedKey] = item
    end
    return output
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('location values must be a table') end
    local source = copy(values)
    local allowed = {
        id=true, locationRef=true, ref=true, key=true, locationType=true, type=true,
        category=true, provider=true, worldTarget=true, world_target=true, _worldTarget=true,
        accessRequirements=true, access_requirements=true, meetingModes=true,
        allowedMeetingModes=true, allowed_meeting_modes=true, maxTravelDistance=true,
        max_travel_distance=true, blockedTags=true, blocked_tags=true, available=true,
        reservable=true, version=true, recordId=true, record_id=true, idNumber=true,
        createdAt=true, created_at=true, updatedAt=true, updated_at=true
    }
    for key in pairs(source) do
        if not allowed[key] then return nil, invalid('location field is not allowlisted', { field = tostring(key) }) end
    end
    local locationRef = source.locationRef or source.id or source.ref or source.key
    if not token(locationRef, 160) then return nil, invalid('location reference is required') end
    local locationType = source.locationType or source.type or 'CONFIG_LOCATION'
    locationType = tostring(locationType):upper()
    if not types[locationType] then return nil, invalid('location type is not supported', { locationType = locationType }) end
    local category = source.category
    category = category == nil and ({
        PROPERTY = 'housing', MOTEL_ROOM = 'motel', HOTEL_ROOM = 'motel',
        VENUE_ROOM = 'venue', VEHICLE = 'vehicle', SAFE_ROADSIDE = 'roadside',
        CUSTOM_PROVIDER = 'custom'
    })[locationType] or category
    category = category == nil and 'configured' or tostring(category):lower()
    if not categories[category] then return nil, invalid('location category is invalid') end
    local target, targetResult = normalizeTarget(source.worldTarget or source.world_target)
    if targetResult then return nil, targetResult end
    local locationModes, modeError = normalizeList(source.meetingModes or source.allowedMeetingModes or source.allowed_meeting_modes or {}, modes, 'location meeting modes', true)
    if not locationModes then return nil, modeError end
    local blockedTags, tagError = normalizeList(source.blockedTags or source.blocked_tags or {}, {}, 'location blocked tags', true)
    if not blockedTags then return nil, tagError end
    local access, accessError = normalizeAccess(source.accessRequirements or source.access_requirements)
    if not access then return nil, accessError end
    local maxDistance = source.maxTravelDistance or source.max_travel_distance
    if maxDistance ~= nil then
        maxDistance = tonumber(maxDistance)
        if not finite(maxDistance) or maxDistance <= 0 or maxDistance > 100000 then return nil, invalid('location maximum travel distance is invalid') end
    end
    local version = source.version == nil and 1 or tonumber(source.version)
    if not version or version < 1 or version ~= math.floor(version) then return nil, invalid('location version is invalid') end
    local recordId = source.recordId or source.record_id or source.idNumber
    if recordId ~= nil then
        recordId = tonumber(recordId)
        if not recordId or recordId < 1 or recordId ~= math.floor(recordId) then return nil, invalid('location record ID is invalid') end
    end
    if source.provider ~= nil and not token(source.provider, 64) then return nil, invalid('location provider is invalid') end
    if source.available ~= nil and type(source.available) ~= 'boolean' then return nil, invalid('location availability must be boolean') end
    if source.reservable ~= nil and type(source.reservable) ~= 'boolean' then return nil, invalid('location reservability must be boolean') end
    return {
        id = locationRef,
        locationRef = locationRef,
        ref = locationRef,
        type = locationType,
        locationType = locationType,
        category = category,
        provider = source.provider,
        _worldTarget = copy(target),
        accessRequirements = access,
        meetingModes = locationModes,
        allowedMeetingModes = copy(locationModes),
        maxTravelDistance = maxDistance,
        blockedTags = blockedTags,
        available = source.available == nil and true or source.available == true,
        reservable = source.reservable == nil and true or source.reservable == true,
        recordId = recordId,
        version = version,
        createdAt = source.createdAt or source.created_at,
        updatedAt = source.updatedAt or source.updated_at
    }
end

function Location.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(normalized, Location)
end

function Location.validate(values)
    local location, errorResult = Location.new(values)
    if not location then return errorResult end
    return Result.ok(location)
end

function Location:copy()
    return setmetatable(copy(self), Location)
end

function Location.toRow(value)
    local location = getmetatable(value) == Location and value or Location.new(value)
    if not location then return nil, invalid('location row source is invalid') end
    return {
        location_key = location.locationRef,
        location_type = location.locationType,
        category = location.category,
        provider = location.provider,
        world_target = copy(location._worldTarget or location.worldTarget),
        access_requirements = copy(location.accessRequirements),
        meeting_modes = copy(location.meetingModes),
        max_travel_distance = location.maxTravelDistance,
        blocked_tags = copy(location.blockedTags),
        available = location.available,
        reservable = location.reservable
    }
end

function Location.fromRow(row)
    if type(row) ~= 'table' then return nil, invalid('location database row is invalid') end
    local available = row.available
    if available ~= nil and type(available) ~= 'boolean' then available = tonumber(available) == 1 end
    local reservable = row.reservable
    if reservable ~= nil and type(reservable) ~= 'boolean' then reservable = tonumber(reservable) == 1 end
    local value, errorResult = Location.new({
        id = row.locationRef or row.location_key or row.id,
        type = row.locationType or row.location_type or row.type,
        category = row.category,
        provider = row.provider,
        worldTarget = row.worldTarget or row.world_target or row.coordinates or row.coordinates_json,
        accessRequirements = row.accessRequirements or row.access_requirements,
        meetingModes = row.meetingModes or row.meeting_modes,
        maxTravelDistance = row.maxTravelDistance or row.max_travel_distance,
        blockedTags = row.blockedTags or row.blocked_tags,
        available = available,
        reservable = reservable,
        recordId = row.id,
        version = row.version,
        createdAt = row.createdAt or row.created_at,
        updatedAt = row.updatedAt or row.updated_at
    })
    if not value then return nil, errorResult end
    return value
end

Location.types = types
Location.meetingModes = modes
NightShift.Domain.Location = Location
