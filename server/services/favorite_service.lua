NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

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

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.FAVORITE_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function actor(service, source)
    if type(service._identity) ~= 'table' or type(service._identity.resolve) ~= 'function' then
        return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'favorite identity service is unavailable')
    end
    local ok, result = pcall(service._identity.resolve, service._identity, source)
    if not ok or type(result) ~= 'table' or not result.ok or type(result.value) ~= 'table' then
        return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'favorite identity could not be resolved')
    end
    local identity = result.value
    return { type = 'PLAYER', ref = identity.identityKey or identity.key, source = source, identity = identity }
end

local function safeWorker(worker)
    local profile = type(worker) == 'table' and worker.profile or {}
    return {
        workerKey = worker and worker.workerKey,
        profileKey = profile and (profile.profileKey or profile.key),
        alias = profile and (profile.alias or profile.displayName),
        rating = profile and tonumber(profile.rating) or 0,
        persistent = profile and tostring(profile.profileType or ''):upper() == 'PERSISTENT' or false
    }
end

local function ensureClientProfile(service, source)
    if type(service) ~= 'table' then return nil end
    local ensure = type(service.ensure) == 'function' and service.ensure or service.getOrCreate
    if type(ensure) ~= 'function' then return nil end
    local ok, result = pcall(ensure, service, source)
    if not ok or type(result) ~= 'table' then
        return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile could not be ensured')
    end
    if result.ok == true then
        local value = result.value or result.data
        if type(value) == 'table' then return value end
        return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile service returned an invalid result')
    end
    if result.ok == false then return nil, result end
    return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile service returned an invalid result')
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.favoriteRepository
    if type(repository) ~= 'table' or type(repository.findByPair) ~= 'function' or type(repository.create) ~= 'function' or type(repository.deleteExpectedVersion) ~= 'function' then
        return nil, invalid('favorite service requires a favorite repository')
    end
    local identity = options.identityService or options.identity
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, invalid('favorite service requires an identity service') end
    local worker = options.workerService or options.npcWorkerService
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' then return nil, invalid('favorite service requires an NPC worker service') end
    local config = options.config or NightShift.ReputationConfig or {}
    local favoriteConfig = type(config.favorite) == 'table' and config.favorite or
        type(config.favorites) == 'table' and config.favorites or config
    return setmetatable({
        _repository = repository,
        _identity = identity,
        _worker = worker,
        _clientProfileService = options.clientProfileService or options.clientProfile,
        _clientRepository = options.clientProfileRepository or options.clientRepository,
        _persistentOnly = options.persistentOnly ~= false and favoriteConfig.persistentOnly ~= false
    }, Service)
end

function Service:_workerByProfileId(profileId)
    if type(self._worker) ~= 'table' then return nil end
    if type(self._worker.getByProfileId) == 'function' then
        local result = self._worker:getByProfileId(profileId)
        if type(result) == 'table' and result.ok then return result.value end
    end
    if type(self._worker.listAvailable) == 'function' then
        local result = self._worker:listAvailable({ limit = 100 })
        if type(result) == 'table' and result.ok then
            for _, worker in ipairs(result.value and result.value.items or {}) do
                local profile = worker.profile
                local id = worker.profileId or profile and profile.id
                if tonumber(id) == tonumber(profileId) then return worker end
            end
        end
    end
    return nil
end

function Service:_clientProfile(source, identity)
    if type(self._clientProfileService) == 'table' and type(self._clientProfileService.get) == 'function' then
        local result = self._clientProfileService:get(source)
        if type(result) == 'table' and result.ok then
            if type(result.value) == 'table' then return result.value end
            return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile lookup returned an invalid result')
        end
        if type(result) == 'table' and notFound(result) then
            local ensured, ensureError = ensureClientProfile(self._clientProfileService, source)
            if ensured then return ensured end
            return nil, ensureError or Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile was not found')
        end
        if type(result) == 'table' and result.error then return nil, result end
        if result ~= nil then return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile lookup returned an invalid result') end
    end
    if type(self._clientRepository) == 'table' and type(self._clientRepository.findByIdentity) == 'function' then
        local result = self._clientRepository:findByIdentity(identity.playerIdentifier or identity.identifier, identity.characterId)
        if type(result) == 'table' and result.ok then
            if type(result.value) == 'table' then return result.value end
            return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile lookup returned an invalid result')
        end
        if type(result) == 'table' and notFound(result) then
            return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile was not found')
        end
        return nil, type(result) == 'table' and result or Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile lookup returned an invalid result')
    end
    return nil, Result.err(Codes.FAVORITE_OPERATION_FAILED, 'client profile was not found')
