NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Config = NightShift.NpcStreamingConfig or {}

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

local function handleMatches(expected, observed)
    local expectedNumber, observedNumber = tonumber(expected), tonumber(observed)
    if expectedNumber ~= nil or observedNumber ~= nil then
        return expectedNumber ~= nil and observedNumber ~= nil and expectedNumber == observedNumber
    end
    return expected == observed
end

local function invalid(message, details)
    return Result.err(Codes.NPC_SPAWN_INVALID, message, details)
end

local function unwrap(value, fallback)
    if type(value) ~= 'table' then return nil, Result.err(fallback or Codes.NPC_SPAWN_INVALID, 'NPC spawn provider returned an invalid result') end
    if value.ok == false then return nil, value end
    if value.ok == true and value.value ~= nil then return value.value end
    if value.success == true and value.value ~= nil then return value.value end
    return value
end

local function callResolver(resolver, ...)
    if type(resolver) == 'table' and type(resolver.resolve) == 'function' then
        local instance = resolver
        return pcall(function(...) return instance:resolve(...) end, ...)
    end
    if type(resolver) == 'function' then return pcall(resolver, ...) end
    return false, nil
end

local function normalizeCandidate(value)
    if type(value) ~= 'table' then return nil end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil end
    local output = { kind = kind }
    if kind == 'coords' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local coordinate = tonumber(value[axis])
            local limit = axis == 'z' and 10000 or 100000
            if not finite(coordinate) or math.abs(coordinate) > limit then return nil end
            output[axis] = coordinate
        end
        if value.heading ~= nil then
            local heading = tonumber(value.heading)
            if not finite(heading) or math.abs(heading) > 360 then return nil end
            output.heading = heading
        end
    else
        if not token(value.provider, 96) then return nil end
        output.provider = value.provider
    end
    return output
end

local function modelAllowed(model, allowlist)
    if not token(model, 96) or type(allowlist) ~= 'table' then return false end
    if allowlist[model] == true then return true end
    for _, value in ipairs(allowlist) do if value == model then return true end end
    return false
end

local function modelValue(resolver, plan, sourceValue)
    if resolver == nil then return nil end
    local ok, result = callResolver(resolver, sourceValue, copy(plan))
    if not ok then return nil, Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC model resolver failed') end
    if type(result) == 'string' then return result end
    local value, resolverError = unwrap(result, Codes.NPC_SPAWN_CONTEXT_REQUIRED)
    if not value and resolverError and resolverError.error then return nil, resolverError end
    if type(value) == 'table' then value = value.model or value.modelName end
    return type(value) == 'string' and value or value
end

local function streamingDistrict(travel)
    if type(travel) ~= 'table' then return 'global' end
    local resolved = type(travel.resolvedDestination) == 'table' and travel.resolvedDestination or {}
    local destination = type(travel.destination) == 'table' and travel.destination or {}
    local origin = type(travel.origin) == 'table' and travel.origin or {}
    local value = resolved.district or destination.district or origin.district or travel.district
    return token(value, 96) and value or 'global'
end

local function releaseStreamingLease(service, playerSource, profileKey)
    local budget = service._streamingBudget
    if type(budget) == 'table' and type(budget.release) == 'function' then
        pcall(budget.release, budget, playerSource, profileKey)
    end
end

function Service.new(options)
    options = options or {}
    if type(options.travelService) ~= 'table' or type(options.travelService.get) ~= 'function' then
        return nil, invalid('NPC spawn service requires a travel service')
    end
    if type(options.entityRegistry) ~= 'table' or type(options.entityRegistry.register) ~= 'function' then
        return nil, invalid('NPC spawn service requires an entity registry')
    end
    local config = options.config or Config
    local allowlist = options.modelAllowlist or config.modelAllowlist or {}
    if options.streamingBudget ~= nil and
        (type(options.streamingBudget) ~= 'table' or type(options.streamingBudget.request) ~= 'function') then
        return nil, invalid('NPC spawn streaming budget is invalid')
    end
    if options.stateBagPolicy ~= nil and
        (type(options.stateBagPolicy) ~= 'table' or type(options.stateBagPolicy.fromLogical) ~= 'function'
            or type(options.stateBagPolicy.write) ~= 'function') then
        return nil, invalid('NPC spawn state bag policy is invalid')
    end
    return setmetatable({
        _travel = options.travelService,
        _registry = options.entityRegistry,
        _location = options.locationService,
        _clock = options.clock,
        _config = copy(config),
        _modelAllowlist = copy(allowlist),
        _modelResolver = options.modelResolver,
        _safeSpawnResolver = options.safeSpawnResolver or options.spawnResolver,
        _appearanceResolver = options.appearanceResolver,
        _createServerEntity = options.createServerEntity,
        _streamingBudget = options.streamingBudget,
        _stateBagPolicy = options.stateBagPolicy
    }, Service)
