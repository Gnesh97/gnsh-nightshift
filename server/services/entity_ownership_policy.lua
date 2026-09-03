NightShift = NightShift or {}
NightShift.Network = NightShift.Network or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Policy = {}
Policy.__index = Policy

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
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return math.floor(value)
end

local function token(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= (maximum or 160)
        and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function handle(value)
    if integer(value, 1, 2147483647) then return tonumber(value) end
    if token(value, 96) then return value end
    return nil
end

local function state(value)
    value = value == nil and 'AUTHORIZED' or tostring(value):upper()
    local states = NightShift.Enums and NightShift.Enums.NpcEntityStates or {}
    if states[value] ~= true then return nil end
    return value
end

local function source(value)
    return integer(value, 0, 65535)
end

local function invalid(message, details)
    return Result.err(Codes.ENTITY_OWNERSHIP_INVALID or Codes.ENTITY_INVALID, message, details)
end

local function mismatch(message, details)
    return Result.err(Codes.ENTITY_GENERATION_MISMATCH, message, details)
end

local allowed = {
    profileKey = true, travelKey = true, bookingId = true,
    generation = true, generationToken = true, entity = true,
    networkId = true, networkOwner = true, owner = true,
    state = true, serverOwned = true, logicalAuthority = true, physicalAuthority = true
}

function Policy.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('entity ownership policy options must be a table') end
    local config = type(options.config) == 'table' and options.config or {}
    if config.allowNetworkOwnerChange ~= nil and type(config.allowNetworkOwnerChange) ~= 'boolean' then
        return nil, invalid('entity ownership owner-change flag is invalid')
    end
    local orphanStrategy = config.orphanStrategy or 'PRESERVE_LOGICAL_RETRY_PHYSICAL'
    if orphanStrategy ~= 'PRESERVE_LOGICAL_RETRY_PHYSICAL' and orphanStrategy ~= 'PRESERVE_LOGICAL_ONLY' then
        return nil, invalid('entity ownership orphan strategy is invalid')
    end
    return setmetatable({
        _config = {
            logicalAuthority = 'SERVER_DB',
            physicalAuthority = 'RUNTIME_ENTITY',
            allowNetworkOwnerChange = config.allowNetworkOwnerChange ~= false,
            orphanStrategy = orphanStrategy
        }
    }, Policy)
end

function Policy:config()
    return copy(self._config)
end

function Policy:normalize(context)
    if type(context) ~= 'table' then return invalid('entity ownership context must be a table') end
    for key in pairs(context) do
        if not allowed[key] then return invalid('entity ownership field is not allowlisted', { field = tostring(key) }) end
    end
    if not token(context.profileKey, 160) then return invalid('entity ownership profile key is required') end
    if context.travelKey ~= nil and not token(context.travelKey, 200) then return invalid('entity ownership travel key is invalid') end
    if context.bookingId ~= nil and not token(context.bookingId, 160) then return invalid('entity ownership booking ID is invalid') end
    local generation = context.generation == nil and nil or integer(context.generation, 1, 2147483647)
    if context.generation ~= nil and not generation then return invalid('entity ownership generation is invalid') end
    if context.generationToken ~= nil and not token(context.generationToken, 240) then
        return invalid('entity ownership generation token is invalid')
    end
    local entity = context.entity == nil and nil or handle(context.entity)
    if context.entity ~= nil and not entity then return invalid('entity ownership entity handle is invalid') end
    local networkId = context.networkId == nil and nil or handle(context.networkId)
    if context.networkId ~= nil and not networkId then return invalid('entity ownership network ID is invalid') end
    local networkOwnerValue = context.networkOwner
    if networkOwnerValue == nil then networkOwnerValue = context.owner end
    local networkOwner = networkOwnerValue == nil and nil or source(networkOwnerValue)
    if networkOwnerValue ~= nil and networkOwner == nil then return invalid('entity ownership network owner is invalid') end
    if context.serverOwned ~= nil and type(context.serverOwned) ~= 'boolean' then
        return invalid('entity ownership serverOwned flag is invalid')
    end
    if context.logicalAuthority ~= nil and context.logicalAuthority ~= 'SERVER_DB' then
        return invalid('entity ownership logical authority is invalid')
    end
    if context.physicalAuthority ~= nil and context.physicalAuthority ~= 'RUNTIME_ENTITY' then
        return invalid('entity ownership physical authority is invalid')
    end
    local normalizedState = state(context.state)
    if not normalizedState then return invalid('entity ownership state is invalid') end
    return Result.ok({
        profileKey = context.profileKey,
        travelKey = context.travelKey,
        bookingId = context.bookingId,
        generation = generation,
        generationToken = context.generationToken,
        entity = entity,
        networkId = networkId,
        networkOwner = networkOwner,
        state = normalizedState,
        serverOwned = context.serverOwned == nil and true or context.serverOwned,
        logicalAuthority = self._config.logicalAuthority,
        physicalAuthority = self._config.physicalAuthority
    })
end

function Policy:validateGeneration(expected, observed)
    if not token(expected, 240) or not token(observed, 240) then
        return mismatch('entity generation token is required for comparison')
    end
    if expected ~= observed then return mismatch('entity generation token does not match') end
    return Result.ok({ match = true, generationToken = expected })
end

function Policy:classify(binding, observed)
    local normalized = self:normalize(binding)
    if not normalized or normalized.ok ~= true then return normalized end
    observed = observed == nil and {} or observed
    if type(observed) ~= 'table' then return invalid('entity observation must be a table') end
    for key in pairs(observed) do
        if key ~= 'entityPresent' and key ~= 'networkOwner' and key ~= 'networkId'
            and key ~= 'generationToken' and key ~= 'state' then
            return invalid('entity observation field is not allowlisted', { field = tostring(key) })
        end
    end
    if observed.generationToken ~= nil then
        local generation = self:validateGeneration(normalized.value.generationToken, observed.generationToken)
        if not generation.ok then return generation end
    end
    local value = normalized.value
    local physicalPresent = observed.entityPresent
    if physicalPresent == nil then physicalPresent = value.entity ~= nil end
    local observedState = observed.state == nil and value.state or state(observed.state)
    if observed.state ~= nil and not observedState then return invalid('observed entity state is invalid') end
    if observedState == 'DESPAWNED' then
        return Result.ok({ status = 'DESPAWNED', logicalAuthority = value.logicalAuthority,
            physicalAction = 'NONE', preserveLogical = false, networkOwnerChanged = false })
    end
    if observedState == 'DELETED' or value.state == 'DELETED' or not physicalPresent then
        return Result.ok({ status = 'ORPHANED', logicalAuthority = value.logicalAuthority,
            physicalAction = self._config.orphanStrategy == 'PRESERVE_LOGICAL_ONLY' and 'NONE' or 'RETRY_BIND',
            preserveLogical = true, networkOwnerChanged = false })
    end
    local networkOwnerChanged = observed.networkOwner ~= nil and value.networkOwner ~= nil
        and source(observed.networkOwner) ~= value.networkOwner
    if observed.networkOwner ~= nil and source(observed.networkOwner) == nil then
        return invalid('observed entity network owner is invalid')
    end
    return Result.ok({ status = 'BOUND', logicalAuthority = value.logicalAuthority,
        physicalAction = 'KEEP', preserveLogical = true,
        networkOwnerChanged = networkOwnerChanged,
        networkOwner = observed.networkOwner == nil and value.networkOwner or source(observed.networkOwner) })
end

function Policy:reconcile(binding, observed)
    local classified = self:classify(binding, observed)
    if type(classified) ~= 'table' or classified.ok ~= true then return classified end
    local value = classified.value
    local decision = value.status == 'ORPHANED' and 'PRESERVE_LOGICAL_RETRY_PHYSICAL'
        or value.status == 'DESPAWNED' and 'RELEASE_PHYSICAL_ONLY' or 'KEEP_BOUND'
    return Result.ok({ decision = decision, status = value.status,
        logicalAuthority = value.logicalAuthority, physicalAction = value.physicalAction,
        preserveLogical = value.preserveLogical, networkOwnerChanged = value.networkOwnerChanged })
end

NightShift.EntityOwnershipPolicy = Policy
NightShift.Network.EntityOwnershipPolicy = Policy
