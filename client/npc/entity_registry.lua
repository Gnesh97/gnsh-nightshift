NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Registry = {}
Registry.__index = Registry

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
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
    return Result.err(Codes.ENTITY_INVALID, message, details)
end

function Registry.new(options)
    options = options or {}
    local exists = options.entityExists
    if type(exists) ~= 'function' then
        local native = rawget(_G, 'DoesEntityExist')
        exists = type(native) == 'function' and function(entity)
            local ok, value = pcall(native, entity)
            return ok and value == true
        end or function() return true end
    end
    return setmetatable({ _bindings = {}, _entityExists = exists }, Registry)
end

function Registry:bind(profileKey, generationOrMetadata, entity, extraMetadata)
    if not token(profileKey, 160) then return invalid('client NPC profile key is invalid') end
    local metadata
    if type(generationOrMetadata) == 'table' then
        metadata = generationOrMetadata
    else
        metadata = copy(extraMetadata or {})
        metadata.generationToken = generationOrMetadata
        metadata.entity = entity
    end
    if type(metadata) ~= 'table' then return invalid('client NPC entity metadata must be a table') end
    local allowed = { generation = true, generationToken = true, entity = true, networkId = true, owner = true, state = true }
    for key in pairs(metadata) do
        if not allowed[key] then return invalid('client NPC entity field is not allowlisted', { field = tostring(key) }) end
    end
    if not token(metadata.generationToken, 240) then return invalid('client NPC generation token is required') end
    local generation = tonumber(metadata.generation)
    if not generation or generation < 1 or generation ~= math.floor(generation) then return invalid('client NPC generation is invalid') end
    local entity = handle(metadata.entity)
    if not entity then return invalid('client NPC entity handle is required') end
    local networkId = metadata.networkId == nil and nil or handle(metadata.networkId)
    if metadata.networkId ~= nil and not networkId then return invalid('client NPC network handle is invalid') end
    if metadata.owner ~= nil and (tonumber(metadata.owner) == nil or tonumber(metadata.owner) < 1) then return invalid('client NPC owner is invalid') end
    local state = metadata.state == nil and 'BOUND' or (type(metadata.state) == 'string' and metadata.state:upper() or nil)
    if state ~= 'BOUND' then return invalid('client NPC entity state must be BOUND') end
    local existing = self._bindings[profileKey]
    if existing and existing.generationToken ~= metadata.generationToken then
        return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'client NPC generation token does not match')
    end
    local existsOk, exists = pcall(self._entityExists, entity)
    if not existsOk or exists ~= true then
        return Result.err(Codes.ENTITY_DELETED, 'client NPC entity no longer exists')
    end
    local binding = {
        profileKey = profileKey,
        generation = generation,
        generationToken = metadata.generationToken,
        entity = entity,
        networkId = networkId,
        owner = metadata.owner,
        state = 'BOUND'
    }
    self._bindings[profileKey] = binding
    return Result.ok(copy(binding))
end

function Registry:get(profileKey)
    if not token(profileKey, 160) then return invalid('client NPC profile key is invalid') end
    local binding = self._bindings[profileKey]
    if not binding then return Result.err(Codes.ENTITY_NOT_FOUND, 'client NPC entity mapping was not found') end
    return Result.ok(copy(binding))
end

function Registry:markDeleted(profileKey, generationToken)
    local found = self:get(profileKey)
    if not found.ok then return found end
    if generationToken ~= found.value.generationToken then
        return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'client NPC generation token does not match')
    end
    local binding = found.value
    binding.entity, binding.networkId, binding.state = nil, nil, 'DELETED'
    self._bindings[profileKey] = binding
    return Result.ok(copy(binding))
end

function Registry:detectDeleted(profileKey)
    local found = self:get(profileKey)
    if not found.ok then return found end
    local existsOk, exists = true, false
    if found.value.entity ~= nil then existsOk, exists = pcall(self._entityExists, found.value.entity) end
    if found.value.entity == nil or not existsOk or exists ~= true then
        return self:markDeleted(profileKey, found.value.generationToken)
    end
    return Result.ok(found.value)
end

function Registry:cleanup(profileKey, generationToken)
    local found = self:get(profileKey)
    if not found.ok then return found end
    if generationToken ~= nil and generationToken ~= found.value.generationToken then
        return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'client NPC generation token does not match')
    end
    local binding = found.value
    binding.entity, binding.networkId, binding.state = nil, nil, 'DESPAWNED'
    self._bindings[profileKey] = nil
    return Result.ok(copy(binding))
end

NightShift.ClientNpcEntityRegistry = Registry
