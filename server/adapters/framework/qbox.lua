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
    if container == nil then return nil end
    local ok, fn = pcall(function() return container[method] end)
    if not ok then return nil end
    if type(fn) ~= 'function' then return nil end
    local called, value = pcall(fn, container, ...)
    if called and value ~= nil then return value end
    called, value = pcall(fn, ...)
    return called and value or nil
end

local function getCore(options)
    if options.core ~= nil then return options.core end
    if type(options.getCore) == 'function' then
        local ok, value = pcall(options.getCore)
        if ok and value ~= nil then return value end
    end
    local exports = rawget(_G, 'exports')
    if exports ~= nil then
        local ok, value = pcall(function() return exports['qbx_core'] end)
        if ok and value ~= nil then return value end
    end
    return nil
end

local function hasMethod(container, method)
    if container == nil then return false end
    local ok, value = pcall(function() return container[method] end)
    return ok and type(value) == 'function'
end

local function member(container, key)
    if container == nil then return nil end
    local ok, value = pcall(function() return container[key] end)
    return ok and value or nil
end

local function unregisterEvent(options, token)
    if token == nil or token == false then return end
    local remover = options.eventUnregistrar
    if type(remover) == 'function' then
        pcall(remover, token)
        return
    end
    local removeEventHandler = rawget(_G, 'RemoveEventHandler')
    if type(removeEventHandler) == 'function' then pcall(removeEventHandler, token) end
end

local function registerEvent(options, name, handler)
    local names = type(name) == 'table' and name or { name }
    local tokens = {}
    for _, eventName in ipairs(names) do
        if type(eventName) == 'string' and eventName ~= '' then
            local token
            local registrar = options.eventRegistrar
            if type(registrar) ~= 'function' then
                local addEventHandler = rawget(_G, 'AddEventHandler')
                if type(addEventHandler) == 'function' then registrar = addEventHandler end
            end
            if type(registrar) == 'function' then
                local ok, value = pcall(registrar, eventName, handler)
                if not ok then
                    for _, registeredToken in ipairs(tokens) do unregisterEvent(options, registeredToken) end
                    error(value, 0)
                end
                token = value
            end
            if token == nil or token == false then
                for _, registeredToken in ipairs(tokens) do unregisterEvent(options, registeredToken) end
                return false
            end
            tokens[#tokens + 1] = token or false
        end
    end
    if #tokens == 1 then return tokens[1] end
    return tokens
end

local function data(player)
    return type(player) == 'table' and (player.PlayerData or player.playerData or player) or {}
end

local function job(player)
    local value = data(player).job
    return type(value) == 'table' and value or {}
end

local function normalizeEvent(adapter, kind, source, payload)
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
    if not source then return nil end
    local result = adapter:getPlayer(source)
    local identity = result and result.ok and result.value or nil
    if not identity and kind == 'unloaded' and type(adapter.getLastIdentity) == 'function' then
        identity = adapter:getLastIdentity(source, false)
    end
    if (kind == 'job' or kind == 'duty') and identity and type(payload) == 'table' then
        local current = copy(identity.job or {})
        current.name = payload.name or payload.label or current.name
        local grade = payload.grade
        if type(grade) == 'table' then grade = grade.level or grade.id end
        current.grade = grade or payload.level or current.grade
        if payload.onduty ~= nil then current.onDuty = payload.onduty end
        if payload.onDuty ~= nil then current.onDuty = payload.onDuty end
        identity.job = Types.job(current)
    elseif kind == 'duty' and identity and type(payload) == 'boolean' then
        local current = copy(identity.job or {})
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
    local core = getCore(options)
    local functions = member(core, 'Functions')
    local events = options.events or {}
    local adapter, err = Interface.new({
        name = 'qbox',
        available = function()
            return type(options.getPlayer) == 'function' or hasMethod(core, 'GetPlayer') or hasMethod(core, 'getPlayer') or hasMethod(functions, 'GetPlayer')
        end,
        capabilities = {
            native = true, qboxNative = true, identity = true, characterId = true,
            job = true, grade = true, duty = true, lifecycle = true, money = true
        },
        getPlayer = function(source)
            if type(options.getPlayer) == 'function' then
                local ok, value = pcall(options.getPlayer, source)
                if ok then return value end
            end
            local value = invoke(core, 'GetPlayer', source)
            if value ~= nil then return value end
            return invoke(functions, 'GetPlayer', source)
        end,
        isPlayerLoaded = function(source)
            if type(options.isPlayerLoaded) == 'function' then
                local ok, value = pcall(options.isPlayerLoaded, source)
                return ok and value == true
            end
            return (invoke(core, 'GetPlayer', source) or invoke(functions, 'GetPlayer', source)) ~= nil
        end,
        getIdentifier = function(player)
            local value = data(player)
            return value.license or value.license2 or value.identifier or value.citizenid
        end,
        getCharacterId = function(player)
            local value = data(player)
            return value.citizenid or value.characterId or value.charid
        end,
        getCharacterName = function(player)
            local value = data(player)
            if type(value.charinfo) == 'table' then
                local name = (tostring(value.charinfo.firstname or '') .. ' ' .. tostring(value.charinfo.lastname or '')):match('^%s*(.-)%s*$')
                if name ~= '' then return name end
            end
            return value.name
        end,
        getJob = job,
        getJobName = function(player) return job(player).name end,
        getJobGrade = function(player)
            local grade = job(player).grade
            return type(grade) == 'table' and (grade.level or grade.id) or grade
        end,
        isOnDuty = function(player)
            local value = job(player)
            if value.onduty ~= nil then return value.onduty == true end
            return value.onDuty == true
        end,
        onPlayerLoaded = function(handler) return registerEvent(options, events.loaded or 'QBCore:Server:PlayerLoaded', handler) end,
        onPlayerUnloaded = function(handler)
            return registerEvent(options, events.unloaded or {
                'QBCore:Server:OnPlayerUnload',
                'qbx_core:server:playerLoggedOut',
                'playerDropped'
            }, handler)
        end,
        onJobChanged = function(handler) return registerEvent(options, events.job or 'QBCore:Server:OnJobUpdate', handler) end,
        onDutyChanged = function(handler) return registerEvent(options, events.duty or 'QBCore:Server:SetDuty', handler) end,
        normalizeEvent = normalizeEvent
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.FrameworkAdapters.qbox = Adapter
