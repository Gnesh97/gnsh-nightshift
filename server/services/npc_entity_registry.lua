NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Enums = NightShift.Enums

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

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function source(value)
    value = tonumber(value)
    if not value or value < 1 or value ~= math.floor(value) then return nil end
    return value
end

local function handle(value)
    if value == nil then return nil end
    if finite(tonumber(value)) and tonumber(value) >= 1 then return tonumber(value) end
    if token(value, 96) then return value end
    return nil
end

local function invalid(message, details)
    return Result.err(Codes.ENTITY_INVALID, message, details)
end

local function notFound(profileKey)
    return Result.err(Codes.ENTITY_NOT_FOUND, 'NPC entity mapping was not found', { profileKey = profileKey })
end

local function bindingError(code, message, details)
    return Result.err(code, message, details)
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function generationToken(profileKey, generation)
    return ('npc:%s:%d'):format(profileKey, generation)
end

function Registry.new(options)
    options = options or {}
    return setmetatable({ _clock = options.clock, _bindings = {}, _generations = {} }, Registry)
end

function Registry:register(profileKey, metadata)
    if not token(profileKey, 160) then return invalid('NPC entity profile key is invalid') end
    if type(metadata) ~= 'table' then return invalid('NPC entity metadata must be a table') end
    local allowed = {
        travelKey = true, bookingId = true, entity = true, networkId = true,
        owner = true, state = true, model = true, appearanceProfileRef = true
    }
    for key in pairs(metadata) do
        if not allowed[key] then return invalid('NPC entity metadata field is not allowlisted', { field = tostring(key) }) end
    end
    if metadata.travelKey ~= nil and not token(metadata.travelKey, 200) then return invalid('NPC entity travel key is invalid') end
    if metadata.bookingId ~= nil and not token(metadata.bookingId, 160) then return invalid('NPC entity booking ID is invalid') end
    local owner = metadata.owner == nil and nil or source(metadata.owner)
    if metadata.owner ~= nil and not owner then return invalid('NPC entity owner is invalid') end
    local entity = handle(metadata.entity)
    local networkId = handle(metadata.networkId)
    if metadata.entity ~= nil and not entity then return invalid('NPC entity handle is invalid') end
    if metadata.networkId ~= nil and not networkId then return invalid('NPC network handle is invalid') end
    local state = metadata.state == nil and (entity and 'BOUND' or 'AUTHORIZED') or (type(metadata.state) == 'string' and metadata.state:upper() or nil)
    if not state or not Enums.NpcEntityStates[state] then return invalid('NPC entity state is invalid') end
    if state == 'BOUND' and not entity then return invalid('BOUND NPC entity requires an entity handle') end
    if metadata.model ~= nil and not token(metadata.model, 96) then return invalid('NPC entity model reference is invalid') end
    if metadata.appearanceProfileRef ~= nil and not token(metadata.appearanceProfileRef, 160) then return invalid('NPC appearance reference is invalid') end
    local existing = self._bindings[profileKey]
    if existing and existing.state ~= 'DESPAWNED' and existing.state ~= 'DELETED' then
        if existing.travelKey == metadata.travelKey and existing.bookingId == metadata.bookingId then
            return Result.ok(copy(existing), { idempotent = true })
        end
        return bindingError(Codes.ENTITY_INVALID, 'NPC profile is already bound to another logical context')
    end
    local generation = (self._generations[profileKey] or 0) + 1
    self._generations[profileKey] = generation
    local binding = {
        profileKey = profileKey,
        travelKey = metadata.travelKey,
        bookingId = metadata.bookingId,
        generation = generation,
        generationToken = generationToken(profileKey, generation),
        entity = entity,
        networkId = networkId,
        owner = owner,
        state = state,
        model = metadata.model,
        appearanceProfileRef = metadata.appearanceProfileRef,
        createdAt = now(self._clock),
        updatedAt = now(self._clock)
    }
    self._bindings[profileKey] = binding
    return Result.ok(copy(binding), { created = true })
end

function Registry:get(profileKey)
    if not token(profileKey, 160) then return invalid('NPC entity profile key is invalid') end
    local binding = self._bindings[profileKey]
    if not binding or binding.state == 'DESPAWNED' then return notFound(profileKey) end
    return Result.ok(copy(binding))
end

