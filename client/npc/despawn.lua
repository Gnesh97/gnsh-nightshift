NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Despawn = {}
Despawn.__index = Despawn

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
    return Result.err(Codes.NPC_DESPAWN_INVALID, message, details)
end

function Despawn.new(options)
    options = options or {}
    if type(options.registry) ~= 'table' or type(options.registry.get) ~= 'function' or type(options.registry.cleanup) ~= 'function' then
        return nil, invalid('despawn controller requires an entity registry')
    end
    return setmetatable({
        _registry = options.registry,
        _fadeOut = options.fadeOut,
        _deleteEntity = options.deleteEntity,
        _onReturn = options.onReturn
    }, Despawn)
end

function Despawn:despawn(context)
    if type(context) ~= 'table' or context.serverOwned ~= true then
        return Result.err(Codes.NPC_DESPAWN_INVALID, 'despawn requires server-owned context')
    end
    local allowed = {
        serverOwned = true, profileKey = true, generationToken = true, entity = true,
        returnWorker = true, cooldownSeconds = true
    }
    for key in pairs(context) do if not allowed[key] then return invalid('despawn context field is not allowlisted', { field = tostring(key) }) end end
    if not token(context.profileKey, 160) or not token(context.generationToken, 240) then
        return invalid('despawn generation context is invalid')
    end
    local found = self._registry:get(context.profileKey)
    if not found.ok then return found end
    if found.value.generationToken ~= context.generationToken then
        return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'despawn generation token does not match')
    end
    local entity = handle(context.entity or found.value.entity)
    if context.entity ~= nil and not entity then return invalid('despawn entity handle is invalid') end
    if entity ~= nil then
        if type(self._fadeOut) == 'function' then
            local ok, value = pcall(self._fadeOut, entity, copy(context))
            if not ok or value == false then return invalid('NPC fade-out failed') end
        end
        if type(self._deleteEntity) == 'function' then
            local ok, value = pcall(self._deleteEntity, entity, copy(context))
            if not ok or value == false then return invalid('NPC entity deletion failed') end
        end
    end
    local cleaned = self._registry:cleanup(context.profileKey, context.generationToken)
    if not cleaned.ok then return cleaned end
    if context.returnWorker == true and type(self._onReturn) == 'function' then
        local ok = pcall(self._onReturn, {
            serverOwned = true,
            profileKey = context.profileKey,
            generationToken = context.generationToken,
            cooldownSeconds = context.cooldownSeconds
        })
        if not ok then return invalid('NPC worker return callback failed') end
    end
    return Result.ok({
        profileKey = cleaned.value.profileKey,
        generation = cleaned.value.generation,
        generationToken = cleaned.value.generationToken,
        entity = entity,
        returned = context.returnWorker == true
    })
end

Despawn.cleanup = Despawn.despawn
Despawn.requestDespawn = Despawn.despawn

NightShift.ClientNpcDespawn = Despawn
