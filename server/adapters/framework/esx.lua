NightShift = NightShift or {}
NightShift.FrameworkAdapters = NightShift.FrameworkAdapters or {}

local Interface = NightShift.FrameworkInterface
local Types = NightShift.Types.Framework
local Result = NightShift.Result

local function invoke(container, method, ...)
    if type(container) ~= 'table' then return nil end
    local fn = container[method]
    if type(fn) ~= 'function' then return nil end
    local called, value = pcall(fn, container, ...)
    if called and value ~= nil then return value end
    called, value = pcall(fn, ...)
    return called and value or nil
end

local function getESX(options)
    if type(options.esx) == 'table' then return options.esx end
    if type(options.getESX) == 'function' then
        local ok, value = pcall(options.getESX)
        if ok and type(value) == 'table' then return value end
    end
    local exports = rawget(_G, 'exports')
    if exports ~= nil then
        local ok, value = pcall(function() return exports['es_extended']:getSharedObject() end)
        if ok and type(value) == 'table' then return value end
    end
    return nil
end

local function registerEvent(options, name, handler)
    if type(options.eventRegistrar) == 'function' then return options.eventRegistrar(name, handler) end
    local addEventHandler = rawget(_G, 'AddEventHandler')
    if type(addEventHandler) == 'function' then return addEventHandler(name, handler) end
    return false
end

local function getJob(player)
    local value = invoke(player, 'getJob') or player.job
    return type(value) == 'table' and value or {}
end

local function normalizeEvent(adapter, kind, source, payload)
    local first = source
    source = tonumber(first) or (type(payload) == 'table' and tonumber(payload.source or payload.playerId or payload.ServerId or payload.serverId))
    if not source and type(first) == 'table' then source = tonumber(first.source or first.playerId or first.ServerId or first.serverId) end
    if not source then source = tonumber(rawget(_G, 'source')) end
    if not source then return nil end
    local result = adapter:getPlayer(source)
    local identity = result and result.ok and result.value or nil
    if not identity and kind == 'unloaded' and type(adapter.getLastIdentity) == 'function' then
        identity = adapter:getLastIdentity(source, false)
    end
    if (kind == 'job' or kind == 'duty') and identity and type(payload) == 'table' then
        local current = Types.copy(identity.job or {})
        current.name = payload.name or payload.label or current.name
        local grade = payload.grade
        if type(grade) == 'table' then grade = grade.level or grade.id end
        current.grade = grade or payload.level or current.grade
        if payload.onDuty ~= nil then current.onDuty = payload.onDuty end
        if payload.onduty ~= nil then current.onDuty = payload.onduty end
        identity.job = Types.job(current)
    elseif kind == 'duty' and identity and type(payload) == 'boolean' then
        local current = Types.copy(identity.job or {})
        current.onDuty = payload
        identity.job = Types.job(current)
    end
    if kind == 'unloaded' and identity then
        identity.loaded = false
    end
    return identity
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local esx = getESX(options)
    local availability = {}
    local events = options.events or {}
    local getPlayerFromId = options.getPlayerFromId or (esx and (esx.GetPlayerFromId or esx.getPlayerFromId))
    local adapter, err = Interface.new({
        name = 'esx',
        available = function() return type(getPlayerFromId) == 'function' or type(options.playerResolver) == 'function' end,
        capabilities = {
            native = true, identity = true, characterId = true, job = true,
            grade = true, duty = false, internalDuty = true, availability = true,
            lifecycle = true, money = true
        },
        getPlayer = function(source)
            if type(options.playerResolver) == 'function' then
                local ok, value = pcall(options.playerResolver, source)
                if ok then return value end
            end
            if type(getPlayerFromId) ~= 'function' then return nil end
            local ok, value = pcall(getPlayerFromId, source)
            if ok and value ~= nil then return value end
            local called, value = pcall(getPlayerFromId, esx, source)
            return called and value or nil
        end,
        isPlayerLoaded = function(source)
            if type(options.isPlayerLoaded) == 'function' then
                local ok, value = pcall(options.isPlayerLoaded, source)
                return ok and value == true
            end
            if type(options.playerResolver) == 'function' then
                local ok, value = pcall(options.playerResolver, source)
                return ok and value ~= nil
            end
            if type(getPlayerFromId) ~= 'function' then return false end
            local ok, value = pcall(getPlayerFromId, source)
            if ok and value ~= nil then return true end
            local called, value = pcall(getPlayerFromId, esx, source)
            return called and value ~= nil
        end,
        getIdentifier = function(player)
            return invoke(player, 'getIdentifier') or player.identifier or player.license
        end,
        getCharacterId = function(player, source)
            local custom
            if type(options.characterIdResolver) == 'function' then
                local ok, value = pcall(options.characterIdResolver, player, source)
                if ok then custom = value end
            end
            return custom or player.characterId or player.charid or invoke(player, 'getCharacterId')
                or invoke(player, 'getIdentifier') or player.identifier
        end,
        getCharacterName = function(player)
            return invoke(player, 'getName') or player.name or player.playerName
        end,
        getJob = getJob,
        getJobName = function(player) return getJob(player).name end,
        getJobGrade = function(player)
            local value = getJob(player)
            return value.grade or value.grade_level or value.level
        end,
        isOnDuty = function(player, source)
            local value = getJob(player)
            if value.onDuty ~= nil then return value.onDuty == true end
            if value.onduty ~= nil then return value.onduty == true end
            return availability[tonumber(source)] ~= false
        end,
        onPlayerLoaded = function(handler) return registerEvent(options, events.loaded or 'esx:playerLoaded', handler) end,
        onPlayerUnloaded = function(handler) return registerEvent(options, events.unloaded or 'playerDropped', handler) end,
        onJobChanged = function(handler) return registerEvent(options, events.job or 'esx:setJob', handler) end,
        onDutyChanged = function(handler) return registerEvent(options, events.duty or 'nightshift:esx:dutyChanged', handler) end,
        normalizeEvent = normalizeEvent
    })
    if not adapter then return nil, err end
    adapter._availability = availability
    adapter.setAvailability = function(self, source, value) return Adapter.setAvailability(self, source, value) end
    return adapter
end

function Adapter:setAvailability(source, value)
    source = tonumber(source)
    if not source or source < 1 or math.floor(source) ~= source or type(value) ~= 'boolean' then
        return Result.err('PROVIDER_INVALID', 'source and availability value are required')
    end
    self._availability[source] = value
    return Result.ok({ source = source, available = value, internal = true })
end

NightShift.FrameworkAdapters.esx = Adapter
