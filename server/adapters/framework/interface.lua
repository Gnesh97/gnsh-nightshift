NightShift = NightShift or {}

local Result = NightShift.Result
local Errors = NightShift.Errors.Codes
local Types = NightShift.Types.Framework

local Interface = NightShift.FrameworkInterface or {}
local Adapter = {}
Adapter.__index = Adapter

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function providerError(code, message, details)
    return Result.err(code, message, details)
end

local function validSource(source)
    source = tonumber(source)
    return source and source >= 1 and math.floor(source) == source
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    return pcall(fn, ...)
end

local function normalizeEvent(adapter, kind, ...)
    if type(adapter._normalizeEvent) == 'function' then
        local ok, value = pcall(adapter._normalizeEvent, adapter, kind, ...)
        if ok and value then return value end
    end
    local first = select(1, ...)
    local source = tonumber(first)
    if not source and type(first) == 'table' then source = tonumber(first.source or first.playerId or first.id) end
    if not validSource(source) then return nil end
    local result = adapter:getPlayer(source)
    return result and result.ok and result.value or nil
end

local function register(adapter, kind, handler)
    if type(handler) ~= 'function' then
        return nil, providerError(Errors.PROVIDER_INVALID, 'lifecycle handler must be a function', { kind = kind })
    end
    local registerFn = adapter._registrars[kind]
    if type(registerFn) ~= 'function' then
        return false
    end
    local wrapped = function(...)
        local value = normalizeEvent(adapter, kind, ...)
        if value then
            local ok, err = pcall(handler, value)
            if not ok then
                return providerError(Errors.PROVIDER_INVALID, 'framework lifecycle handler failed', { kind = kind, reason = tostring(err) })
            end
        end
        return value
    end
    local ok, token = pcall(registerFn, wrapped)
    if not ok then return nil, providerError(Errors.PROVIDER_UNAVAILABLE, 'framework lifecycle registration failed', { kind = kind, reason = tostring(token) }) end
    return token or true
end

function Interface.new(options)
    options = options or {}
    if type(options) ~= 'table' or type(options.name) ~= 'string' or options.name:match('^%s*$') then
        return nil, NightShift.Errors.create(Errors.PROVIDER_INVALID, 'framework adapter name is required')
    end
    if type(options.getPlayer) ~= 'function' or type(options.isPlayerLoaded) ~= 'function' then
        return nil, NightShift.Errors.create(Errors.PROVIDER_INVALID, 'framework adapter must expose player lookup and loaded predicate')
    end
    local adapter = setmetatable({
        name = options.name,
        _available = options.available == nil and true or options.available,
        _getPlayer = options.getPlayer,
        _isPlayerLoaded = options.isPlayerLoaded,
        _getIdentifier = options.getIdentifier,
        _getCharacterId = options.getCharacterId,
        _getCharacterName = options.getCharacterName,
        _getJob = options.getJob,
        _getJobName = options.getJobName,
        _getJobGrade = options.getJobGrade,
        _isOnDuty = options.isOnDuty,
        _registrars = {
            loaded = options.onPlayerLoaded,
            unloaded = options.onPlayerUnloaded,
            job = options.onJobChanged,
            duty = options.onDutyChanged
        },
        _normalizeEvent = options.normalizeEvent,
        _capabilities = copy(options.capabilities or {})
    }, Adapter)
    adapter._capabilities.provider = adapter.name
    adapter._capabilities.available = adapter._available
    return adapter
end

function Interface.isValid(adapter)
    return type(adapter) == 'table'
        and type(adapter.getPlayer) == 'function'
        and type(adapter.isPlayerLoaded) == 'function'
        and type(adapter.getCapabilities) == 'function'
end

function Adapter:isAvailable()
    if type(self._available) == 'function' then
        local ok, value = pcall(self._available)
        return ok and value == true
    end
    return self._available == true
end

function Adapter:getPlayer(source)
    if not validSource(source) then return providerError(Errors.PROVIDER_INVALID, 'source must be a positive integer', { source = source }) end
    local ok, player = call(self._getPlayer, source)
    if not ok then return providerError(Errors.PROVIDER_UNAVAILABLE, 'framework player lookup failed', { source = source }) end
    if type(player) ~= 'table' then return providerError(Errors.PROVIDER_UNAVAILABLE, 'player is not loaded', { source = source }) end
    local function read(fn, fallback)
        if type(fn) ~= 'function' then return fallback end
        local success, value = pcall(fn, player, source)
        return success and value or fallback
    end
    local jobValue = read(self._getJob, player.job)
    local defaultIdentifier = player.identifier or player.license or player.license2
    local defaultCharacterId = player.characterId or player.charid or player.citizenid
    local defaultCharacterName = player.characterName or player.name or player.playerName
    local identity = Types.identity({
        source = source,
        identifier = read(self._getIdentifier, defaultIdentifier),
        characterId = read(self._getCharacterId, defaultCharacterId),
        characterName = read(self._getCharacterName, defaultCharacterName),
        job = {
            name = read(self._getJobName, type(jobValue) == 'table' and (jobValue.name or jobValue.label) or nil),
            grade = read(self._getJobGrade, type(jobValue) == 'table' and (jobValue.grade or jobValue.level) or 0),
            onDuty = (function()
                local duty = read(self._isOnDuty, nil)
                if duty == nil and type(jobValue) == 'table' then duty = jobValue.onDuty; if duty == nil then duty = jobValue.onduty end end
                return duty == true
            end)()
        },
        loaded = true,
        provider = self.name
    })
    if not identity then return providerError(Errors.PROVIDER_INVALID, 'framework returned an invalid normalized identity', { source = source, provider = self.name }) end
    return Result.ok(identity)
end

Adapter.getIdentity = Adapter.getPlayer

function Adapter:getJob(source)
    local result = self:getPlayer(source)
    if not result.ok then return result end
    return Result.ok(result.value.job)
end

function Adapter:isPlayerLoaded(source)
    if not validSource(source) then return false end
    local ok, loaded = call(self._isPlayerLoaded, source)
    return ok and loaded == true
end

function Adapter:onPlayerLoaded(handler) return register(self, 'loaded', handler) end
function Adapter:onPlayerUnloaded(handler) return register(self, 'unloaded', handler) end
function Adapter:onJobChanged(handler) return register(self, 'job', handler) end
function Adapter:onDutyChanged(handler) return register(self, 'duty', handler) end

function Adapter:getCapabilities()
    local capabilities = copy(self._capabilities)
    capabilities.available = self:isAvailable()
    return capabilities
end

function Adapter:healthCheck()
    if not self:isAvailable() then return providerError(Errors.PROVIDER_UNAVAILABLE, 'framework provider is unavailable', { provider = self.name }) end
    return Result.ok({ provider = self.name, available = true, capabilities = self:getCapabilities() })
end

NightShift.FrameworkInterface = Interface
NightShift.FrameworkInterface.Adapter = Adapter
