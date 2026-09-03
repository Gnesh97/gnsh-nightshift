NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local PermissionService = {}
PermissionService.__index = PermissionService

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function source(value)
    value = tonumber(value)
    return value and value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.PERMISSION_INVALID, message, details)
end

local function failed(message, details)
    return Result.err(Codes.PERMISSION_PROVIDER_FAILED, message, details)
end

local function denied(permission, identity, reason)
    return Result.err(Codes.PERMISSION_DENIED, 'permission denied', {
        permission = permission,
        identityKey = identity and (identity.identityKey or identity.key),
        reason = reason
    })
end

local function normalizeDecision(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'table' and value.ok ~= nil then return value.ok == true end
    return nil
end

local function jobRule(definition, jobName)
    local jobs = definition.jobs or definition.jobPermissions or definition.job
    if type(jobs) ~= 'table' or not text(jobName) then return nil end
    local rule = jobs[jobName]
    if rule == nil then return nil end
    if rule == true then return 0 end
    if type(rule) == 'table' then rule = rule.minGrade or rule.grade or rule.minimumGrade end
    rule = rule == nil and 0 or tonumber(rule)
    if not rule or rule < 0 or rule ~= math.floor(rule) then return nil end
    return rule
end

local function identityKey(identity)
    if type(identity) ~= 'table' then return nil end
    if text(identity.identityKey) then return identity.identityKey end
    if text(identity.key) then return identity.key end
    if NightShift.IdentityService and type(NightShift.IdentityService.makeKey) == 'function' then
        return NightShift.IdentityService.makeKey(identity.identifier or identity.playerIdentifier, identity.characterId)
    end
    return nil
end

function PermissionService.new(options)
    options = options or {}
    local framework = options.framework or options.frameworkAdapter or options.provider
    local identity = options.identityService or options.identity or options.identityResolver
    if type(framework) ~= 'table' then return nil, Result.err(Codes.PERMISSION_INVALID, 'permission service requires a framework adapter') end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, Result.err(Codes.PERMISSION_INVALID, 'permission service requires an identity service') end
    local config = options.config or NightShift.PermissionConfig or {}
    local definitions = config.permissions or config
    if type(definitions) ~= 'table' or next(definitions) == nil then return nil, invalid('permission definitions are empty') end
    local service = setmetatable({
        _framework = framework,
        _identity = identity,
        _definitions = copy(definitions),
        _aceChecker = options.aceChecker,
        _provider = options.provider or options.customProvider,
        _audit = options.auditService or options.audit,
        _cache = {},
        _tokens = {}
    }, PermissionService)
    if service._aceChecker == nil and type(rawget(_G, 'IsPlayerAceAllowed')) == 'function' then
        service._aceChecker = rawget(_G, 'IsPlayerAceAllowed')
    end
    if type(framework.onJobChanged) == 'function' then
        local token, registrationError = framework:onJobChanged(function(value)
            service:invalidate(value)
        end)
        if token == nil and registrationError ~= nil then return nil, registrationError end
        service._tokens.job = token
    end
    if type(framework.onPlayerUnloaded) == 'function' then
        local token, registrationError = framework:onPlayerUnloaded(function(value)
            service:invalidate(value)
        end)
        if token == nil and registrationError ~= nil then return nil, registrationError end
        service._tokens.unloaded = token
    end
    return service
end

function PermissionService.isValid(service)
    return type(service) == 'table' and type(service.check) == 'function' and type(service.invalidate) == 'function'
end

function PermissionService:getPermissionKeys()
    local output = {}
    for key in pairs(self._definitions) do output[#output + 1] = key end
    table.sort(output)
    return output
end

function PermissionService:_resolve(sourceValue)
    local ok, result = pcall(self._identity.resolve, self._identity, sourceValue)
    if not ok or type(result) ~= 'table' then return nil, failed('identity resolution failed') end
    if not result.ok then return nil, result end
    if type(result.value) ~= 'table' then return nil, failed('identity resolution returned no identity') end
    return result.value
end

function PermissionService:_cacheKey(identity, permission)
    return (identityKey(identity) or '') .. '\0' .. permission
end

function PermissionService:_cacheResult(key, result)
    self._cache[key] = copy(result)
    return result
end

function PermissionService:_providerDecision(sourceValue, permission, identity, definition)
    if type(self._provider) ~= 'function' then return nil end
    local ok, value = pcall(self._provider, sourceValue, permission, copy(identity), copy(definition))
    if not ok then return false, failed('custom permission provider failed', { permission = permission }) end
    if value == nil then return nil end
    local decision = normalizeDecision(value)
    if decision == nil then return false, failed('custom permission provider returned an invalid decision', { permission = permission }) end
    return decision, nil
end

function PermissionService:_aceDecision(sourceValue, permission, identity, definition)
    if type(self._aceChecker) ~= 'function' then return nil end
    local aceName = definition.ace
    if not text(aceName) then return nil end
    local ok, value = pcall(self._aceChecker, sourceValue, aceName, permission, copy(identity))
    if not ok then return false, failed('ACE permission check failed', { permission = permission }) end
    if type(value) ~= 'boolean' then return false, failed('ACE permission check returned an invalid decision', { permission = permission }) end
    return value, nil
end

function PermissionService:_jobDecision(identity, definition)
    local job = type(identity.job) == 'table' and identity.job or {}
    local minimum = jobRule(definition, job.name)
    if minimum == nil then return nil end
    local grade = tonumber(job.grade) or 0
    return grade >= minimum
end

function PermissionService:_check(sourceValue, permission)
    sourceValue = tonumber(sourceValue)
    if not source(sourceValue) then return invalid('permission source must be a positive integer', { source = sourceValue }) end
    if not text(permission) or type(self._definitions[permission]) ~= 'table' then return invalid('permission key is not allowlisted', { permission = permission }) end
    local identity, identityResult = self:_resolve(sourceValue)
    if not identity then return identityResult end
    local key = self:_cacheKey(identity, permission)
    local cached = self._cache[key]
    if cached then
        if cached.allowed then return Result.ok(cached, { cached = true }) end
        return denied(permission, identity, cached.reason)
    end
    local definition = self._definitions[permission]
    local custom, customError = self:_providerDecision(sourceValue, permission, identity, definition)
    if customError then return customError end
    if custom ~= nil then
        if custom then
            local allowed = { allowed = true, permission = permission, via = 'custom', identityKey = identityKey(identity), source = sourceValue }
            self._cache[key] = copy(allowed)
            return Result.ok(allowed)
        end
        return denied(permission, identity, 'custom')
    end
    local ace, aceError = self:_aceDecision(sourceValue, permission, identity, definition)
    if aceError then return aceError end
    if ace == true then
        local allowed = { allowed = true, permission = permission, via = 'ace', identityKey = identityKey(identity), source = sourceValue }
        self._cache[key] = copy(allowed)
        return Result.ok(allowed)
    end
    local job = self:_jobDecision(identity, definition)
    if job == true then
        local allowed = { allowed = true, permission = permission, via = 'job', identityKey = identityKey(identity), source = sourceValue }
        self._cache[key] = copy(allowed)
        return Result.ok(allowed)
    end
    return denied(permission, identity, ace == false and 'ace' or 'job')
end

function PermissionService:check(sourceValue, permission)
    local result = self:_check(sourceValue, permission)
    if type(self._audit) == 'table' and type(self._audit.record) == 'function' then
        local numericSource = tonumber(sourceValue)
        local errorResult = type(result) == 'table' and (result.error or result) or nil
        pcall(self._audit.record, self._audit, {
            actor = numericSource and { source = numericSource, actorType = 'PLAYER' } or nil,
            action = 'permission.check',
            target = { type = 'PERMISSION', ref = tostring(permission or '') },
            result = result,
            resultStatus = type(result) == 'table' and result.ok == true and 'OK' or 'ERROR',
            resultCode = errorResult and errorResult.code or nil,
            reason = errorResult and errorResult.message or nil,
            metadata = {
                via = type(result) == 'table' and type(result.value) == 'table' and result.value.via or nil
            }
        })
    end
    return result
end

PermissionService.authorize = PermissionService.check

function PermissionService:isAllowed(sourceValue, permission)
    local result = self:check(sourceValue, permission)
    return result.ok == true
end

PermissionService.has = PermissionService.isAllowed
PermissionService.can = PermissionService.isAllowed

function PermissionService:invalidate(identityOrSource)
    local key = type(identityOrSource) == 'table' and identityKey(identityOrSource) or nil
    local sourceValue = type(identityOrSource) == 'table' and tonumber(identityOrSource.source) or tonumber(identityOrSource)
    for cacheKey, entry in pairs(self._cache) do
        local matchesKey = key and cacheKey:sub(1, #key) == key
        local matchesSource = sourceValue and entry.source == sourceValue
        if matchesKey or matchesSource then self._cache[cacheKey] = nil end
    end
    return Result.ok({ invalidated = true, identityKey = key, source = sourceValue })
end

function PermissionService:invalidateAll()
    self._cache = {}
    return Result.ok({ invalidated = true, all = true })
end

function PermissionService:healthCheck()
    return Result.ok({ healthy = true, permissions = #self:getPermissionKeys() })
end

NightShift.PermissionService = PermissionService
NightShift.Services = NightShift.Services or {}
NightShift.Services.Permission = PermissionService