end

function Service:request(playerSource, request)
    playerSource = source(playerSource)
    if not playerSource then return invalid('NPC spawn source is invalid') end
    if type(request) ~= 'table' then return invalid('NPC spawn request must be a table') end
    for key in pairs(request) do
        if key == 'model' or key == 'modelName' or key == 'coords' or key == 'candidate' or key == 'location' or key == 'spawn' then
            return Result.err(Codes.NPC_SPAWN_UNAUTHORIZED, 'client cannot provide NPC model or location')
        end
        if key ~= 'travelKey' and key ~= 'bookingId' and key ~= 'profileKey' then
            return invalid('NPC spawn request field is not allowlisted', { field = tostring(key) })
        end
    end
    if not token(request.travelKey, 200) or not token(request.bookingId, 160) or not token(request.profileKey, 160) then
        return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC spawn requires a valid travel context')
    end
    local travelResult = self._travel:get(request.travelKey)
    if not travelResult.ok then return travelResult end
    local travel = travelResult.value
    if travel.bookingId ~= request.bookingId or travel.profileKey ~= request.profileKey then
        return Result.err(Codes.NPC_SPAWN_UNAUTHORIZED, 'NPC spawn context does not match the travel plan')
    end
    local readiness = self._travel:shouldSpawn(request.travelKey)
    if not readiness.ok then return readiness end
    if not readiness.value.ready then
        return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC travel has not reached its spawn threshold')
    end
    local model, modelError = modelValue(self._modelResolver, travel, playerSource)
    if modelError then return modelError end
    if model == nil then model = self._config.defaultModel end
    if not modelAllowed(model, self._modelAllowlist) then
        return Result.err(Codes.NPC_SPAWN_MODEL_NOT_ALLOWED, 'NPC model is not allowlisted')
    end
    local candidate
    if self._safeSpawnResolver ~= nil then
        local ok, result = callResolver(self._safeSpawnResolver, playerSource, travel)
        if not ok then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'safe NPC spawn resolver failed') end
        local value, resolverError = unwrap(result, Codes.NPC_SPAWN_CONTEXT_REQUIRED)
        if not value then return resolverError end
        candidate = normalizeCandidate(value.candidate or value.worldTarget or value)
    elseif travel.resolvedDestination then
        candidate = normalizeCandidate(travel.resolvedDestination.worldTarget)
    end
    if not candidate then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'a server-safe NPC spawn candidate is required') end
    local appearanceProfileRef = nil
    if self._appearanceResolver ~= nil then
        local ok, result = callResolver(self._appearanceResolver, playerSource, travel)
        if not ok then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC appearance resolver failed') end
        if ok then
            local value, appearanceError
            if type(result) == 'string' then
                value = result
            else
                value, appearanceError = unwrap(result, Codes.NPC_SPAWN_CONTEXT_REQUIRED)
            end
            if not value and appearanceError then return appearanceError end
            if type(value) == 'table' then value = value.appearanceProfileRef or value.profileRef end
            if value ~= nil and not token(value, 160) then return invalid('NPC appearance reference is invalid') end
            appearanceProfileRef = value
        end
    end
    local entity, networkId, state = nil, nil, 'AUTHORIZED'
    local registryMetadata = {
        travelKey = travel.travelKey, bookingId = travel.bookingId, owner = playerSource,
        state = state, model = model, appearanceProfileRef = appearanceProfileRef
    }
    local streamingLease
    if self._streamingBudget ~= nil then
        local leaseResult = self._streamingBudget:request(
            playerSource, travel.profileKey, streamingDistrict(travel))
        if not leaseResult.ok then return leaseResult end
        streamingLease = leaseResult.value
    end
    if type(self._createServerEntity) == 'function' then
        local ok, result = pcall(self._createServerEntity, {
            source = playerSource, profileKey = travel.profileKey, travelKey = travel.travelKey,
            bookingId = travel.bookingId, model = model, candidate = copy(candidate),
            appearanceProfileRef = appearanceProfileRef, serverOwned = true
        })
        if not ok then
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'server NPC entity creation failed')
        end
        local value, createError = unwrap(result, Codes.NPC_SPAWN_CONTEXT_REQUIRED)
        if not value then
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return createError
        end
        if type(value) ~= 'table' then
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'server entity creator returned no entity')
        end
        entity, networkId = value.entity, value.networkId
        if entity == nil then
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'server entity creator returned no entity handle')
        end
        registryMetadata.entity, registryMetadata.networkId, registryMetadata.state = entity, networkId, 'BOUND'
    end
    local registered = self._registry:register(travel.profileKey, registryMetadata)
    if not registered.ok then
        releaseStreamingLease(self, playerSource, travel.profileKey)
        return registered
    end
    local binding = registered.value
    local stateBag
    if self._stateBagPolicy and type(self._stateBagPolicy.write) == 'function' and binding.entity ~= nil then
        local metadata = self._stateBagPolicy:fromLogical(binding)
        if not metadata.ok then
            self._registry:unregister(travel.profileKey, binding.generationToken)
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return metadata
        end
        local written = self._stateBagPolicy:write(binding.entity, metadata.value)
        if not written.ok and written.error.code ~= Codes.STATE_BAG_UNAVAILABLE then
            self._registry:unregister(travel.profileKey, binding.generationToken)
            releaseStreamingLease(self, playerSource, travel.profileKey)
            return written
        end
        if written.ok then stateBag = written.value end
    end
    return Result.ok({
        serverOwned = true,
        spawnKey = binding.generationToken,
        profileKey = travel.profileKey,
        travelKey = travel.travelKey,
        bookingId = travel.bookingId,
        generation = binding.generation,
        generationToken = binding.generationToken,
        model = model,
        appearanceProfileRef = appearanceProfileRef,
        candidate = copy(candidate),
        entity = entity or binding.entity,
        networkId = networkId or binding.networkId,
        streamingLease = copy(streamingLease),
        stateBag = copy(stateBag)
    })
