NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function source(value)
    value = tonumber(value)
    if not value or value < 1 or value ~= math.floor(value) then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.NPC_ARRIVAL_INVALID, message, details)
end

local function call(callback, ...)
    if type(callback) ~= 'function' then return false, nil end
    return pcall(callback, ...)
end

function Service.new(options)
    options = options or {}
    if type(options.travelService) ~= 'table' or type(options.travelService.get) ~= 'function' then
        return nil, invalid('arrival service requires a travel service')
    end
    if type(options.entityRegistry) ~= 'table' or type(options.entityRegistry.validate) ~= 'function' then
        return nil, invalid('arrival service requires an entity registry')
    end
    local maxDistance = tonumber(options.maxDistance or (NightShift.NpcStreamingConfig or {}).maxPlausibleArrivalDistance or 12)
    if not finite(maxDistance) or maxDistance <= 0 or maxDistance > 100000 then return nil, invalid('arrival plausibility distance is invalid') end
    return setmetatable({
        _travel = options.travelService,
        _registry = options.entityRegistry,
        _booking = options.bookingService,
        _actorResolver = options.actorResolver,
        _clock = options.clock,
        _distanceCheck = options.distanceCheck or options.plausibilityCheck,
        _maxDistance = maxDistance
    }, Service)
end

function Service:accept(playerSource, payload)
    playerSource = source(playerSource)
    if not playerSource or type(payload) ~= 'table' then return invalid('arrival payload is invalid') end
    local allowed = {
        travelKey = true, bookingId = true, profileKey = true, generationToken = true,
        entity = true, networkId = true, expectedVersion = true, position = true
    }
    for key in pairs(payload) do
        if not allowed[key] then return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival payload contains an untrusted field', { field = tostring(key) }) end
    end
    if not token(payload.travelKey, 200) or not token(payload.bookingId, 160) or
        not token(payload.profileKey, 160) or not token(payload.generationToken, 240) then
        return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival payload is missing a generation-bound travel context')
    end
    local travelResult = self._travel:get(payload.travelKey)
    if not travelResult.ok then return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival travel plan is unavailable') end
    local travel = travelResult.value
    if travel.bookingId ~= payload.bookingId or travel.profileKey ~= payload.profileKey then
        return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival logical context does not match the travel plan')
    end
    local binding = self._registry:validate(payload.profileKey, payload.generationToken, {
        travelKey = payload.travelKey, bookingId = payload.bookingId,
        entity = payload.entity, networkId = payload.networkId, owner = playerSource
    })
    if not binding.ok then
        if binding.error and binding.error.code == Codes.ENTITY_GENERATION_MISMATCH then
            return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival entity generation does not match')
        end
        return binding
    end
    if travel.state ~= 'TRAVELLING' and travel.state ~= 'ARRIVAL_PENDING' and travel.state ~= 'RECOVERING' then
        return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival travel plan is not active')
    end
    if not travel:isSpawnReady() then
        return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival was reported before the travel spawn threshold')
    end
    if binding.value.state ~= 'BOUND' or binding.value.entity == nil then
        return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival entity binding is deleted or not spawned')
    end
    if type(self._distanceCheck) ~= 'function' then
        return Result.err(Codes.NPC_ARRIVAL_INVALID, 'server arrival plausibility check is unavailable')
    end
    local distanceOk, plausible = call(self._distanceCheck, playerSource, copy(travel), copy(payload), copy(binding.value), self._maxDistance)
    if not distanceOk or plausible == nil then return Result.err(Codes.NPC_ARRIVAL_INVALID, 'server arrival plausibility check failed') end
    if not (plausible == true or type(plausible) == 'table' and (plausible.allowed == true or plausible.ok == true and (plausible.value == nil or plausible.value == true or plausible.value.allowed == true))) then
        return Result.err(Codes.NPC_ARRIVAL_TOO_FAR, 'arrival position is not plausible')
    end
    if type(self._booking) ~= 'table' or type(self._booking.markArrival) ~= 'function' then
        return Result.err(Codes.NPC_ARRIVAL_INVALID, 'booking arrival transition is unavailable')
    end
    local actor = { type = 'PLAYER', ref = tostring(playerSource), source = playerSource }
    if type(self._actorResolver) == 'function' then
        local okActor, resolvedActor = pcall(self._actorResolver, playerSource, copy(payload), copy(travel))
        if okActor and type(resolvedActor) == 'table' and type(resolvedActor.ref) == 'string' then
            actor = { type = 'PLAYER', ref = resolvedActor.ref, source = playerSource }
        end
    end
    local ok, bookingResult = pcall(self._booking.markArrival, self._booking, actor, payload.bookingId, payload.expectedVersion, function()
        return true
    end)
    if not ok or type(bookingResult) ~= 'table' then return Result.err(Codes.NPC_ARRIVAL_INVALID, 'booking arrival transition failed') end
    if bookingResult.ok == false then return bookingResult end
    local marked = self._travel:markArrival(payload.travelKey)
    if not marked.ok then return marked end
    return Result.ok({
        booking = copy(bookingResult.value),
        travel = copy(marked.value),
        profileKey = payload.profileKey,
        generation = binding.value.generation,
        generationToken = binding.value.generationToken
    })
