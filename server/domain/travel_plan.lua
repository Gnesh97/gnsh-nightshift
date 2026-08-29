NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Enums = NightShift.Enums

local Plan = {}
Plan.__index = Plan

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    local metatable = getmetatable(value)
    if metatable ~= nil then setmetatable(output, metatable) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function bounded(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value < minimum or value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.TRAVEL_INVALID, message, details)
end

local function normalizeTarget(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil end
    local output = { kind = kind }
    if kind == 'coords' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local coordinate = bounded(value[axis], -100000, 100000)
            if axis == 'z' then coordinate = bounded(value[axis], -10000, 10000) end
            if not coordinate then return nil end
            output[axis] = coordinate
        end
        if value.heading ~= nil then
            local heading = bounded(value.heading, -360, 360)
            if not heading then return nil end
            output.heading = heading
        end
    else
        if not token(value.provider, 64) then return nil end
        output.provider = value.provider
    end
    return output
end

local function normalizeEndpoint(value, field, destination)
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a typed endpoint') end
    local allowed = { district = true, locationType = true, type = true, locationRef = true, ref = true }
    for key in pairs(value) do
        if not allowed[key] then return nil, invalid(field .. ' contains an untrusted field', { field = tostring(key) }) end
    end
    local district = value.district
    if district ~= nil and not token(district, 64) then return nil, invalid(field .. ' district is invalid') end
    local locationType = value.locationType or value.type
    local locationRef = value.locationRef or value.ref
    if destination and (type(locationType) ~= 'string' or not Enums.LocationTypes[tostring(locationType):upper()]) then
        return nil, invalid(field .. ' location type is invalid')
    end
    if destination and not token(locationRef, 160) then return nil, invalid(field .. ' location reference is required') end
    if not destination and locationType ~= nil and (type(locationType) ~= 'string' or not Enums.LocationTypes[tostring(locationType):upper()]) then
        return nil, invalid(field .. ' location type is invalid')
    end
    if not destination and locationRef ~= nil and not token(locationRef, 160) then return nil, invalid(field .. ' location reference is invalid') end
    if not district and not locationRef then return nil, invalid(field .. ' requires a district or location reference') end
    local output = {}
    if district then output.district = tostring(district):lower() end
    if locationType then output.locationType = tostring(locationType):upper() end
    if locationRef then output.locationRef = locationRef end
    return output
end

local function normalizeResolved(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil end
    local output = {}
    if value.locationType ~= nil then
        local locationType = tostring(value.locationType):upper()
        if not Enums.LocationTypes[locationType] then return nil end
        output.locationType = locationType
    end
    if value.locationRef ~= nil then
        if not token(value.locationRef, 160) then return nil end
        output.locationRef = value.locationRef
    end
    if value.worldTarget ~= nil then
        output.worldTarget = normalizeTarget(value.worldTarget)
        if not output.worldTarget then return nil end
    end
    if value.route ~= nil then
        if type(value.route) ~= 'table' then return nil end
        output.route = copy(value.route)
    end
    if value.meetingMode ~= nil then
        local meetingMode = tostring(value.meetingMode):upper()
        if not Enums.MeetingModes[meetingMode] then return nil end
        output.meetingMode = meetingMode
    end
    if value.resolvedAt ~= nil then
        if not finite(tonumber(value.resolvedAt)) then return nil end
        output.resolvedAt = tonumber(value.resolvedAt)
    end
    return output
end

local function stateOrDefault(value)
    local state = value == nil and 'TRAVELLING' or (type(value) == 'string' and value:upper() or nil)
    return state and Enums.NpcTravelStates[state] and state or nil
end

local function recoveryOrDefault(value)
    local state = value == nil and 'NONE' or (type(value) == 'string' and value:upper() or nil)
    return state and Enums.NpcTravelRecoveryStates[state] and state or nil
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('travel plan values must be a table') end
    local allowed = {
        travelKey = true, bookingId = true, workerKey = true, profileKey = true,
        origin = true, destination = true, resolvedDestination = true,
        mode = true, etaSeconds = true, startedAt = true, expectedArrivalAt = true,
        progress = true, spawnThreshold = true, state = true, recoveryState = true,
        generation = true, recoveryAt = true, arrivedAt = true, createdAt = true,
        updatedAt = true
    }
    for key in pairs(values) do
        if not allowed[key] then return nil, invalid('travel plan field is not allowlisted', { field = tostring(key) }) end
    end
    if not token(values.travelKey, 200) then return nil, invalid('travel key is required') end
    if not token(values.bookingId, 160) then return nil, invalid('travel booking ID is required') end
    if not token(values.workerKey, 160) then return nil, invalid('travel worker key is required') end
    if not token(values.profileKey, 160) then return nil, invalid('travel profile key is required') end
    local origin, originError = normalizeEndpoint(values.origin, 'origin', false)
    if not origin then return nil, originError end
    local destination, destinationError = normalizeEndpoint(values.destination, 'destination', true)
    if not destination then return nil, destinationError end
    local mode = type(values.mode) == 'string' and values.mode:upper() or 'WALK'
    if not Enums.NpcTravelModes[mode] or mode == 'UNKNOWN' then return nil, invalid('travel mode is invalid') end
    local etaSeconds = bounded(values.etaSeconds, 1, 86400)
    if not etaSeconds then return nil, invalid('travel ETA is invalid') end
    local startedAt = values.startedAt == nil and os.time() or bounded(values.startedAt, 0, 4102444800)
    if not startedAt then return nil, invalid('travel start time is invalid') end
    local expectedArrivalAt = values.expectedArrivalAt == nil and startedAt + etaSeconds or bounded(values.expectedArrivalAt, startedAt, 4102444800)
    if not expectedArrivalAt then return nil, invalid('travel expected arrival is invalid') end
    if expectedArrivalAt < startedAt then return nil, invalid('travel expected arrival must not precede start') end
    local progress = values.progress == nil and 0 or bounded(values.progress, 0, 1)
    if progress == nil then return nil, invalid('travel progress is invalid') end
    local spawnThreshold = values.spawnThreshold == nil and 0.65 or bounded(values.spawnThreshold, 0, 1)
    if spawnThreshold == nil then return nil, invalid('travel spawn threshold is invalid') end
    local state = stateOrDefault(values.state)
    if not state then return nil, invalid('travel state is invalid') end
    local recoveryState = recoveryOrDefault(values.recoveryState)
    if not recoveryState then return nil, invalid('travel recovery state is invalid') end
    local generation = values.generation == nil and 1 or tonumber(values.generation)
    if not generation or generation < 1 or generation ~= math.floor(generation) then return nil, invalid('travel generation is invalid') end
    local resolvedDestination = normalizeResolved(values.resolvedDestination)
    if values.resolvedDestination ~= nil and not resolvedDestination then return nil, invalid('resolved destination is invalid') end
    local output = {
        travelKey = values.travelKey, bookingId = values.bookingId, workerKey = values.workerKey,
        profileKey = values.profileKey, origin = origin, destination = destination,
        resolvedDestination = resolvedDestination, mode = mode, etaSeconds = etaSeconds,
        startedAt = startedAt, expectedArrivalAt = expectedArrivalAt, progress = progress,
        spawnThreshold = spawnThreshold, state = state, recoveryState = recoveryState,
        generation = generation, recoveryAt = values.recoveryAt, arrivedAt = values.arrivedAt,
        createdAt = values.createdAt, updatedAt = values.updatedAt
    }
    if output.state == 'ARRIVED' and output.progress < 1 then output.progress = 1 end
    return output
end

function Plan.new(values)
    local normalized, err = normalize(values)
    if not normalized then return nil, err end
    return setmetatable(copy(normalized), Plan)
end

function Plan.copy(value)
    return copy(value)
end

function Plan:isSpawnReady()
    return self.progress >= self.spawnThreshold and
        (self.state == 'PLANNED' or self.state == 'TRAVELLING' or self.state == 'ARRIVAL_PENDING' or self.state == 'ARRIVED')
end

Plan.shouldSpawn = Plan.isSpawnReady

function Plan:advance(progress, at)
    progress = bounded(progress, 0, 1)
    if not progress or progress < self.progress then return invalid('travel progress must be monotonic') end
    if self.state == 'CANCELLED' or self.state == 'COMPLETED' or self.state == 'EXPIRED' then
        return Result.err(Codes.TRAVEL_CONFLICT, 'terminal travel plan cannot advance')
    end
    local nextPlan = copy(self)
    nextPlan.progress = progress
    if progress >= 1 then
        nextPlan.state = 'ARRIVAL_PENDING'
    elseif nextPlan.state == 'PLANNED' then
        nextPlan.state = 'TRAVELLING'
    end
    nextPlan.updatedAt = at or nextPlan.updatedAt
    return Result.ok(setmetatable(nextPlan, Plan))
end

function Plan:markRecovery(recoveryState, at)
    recoveryState = type(recoveryState) == 'string' and recoveryState:upper() or nil
    if not recoveryState or not Enums.NpcTravelRecoveryStates[recoveryState] then return invalid('travel recovery state is invalid') end
    if self.state == 'COMPLETED' or self.state == 'CANCELLED' or self.state == 'EXPIRED' then
        return Result.err(Codes.TRAVEL_CONFLICT, 'terminal travel plan cannot recover')
    end
    local nextPlan = copy(self)
    nextPlan.recoveryState = recoveryState
    nextPlan.recoveryAt = at or nextPlan.recoveryAt
    if recoveryState == 'NONE' then
        nextPlan.state = nextPlan.progress >= 1 and 'ARRIVAL_PENDING' or 'TRAVELLING'
    elseif recoveryState == 'RETURNING' then
        nextPlan.state = 'RETURNING'
    else
        nextPlan.state = 'RECOVERING'
    end
    nextPlan.updatedAt = at or nextPlan.updatedAt
    return Result.ok(setmetatable(nextPlan, Plan))
end

function Plan:markArrival(at)
    if self.state == 'CANCELLED' or self.state == 'COMPLETED' or self.state == 'EXPIRED' then
        return Result.err(Codes.TRAVEL_CONFLICT, 'terminal travel plan cannot arrive')
    end
    local nextPlan = copy(self)
    nextPlan.state = 'ARRIVED'
    nextPlan.progress = 1
    nextPlan.recoveryState = 'NONE'
    nextPlan.arrivedAt = at or nextPlan.arrivedAt
    nextPlan.updatedAt = at or nextPlan.updatedAt
    return Result.ok(setmetatable(nextPlan, Plan))
end

NightShift.Domain.TravelPlan = Plan
