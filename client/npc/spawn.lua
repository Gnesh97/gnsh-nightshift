NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Spawn = {}
Spawn.__index = Spawn

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

local function handle(value)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return value end
    if token(value, 96) then return value end
    return nil
end

local function invalid(message, details)
    return Result.err(Codes.NPC_SPAWN_INVALID, message, details)
end

local function unwrap(value, fallback)
    if type(value) ~= 'table' then return nil, Result.err(fallback or Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'client NPC spawn provider returned an invalid result') end
    if value.ok == false then return nil, value end
    if value.ok == true and value.value ~= nil then return value.value end
    if value.success == true and value.value ~= nil then return value.value end
    return value
end

local function allowedModel(model, allowlist)
    if not token(model, 96) or type(allowlist) ~= 'table' then return false end
    if allowlist[model] == true then return true end
    for _, value in ipairs(allowlist) do if value == model then return true end end
    return false
end

local function candidate(value)
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

function Spawn.new(options)
    options = options or {}
    if type(options.registry) ~= 'table' or type(options.registry.bind) ~= 'function' then
        return nil, invalid('client NPC spawn requires an entity registry')
    end
    return setmetatable({
        _registry = options.registry,
        _modelAllowlist = copy(options.modelAllowlist or {}),
        _loadModel = options.loadModel,
        _createPed = options.createPed,
        _entityExists = options.entityExists
    }, Spawn)
end

function Spawn:spawn(authorization)
    if type(authorization) ~= 'table' or authorization.serverOwned ~= true then
        return Result.err(Codes.NPC_SPAWN_UNAUTHORIZED, 'client NPC spawn requires server authorization')
    end
    if not allowedModel(authorization.model, self._modelAllowlist) then
        return Result.err(Codes.NPC_SPAWN_MODEL_NOT_ALLOWED, 'server NPC model is not allowlisted')
    end
    if not token(authorization.profileKey, 160) or not token(authorization.travelKey, 200) or
        not token(authorization.bookingId, 160) or not token(authorization.generationToken, 240) then
        return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'server spawn authorization is incomplete')
    end
    local safeCandidate = candidate(authorization.candidate)
    if not safeCandidate then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'server spawn candidate is invalid') end
    local entity = handle(authorization.entity)
    local networkId = handle(authorization.networkId)
    if entity == nil then
        if type(self._loadModel) ~= 'function' or type(self._createPed) ~= 'function' then
            return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'client spawn natives are not configured')
        end
        local ok, loaded = pcall(self._loadModel, authorization.model)
        if not ok or loaded ~= true then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC model could not be loaded') end
        local createOk, created = pcall(self._createPed, authorization.model, copy(safeCandidate), copy(authorization))
        if not createOk then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC ped creation failed') end
        local createdValue, createError
        if type(created) == 'number' then
            createdValue = created
        else
            createdValue, createError = unwrap(created)
            if not createdValue then return createError end
        end
        if type(createdValue) == 'table' then
            entity, networkId = handle(createdValue.entity or createdValue.handle), handle(createdValue.networkId)
        else
            entity = handle(createdValue)
        end
        if not entity then return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, 'NPC ped creation returned no entity handle') end
    end
    local bound = self._registry:bind(authorization.profileKey, authorization.generationToken, entity, {
        generation = authorization.generation,
        networkId = networkId,
        owner = authorization.owner
    })
    if not bound.ok then return bound end
    return Result.ok({
        serverOwned = true,
        profileKey = bound.value.profileKey,
        travelKey = authorization.travelKey,
        bookingId = authorization.bookingId,
        generation = bound.value.generation,
        generationToken = bound.value.generationToken,
        entity = bound.value.entity,
        networkId = bound.value.networkId,
        model = authorization.model,
        candidate = safeCandidate
    })
end

Spawn.handleAuthorization = Spawn.spawn

NightShift.ClientNpcSpawn = Spawn