end

function Service:_workerFor(key)
    if not text(key, 160) then return nil, invalid('NPC worker key is invalid') end
    local result = self._worker:get(key)
    if type(result) ~= 'table' or not result.ok then return nil, result end
    local worker = result.value
    local profile = worker and worker.profile
    if type(profile) ~= 'table' or integer(profile.id, 1, 2147483647) == nil then
        return nil, Result.err(Codes.FAVORITE_NOT_FOUND, 'NPC worker profile is unavailable')
    end
    if self._persistentOnly and tostring(profile.profileType or ''):upper() ~= 'PERSISTENT' then
        return nil, Result.err(Codes.FAVORITE_INVALID, 'only persistent NPC workers can be favorited')
    end
    return worker
end

function Service:add(source, workerKey)
    local actorValue, actorError = actor(self, source)
    if not actorValue then return actorError end
    local worker, workerError = self:_workerFor(workerKey)
    if not worker then return workerError end
    local client, clientError = self:_clientProfile(source, actorValue.identity)
    if not client then return clientError end
    local workerProfile = worker.profile
    local existing = self._repository:findByPair(client.id, workerProfile.id)
    if type(existing) ~= 'table' then return Result.err(Codes.FAVORITE_OPERATION_FAILED, 'favorite lookup returned an invalid result') end
    if existing.ok then return Result.ok({ favorite = safeWorker(worker), relation = existing.value }, { idempotent = true }) end
    if not notFound(existing) then return existing end
    local created = self._repository:create({ clientProfileId = client.id, workerProfileId = workerProfile.id })
    if type(created) ~= 'table' or not created.ok then
        local raced = self._repository:findByPair(client.id, workerProfile.id)
        if type(raced) == 'table' and raced.ok then return Result.ok({ favorite = safeWorker(worker), relation = raced.value }, { idempotent = true }) end
        return Result.err(Codes.FAVORITE_OPERATION_FAILED, 'favorite could not be persisted', { cause = created and created.error and created.error.code })
    end
    return Result.ok({ favorite = safeWorker(worker), relation = created.value }, { created = true, serverAuthoritative = true })
end

function Service:remove(source, workerKey)
    local actorValue, actorError = actor(self, source)
    if not actorValue then return actorError end
    local worker, workerError = self:_workerFor(workerKey)
    if not worker then return workerError end
    local client, clientError = self:_clientProfile(source, actorValue.identity)
    if not client then return clientError end
    local relation = self._repository:findByPair(client.id, worker.profile.id)
    if type(relation) ~= 'table' then return Result.err(Codes.FAVORITE_OPERATION_FAILED, 'favorite lookup returned an invalid result') end
    if not relation.ok then
        if notFound(relation) then return Result.ok({ removed = false, favorite = safeWorker(worker) }, { idempotent = true }) end
        return relation
    end
    local deleted = self._repository:deleteExpectedVersion(relation.value.id, relation.value.version)
    if type(deleted) ~= 'table' or not deleted.ok then
        return Result.err(Codes.FAVORITE_OPERATION_FAILED, 'favorite could not be removed', { cause = deleted and deleted.error and deleted.error.code })
    end
    return Result.ok({ removed = true, favorite = safeWorker(worker) }, { serverAuthoritative = true })
end

function Service:list(source, options)
    local actorValue, actorError = actor(self, source)
    if not actorValue then return actorError end
    local client, clientError = self:_clientProfile(source, actorValue.identity)
    if not client then return clientError end
    if type(self._repository.findByClient) ~= 'function' then return Result.err(Codes.FAVORITE_OPERATION_FAILED, 'favorite repository cannot list favorites') end
    local result = self._repository:findByClient(client.id, options)
    if type(result) ~= 'table' or not result.ok then return result end
    local items = {}
    for index, relation in ipairs(result.value or {}) do
        local worker = self:_workerByProfileId(relation.workerProfileId)
        if worker then
            items[index] = { relation = { id = relation.id, version = relation.version }, favorite = safeWorker(worker) }
        else
            items[index] = { relation = { id = relation.id, version = relation.version }, workerProfileId = relation.workerProfileId }
        end
    end
    return Result.ok({ items = items }, result.metadata)
end

Service.addFavorite = Service.add
Service.removeFavorite = Service.remove
NightShift.FavoriteService = Service