end

Service.authorize = Service.request

function Service:confirmSpawn(playerSource, payload)
    playerSource = source(playerSource)
    if not playerSource or type(payload) ~= 'table' then return invalid('NPC spawn confirmation is invalid') end
    local allowed = { profileKey = true, travelKey = true, bookingId = true, generationToken = true, entity = true, networkId = true }
    for key in pairs(payload) do if not allowed[key] then return Result.err(Codes.NPC_SPAWN_UNAUTHORIZED, 'spawn confirmation contains an untrusted field', { field = tostring(key) }) end end
    if not token(payload.profileKey, 160) or not token(payload.generationToken, 240) then return invalid('NPC spawn confirmation references are invalid') end
    local existingResult = self._registry:get(payload.profileKey)
    if type(existingResult) == 'table' and existingResult.ok == true and type(existingResult.value) == 'table' then
        local existing = existingResult.value
        if existing.state == 'DELETED' then
            return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'NPC entity mapping is deleted')
        end
        -- A server-created entity is authoritative.  The client may report
        -- the same handle for observability, but it can never replace or
        -- augment the server binding with a forged physical entity/network ID.
        if existing.entity ~= nil then
            if payload.entity ~= nil and not handleMatches(existing.entity, payload.entity) then
                return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'server-owned NPC entity handle does not match')
            end
            if payload.networkId ~= nil then
                if existing.networkId == nil or not handleMatches(existing.networkId, payload.networkId) then
                    return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'server-owned NPC network handle does not match')
                end
            end
            local validated = self._registry:validate(payload.profileKey, payload.generationToken, {
                travelKey = payload.travelKey, bookingId = payload.bookingId, owner = playerSource,
                entity = payload.entity, networkId = payload.networkId
            })
            if not validated.ok then return validated end
            return Result.ok({
                profileKey = existing.profileKey,
                travelKey = existing.travelKey,
                bookingId = existing.bookingId,
                generation = existing.generation,
                generationToken = existing.generationToken,
                entity = existing.entity,
                networkId = existing.networkId,
                serverOwned = true
            }, { observed = true })
        end
    end
    local validated = self._registry:validate(payload.profileKey, payload.generationToken, {
        travelKey = payload.travelKey, bookingId = payload.bookingId, owner = playerSource
    })
    if not validated.ok then return validated end
    local bound = self._registry:bind(payload.profileKey, payload.generationToken, payload.entity, {
        networkId = payload.networkId, owner = playerSource
    })
    if not bound.ok then return bound end
    return Result.ok({
        profileKey = bound.value.profileKey,
        travelKey = bound.value.travelKey,
        bookingId = bound.value.bookingId,
        generation = bound.value.generation,
        generationToken = bound.value.generationToken,
        entity = bound.value.entity,
        networkId = bound.value.networkId,
        serverOwned = true
    })
end

function Service:release(playerSource, profileKey)
    playerSource = source(playerSource)
    if not playerSource or not token(profileKey, 160) then
        return invalid('NPC streaming release reference is invalid')
    end
    if self._streamingBudget == nil then
        return Result.ok({ released = false, bypassed = true })
    end
    return self._streamingBudget:release(playerSource, profileKey)
end

NightShift.NpcSpawnService = Service
