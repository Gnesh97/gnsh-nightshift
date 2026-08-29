NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.WorkerProfile

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

local function invalid(message, details)
    return Result.err(Codes.PROFILE_INVALID, message, details)
end

local function lookupIdentity(service, source, options)
    if type(service._identity) ~= 'table' or type(service._identity.resolve) ~= 'function' then
        return nil, Result.err(Codes.IDENTITY_INVALID, 'worker profile service requires an identity service')
    end
    local ok, result = pcall(service._identity.resolve, service._identity, source, options)
    if not ok or type(result) ~= 'table' then return nil, Result.err(Codes.IDENTITY_UNAVAILABLE, 'worker identity could not be resolved') end
    if not result.ok then return nil, result end
    if type(result.value) ~= 'table' then return nil, Result.err(Codes.IDENTITY_INVALID, 'identity service returned no identity') end
    return result.value
end

local function profileInput(identity, attributes)
    local values = copy(attributes or {})
    if type(values) ~= 'table' then values = {} end
    values.playerIdentifier = identity.playerIdentifier or identity.identifier
    values.characterId = identity.characterId
    values.identityKey = identity.identityKey or identity.key
    values.characterName = identity.characterName
    if values.displayName == nil and values.alias == nil then values.displayName = identity.displayName end
    if values.jobName == nil and values.job_name == nil and type(identity.job) == 'table' then values.jobName = identity.job.name end
    return values
end

function Service.new(options)
    options = options or {}
    if type(options.identityService or options.identity or options.identityResolver) ~= 'table' then return nil, Result.err(Codes.IDENTITY_INVALID, 'worker profile service requires identityService') end
    if type(options.repository or options.workerProfileRepository) ~= 'table' or type((options.repository or options.workerProfileRepository).findByIdentity) ~= 'function' or type((options.repository or options.workerProfileRepository).create) ~= 'function' then
        return nil, Result.err(Codes.REPOSITORY_INVALID, 'worker profile service requires a worker profile repository')
    end
    return setmetatable({ _identity = options.identityService or options.identity or options.identityResolver, _repository = options.repository or options.workerProfileRepository }, Service)
end

function Service:get(source)
    local identity, identityResult = lookupIdentity(self, source)
    if not identity then return identityResult end
    return self._repository:findByIdentity(identity.playerIdentifier or identity.identifier, identity.characterId)
end

function Service:ensure(source, attributes, identityOptions)
    local identity, identityResult = lookupIdentity(self, source, identityOptions)
    if not identity then return identityResult end
    local identifier = identity.playerIdentifier or identity.identifier
    local existing = self._repository:findByIdentity(identifier, identity.characterId)
    if type(existing) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'worker profile lookup returned an invalid result') end
    if existing.ok then return existing end
    if not existing.error or existing.error.code ~= Codes.REPOSITORY_NOT_FOUND then return existing end

    local profile, profileError = Domain.new(profileInput(identity, attributes))
    if not profile then return profileError end
    local created = self._repository:create(profile)
    if type(created) ~= 'table' then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'worker profile create returned an invalid result') end
    if not created.ok then
        local raced = self._repository:findByIdentity(identifier, identity.characterId)
        if type(raced) == 'table' and raced.ok then return raced end
        return created
    end
    local persisted = self._repository:findByIdentity(identifier, identity.characterId)
    if type(persisted) == 'table' then
        if persisted.ok then return persisted end
        return persisted
    end
    local fallback = copy(profile)
    local insertId = created.value and (created.value.insertId or created.value.id)
    if insertId ~= nil then fallback.id = insertId end
    return Result.ok(fallback, { persisted = false })
end

Service.create = Service.ensure
Service.getOrCreate = Service.ensure

function Service:update(source, changes)
    if type(changes) ~= 'table' then return invalid('worker profile changes must be a table') end
    local identity, identityResult = lookupIdentity(self, source)
    if not identity then return identityResult end
    local identifier = identity.playerIdentifier or identity.identifier
    local current = self._repository:findByIdentity(identifier, identity.characterId)
    if type(current) ~= 'table' or not current.ok then return current end
    local nextProfile, profileError = Domain.apply(current.value, changes)
    if not nextProfile then return profileError end
    local updated = self._repository:updateExpectedVersion(current.value.id, current.value.version, changes)
    if type(updated) ~= 'table' or not updated.ok then return updated end
    nextProfile.id = current.value.id
    nextProfile.version = updated.value and updated.value.version or current.value.version + 1
    nextProfile.createdAt = current.value.createdAt
    nextProfile.updatedAt = current.value.updatedAt
    return Result.ok(nextProfile, { identityKey = identity.identityKey, version = nextProfile.version })
end

function Service:list(options)
    if type(self._repository.findAll) ~= 'function' then return Result.err(Codes.REPOSITORY_INVALID, 'worker profile repository cannot list profiles') end
    return self._repository:findAll(options)
end

NightShift.WorkerProfileService = Service
NightShift.Services = NightShift.Services or {}
NightShift.Services.WorkerProfile = Service
