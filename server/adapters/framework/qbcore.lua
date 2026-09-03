NightShift = NightShift or {}
NightShift.FrameworkAdapters = NightShift.FrameworkAdapters or {}

local Interface = NightShift.FrameworkInterface
local Types = NightShift.Types.Framework

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function invoke(container, method, ...)
    if type(container) ~= 'table' then return nil end
    local fn = container[method]
    if type(fn) ~= 'function' then return nil end
    local called, value = pcall(fn, container, ...)
    if called and value ~= nil then return value end
    called, value = pcall(fn, ...)
    return called and value or nil
end

local function getCore(options)
    if type(options.core) == 'table' then return options.core end
    if type(options.getCore) == 'function' then
        local ok, value = pcall(options.getCore)
        if ok and type(value) == 'table' then return value end
    end
    local exports = rawget(_G, 'exports')
    if exports ~= nil then
        local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
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

local function playerData(player)
    return type(player) == 'table' and (player.PlayerData or player.playerData or player) or {}
end

local function jobData(player)
    local data = playerData(player)
    return type(data.job) == 'table' and data.job or {}
end

local function rawFromEvent(adapter, source, payload)
    local first = source
    source = tonumber(first) or (type(payload) == 'table' and tonumber(payload.source or payload.playerId or payload.ServerId or payload.serverId))
    if not source and type(first) == 'table' then
        source = tonumber(first.source or first.playerId or first.ServerId or first.serverId)
        if not source and type(first.PlayerData) == 'table' then source = tonumber(first.PlayerData.source or first.PlayerData.playerId) end
    end
    if not source and type(payload) == 'table' and type(payload.PlayerData) == 'table' then
        source = tonumber(payload.PlayerData.source or payload.PlayerData.playerId)
    end
    if not source then source = tonumber(rawget(_G, 'source')) end
    local result = source and adapter:getPlayer(source)
    return source, result and result.ok and result.value or nil
end

local function normalizeEvent(adapter, kind, source, payload)
    local identity
    source, identity = rawFromEvent(adapter, source, payload)
    if not source then return nil end
    if not identity and kind == 'unloaded' and type(adapter.getLastIdentity) == 'function' then
        identity = adapter:getLastIdentity(source, false)
    end
    if kind == 'job' or kind == 'duty' then
        local base = identity
        if not base then return nil end
        local current = copy(base.job or {})
        if type(payload) == 'table' then
            current.name = payload.name or payload.label or current.name
            local grade = payload.grade
            if type(grade) == 'table' then grade = grade.level or grade.id end
            current.grade = grade or payload.level or current.grade
            if payload.onduty ~= nil then current.onDuty = payload.onduty end
            if payload.onDuty ~= nil then current.onDuty = payload.onDuty end
        elseif kind == 'duty' and type(payload) == 'boolean' then
            current.onDuty = payload
        end
        base.job = Types.job(current)
        return base
    end
    if kind == 'unloaded' then
        if identity then
            identity.loaded = false
            return identity
        end
        if type(payload) == 'table' then
            return Types.identity({
                source = source,
                identifier = payload.license or payload.identifier or payload.citizenid,
                characterId = payload.citizenid or payload.characterId,
                characterName = payload.name or payload.characterName,
                job = payload.job,
                loaded = false,
                provider = adapter.name
            })
        end
    end
    return identity
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local core = getCore(options)
    local functions = core and core.Functions or nil
    local events = options.events or {}
    local adapter, err = Interface.new({
        name = 'qbcore',
        available = function() return core ~= nil and type(functions) == 'table' and type(functions.GetPlayer) == 'function' end,
        capabilities = {
            native = true, identity = true, characterId = true, job = true,
            grade = true, duty = true, lifecycle = true, money = true
        },
        getPlayer = function(source)
            if type(options.playerResolver) == 'function' then
                local ok, value = pcall(options.playerResolver, source)
                if ok then return value end
            end
            return invoke(functions, 'GetPlayer', source)
        end,
        isPlayerLoaded = function(source)
            if type(options.isPlayerLoaded) == 'function' then
                local ok, value = pcall(options.isPlayerLoaded, source)
                return ok and value == true
            end
            return invoke(functions, 'GetPlayer', source) ~= nil
        end,
        getIdentifier = function(player)
            local data = playerData(player)
            return data.license or data.license2 or data.steam or data.identifier or data.citizenid
        end,
        getCharacterId = function(player)
            local data = playerData(player)
            return data.citizenid or data.charid or data.characterId
        end,
        getCharacterName = function(player)
            local data = playerData(player)
            if type(data.charinfo) == 'table' then
                local first, last = data.charinfo.firstname or '', data.charinfo.lastname or ''
                local name = (tostring(first) .. ' ' .. tostring(last)):match('^%s*(.-)%s*$')
                if name ~= '' then return name end
            end
            return data.name
        end,
        getJob = jobData,
        getJobName = function(player) return jobData(player).name end,
        getJobGrade = function(player)
            local grade = jobData(player).grade
            return type(grade) == 'table' and (grade.level or grade.id) or grade
        end,
        isOnDuty = function(player)
            local job = jobData(player)
            if job.onduty ~= nil then return job.onduty == true end
            return job.onDuty == true
        end,
        onPlayerLoaded = function(handler) return registerEvent(options, events.loaded or 'QBCore:Server:PlayerLoaded', handler) end,
        onPlayerUnloaded = function(handler) return registerEvent(options, events.unloaded or 'QBCore:Server:PlayerUnload', handler) end,
        onJobChanged = function(handler) return registerEvent(options, events.job or 'QBCore:Server:OnJobUpdate', handler) end,
        onDutyChanged = function(handler) return registerEvent(options, events.duty or 'QBCore:Server:SetDuty', handler) end,
        normalizeEvent = normalizeEvent
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.FrameworkAdapters.qbcore = Adapter
