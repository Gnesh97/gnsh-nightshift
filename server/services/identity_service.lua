NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local IdentityService = {}
IdentityService.__index = IdentityService

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

local function trim(value)
    value = tostring(value or '')
    value = value:gsub('%c', ' '):gsub('%s+', ' ')
    return value:gsub('^%s+', ''):gsub('%s+$', '')
end

local function validSource(source)
    source = tonumber(source)
    return source and source >= 1 and source == math.floor(source) and source ~= math.huge and source ~= -math.huge
end

local function normalizedIdentifier(value)
    value = trim(value)
    if not text(value) or #value > 128 or value:find('%z') then return nil end
    return value
end

local function normalizedCharacterId(value)
    if value == nil then return nil end
    value = trim(value)
    if value == '' then return nil end
    if #value > 128 or value:find('%z') then return nil end
    return value
end

local function safeAlias(value, fallback, maxLength)
    maxLength = tonumber(maxLength) or 80
    if maxLength < 1 then maxLength = 80 end
    value = trim(value)
    if value == '' then value = trim(fallback) end
    value = value:gsub("[^%w%s%._%-']", ' '):gsub('%s+', ' ')
    value = value:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, maxLength)
    if value == '' then value = 'Player' end
    return value
end

local function identityKey(identifier, characterId)
    local character = characterId or ''
    return ('%d:%s|%d:%s'):format(#identifier, identifier, #character, character)
end

local function invalid(message, details)
    return Result.err(Codes.IDENTITY_INVALID, message, details)
end

local function unavailable(message, details)
    return Result.err(Codes.IDENTITY_UNAVAILABLE, message, details)
end

function IdentityService.new(options)
    options = options or {}
    local framework = options.framework or options.frameworkAdapter or options.provider
    local lookup = options.getIdentity or options.lookup
    local lookupMethod = false
    if type(lookup) ~= 'function' and type(framework) == 'table' then
        lookup = framework.getIdentity or framework.getPlayer
        lookupMethod = true
    end
    if type(lookup) ~= 'function' then
        return nil, invalid('identity service requires a framework identity lookup')
    end
    return setmetatable({
        _framework = framework,
        _lookup = lookup,
        _lookupMethod = lookupMethod,
        _aliasMaxLength = tonumber(options.aliasMaxLength) or 80,
        _sourceKeys = {},
        _keySources = {},
        _identities = {}
    }, IdentityService)
end

function IdentityService.isValid(service)
    return type(service) == 'table' and type(service.resolve) == 'function' and type(service.getSource) == 'function'
end

function IdentityService.safeAlias(value, fallback, maxLength)
    return safeAlias(value, fallback, maxLength)
end

function IdentityService.makeKey(identifier, characterId)
    identifier = normalizedIdentifier(identifier)
    if not identifier then return nil end
    characterId = normalizedCharacterId(characterId)
    return identityKey(identifier, characterId)
end

function IdentityService:resolve(source, options)
    options = type(options) == 'table' and copy(options) or {}
    source = tonumber(source)
    if not validSource(source) then return invalid('identity source must be a positive integer', { source = source }) end
    local ok, raw
    if self._lookupMethod then
        ok, raw = pcall(self._lookup, self._framework, source)
        if ok and raw == nil then
            local directOk, directRaw = pcall(self._lookup, source)
            if directOk then ok, raw = directOk, directRaw end
        end
    else
        ok, raw = pcall(self._lookup, source)
    end
    if not ok then return unavailable('framework identity lookup failed', { source = source }) end
    if type(raw) == 'table' and raw.ok ~= nil then
        if raw.ok ~= true then
            return unavailable('framework identity is unavailable', {
                source = source,
                cause = raw.error and raw.error.code or raw.code
            })
        end
        raw = raw.value
    end
    if type(raw) ~= 'table' then return unavailable('framework identity is unavailable', { source = source }) end
    if raw.loaded == false then return unavailable('framework player is not loaded', { source = source }) end

    local identifier = normalizedIdentifier(raw.identifier or raw.license or raw.license2)
    if not identifier then return invalid('framework identity has no persistent identifier', { source = source }) end
    local characterId = normalizedCharacterId(raw.characterId or raw.charid or raw.citizenid)
    local key = identityKey(identifier, characterId)
    local previous = self._sourceKeys[source]
    if previous and previous ~= key and self._keySources[previous] == source then
        self._keySources[previous] = nil
        self._identities[previous] = nil
    end

    local displayName = safeAlias(options.alias or raw.displayName or raw.characterName or raw.name, 'Player', self._aliasMaxLength)
    local identity = {
        identityKey = key,
        key = key,
        identifier = identifier,
        playerIdentifier = identifier,
        characterId = characterId,
        characterName = safeAlias(raw.characterName or raw.name, displayName, self._aliasMaxLength),
        displayName = displayName,
        source = source,
        provider = raw.provider,
        loaded = raw.loaded ~= false,
        job = copy(raw.job)
    }
    self._sourceKeys[source] = key
    self._keySources[key] = source
    self._identities[key] = copy(identity)
    return Result.ok(identity)
end

function IdentityService:getSource(key)
    if not text(key) then return nil end
    return self._keySources[key]
end

function IdentityService:get(key)
    if not text(key) or type(self._identities[key]) ~= 'table' then return nil end
    return copy(self._identities[key])
end

function IdentityService:releaseSource(source)
    source = tonumber(source)
    if not validSource(source) then return invalid('identity source must be a positive integer', { source = source }) end
    local key = self._sourceKeys[source]
    self._sourceKeys[source] = nil
    if key and self._keySources[key] == source then self._keySources[key] = nil end
    if key then self._identities[key] = nil end
    return Result.ok({ source = source, identityKey = key, released = key ~= nil })
end

IdentityService.forgetSource = IdentityService.releaseSource
IdentityService.resolveIdentity = IdentityService.resolve
IdentityService.makeIdentityKey = IdentityService.makeKey
IdentityService.release = IdentityService.releaseSource
NightShift.IdentityService = IdentityService
NightShift.Services = NightShift.Services or {}
NightShift.Services.Identity = IdentityService