end

-- Pickup has an intermediate arrival at the roadside point. It must be
-- generation/proximity validated just like a destination arrival, but it
-- must not transition the booking to ARRIVED before a vehicle is bound.
function Service:validateOnly(playerSource, payload)
    playerSource = source(playerSource)
    if not playerSource or type(payload) ~= 'table' then return invalid('arrival payload is invalid') end
    local allowed = {
        travelKey = true, bookingId = true, profileKey = true, generationToken = true,
        entity = true, networkId = true, expectedVersion = true, position = true
    }
    for key in pairs(payload) do
        if not allowed[key] then return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival payload contains an untrusted field', { field = tostring(key) }) end
    end
    if not token(payload.travelKey, 200) or not token(payload.bookingId, 160) or
        not token(payload.profileKey, 160) or not token(payload.generationToken, 240) then
        return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival payload is missing a generation-bound travel context')
    end
    local travelResult = self._travel:get(payload.travelKey)
    if not travelResult.ok then return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival travel plan is unavailable') end
    local travel = travelResult.value
    if travel.bookingId ~= payload.bookingId or travel.profileKey ~= payload.profileKey then
        return Result.err(Codes.NPC_ARRIVAL_SPOOF, 'arrival logical context does not match the travel plan')
    end
    local binding = self._registry:validate(payload.profileKey, payload.generationToken, {
        travelKey = payload.travelKey, bookingId = payload.bookingId,
        entity = payload.entity, networkId = payload.networkId, owner = playerSource
    })
    if not binding.ok then return binding end
    if travel.state ~= 'TRAVELLING' and travel.state ~= 'ARRIVAL_PENDING' and travel.state ~= 'RECOVERING' then
        return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival travel plan is not active')
    end
    if not travel:isSpawnReady() then return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival was reported before the travel spawn threshold') end
    if binding.value.state ~= 'BOUND' or binding.value.entity == nil then
        return Result.err(Codes.NPC_ARRIVAL_STALE, 'arrival entity binding is deleted or not spawned')
    end
    if type(self._distanceCheck) ~= 'function' then
        return Result.err(Codes.NPC_ARRIVAL_INVALID, 'server arrival plausibility check is unavailable')
    end
    local distanceOk, plausible = call(self._distanceCheck, playerSource, copy(travel), copy(payload), copy(binding.value), self._maxDistance)
    if not distanceOk or plausible == nil then return Result.err(Codes.NPC_ARRIVAL_INVALID, 'server arrival plausibility check failed') end
    if not (plausible == true or type(plausible) == 'table' and (plausible.allowed == true or plausible.ok == true and (plausible.value == nil or plausible.value == true or plausible.value.allowed == true))) then
        return Result.err(Codes.NPC_ARRIVAL_TOO_FAR, 'arrival position is not plausible')
    end
    return Result.ok({
        bookingId = payload.bookingId, travel = copy(travel), binding = copy(binding.value),
        profileKey = payload.profileKey, generation = binding.value.generation,
        generationToken = binding.value.generationToken
    }, { validated = true, serverAuthoritative = true })
end

Service.validatePickupArrival = Service.validateOnly

Service.markArrival = Service.accept
Service.validate = Service.accept

NightShift.NpcArrivalService = Service