local function current(self, profileKey, generationTokenValue)
    if not token(profileKey, 160) then return nil, invalid('NPC entity profile key is invalid') end
    local binding = self._bindings[profileKey]
    if not binding or binding.state == 'DESPAWNED' then return nil, notFound(profileKey) end
    if generationTokenValue ~= binding.generationToken then
        return nil, bindingError(Codes.ENTITY_GENERATION_MISMATCH, 'NPC entity generation token does not match')
    end
    return binding
end

function Registry:bind(profileKey, generationTokenValue, entity, metadata)
    local binding, errorResult = current(self, profileKey, generationTokenValue)
    if not binding then return errorResult end
    if not handle(entity) then return invalid('NPC entity handle is required') end
    metadata = metadata or {}
    if type(metadata) ~= 'table' then return invalid('NPC entity bind metadata must be a table') end
    for key in pairs(metadata) do
        if key ~= 'networkId' and key ~= 'owner' then return invalid('NPC entity bind field is not allowlisted', { field = tostring(key) }) end
    end
    local networkId = metadata.networkId == nil and binding.networkId or handle(metadata.networkId)
    if metadata.networkId ~= nil and not networkId then return invalid('NPC network handle is invalid') end
    local owner = metadata.owner == nil and binding.owner or source(metadata.owner)
    if metadata.owner ~= nil and not owner then return invalid('NPC entity owner is invalid') end
    binding.entity, binding.networkId, binding.owner = handle(entity), networkId, owner
    binding.state, binding.updatedAt = 'BOUND', now(self._clock)
    return Result.ok(copy(binding))
end

Registry.updateEntity = Registry.bind

function Registry:updateOwner(profileKey, generationTokenValue, owner)
    local binding, errorResult = current(self, profileKey, generationTokenValue)
    if not binding then return errorResult end
    owner = source(owner)
    if not owner then return invalid('NPC entity owner is invalid') end
    binding.owner, binding.updatedAt = owner, now(self._clock)
    return Result.ok(copy(binding))
end

function Registry:markDeleted(profileKey, generationTokenValue)
    local binding, errorResult = current(self, profileKey, generationTokenValue)
    if not binding then return errorResult end
    binding.entity, binding.networkId, binding.state = nil, nil, 'DELETED'
    binding.updatedAt, binding.deletedAt = now(self._clock), now(self._clock)
    return Result.ok(copy(binding))
end

function Registry:unregister(profileKey, generationTokenValue)
    local binding, errorResult = current(self, profileKey, generationTokenValue)
    if not binding then return errorResult end
    binding.entity, binding.networkId, binding.state = nil, nil, 'DESPAWNED'
    binding.updatedAt, binding.despawnedAt = now(self._clock), now(self._clock)
    self._bindings[profileKey] = nil
    return Result.ok(copy(binding))
end

function Registry:validate(profileKey, generationTokenValue, context)
    local binding, errorResult = current(self, profileKey, generationTokenValue)
    if not binding then return errorResult end
    if context ~= nil and type(context) ~= 'table' then return invalid('NPC entity validation context must be a table') end
    context = context or {}
    for _, key in ipairs({ 'travelKey', 'bookingId' }) do
        if context[key] ~= nil and context[key] ~= binding[key] then
            return bindingError(Codes.ENTITY_GENERATION_MISMATCH, 'NPC entity logical context does not match', { field = key })
        end
    end
    if context.entity ~= nil and binding.entity ~= nil and handle(context.entity) ~= binding.entity then
        return bindingError(Codes.ENTITY_GENERATION_MISMATCH, 'NPC entity handle does not match')
    end
    if context.networkId ~= nil and binding.networkId ~= nil and handle(context.networkId) ~= binding.networkId then
        return bindingError(Codes.ENTITY_GENERATION_MISMATCH, 'NPC network handle does not match')
    end
    if context.owner ~= nil and binding.owner ~= nil and source(context.owner) ~= binding.owner then
        return bindingError(Codes.ENTITY_GENERATION_MISMATCH, 'NPC entity owner does not match')
    end
    return Result.ok(copy(binding))
end

function Registry:isDeleted(profileKey, generationTokenValue)
    local found = self:validate(profileKey, generationTokenValue)
    if not found.ok then return found end
    return Result.ok({ deleted = found.value.state == 'DELETED', binding = found.value })
end

NightShift.NpcEntityRegistry = Registry
