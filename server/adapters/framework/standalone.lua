NightShift = NightShift or {}
NightShift.FrameworkAdapters = NightShift.FrameworkAdapters or {}

local Interface = NightShift.FrameworkInterface

local function defaultIdentifier(source)
    local getIdentifiers = rawget(_G, 'GetPlayerIdentifiers')
    if type(getIdentifiers) ~= 'function' then return nil end
    local ok, identifiers = pcall(getIdentifiers, source)
    if not ok or type(identifiers) ~= 'table' then return nil end
    local fallback
    for _, identifier in ipairs(identifiers) do
        if type(identifier) == 'string' then
            fallback = fallback or identifier
            if identifier:match('^license') then return identifier end
        end
    end
    return fallback
end

local function defaultName(source)
    local getName = rawget(_G, 'GetPlayerName')
    if type(getName) == 'function' then
        local ok, value = pcall(getName, source)
        if ok and type(value) == 'string' and value ~= '' then return value end
    end
    return 'Player ' .. tostring(source)
end

local function registerEvent(options, name, handler)
    if type(options.eventRegistrar) == 'function' then return options.eventRegistrar(name, handler) end
    local addEventHandler = rawget(_G, 'AddEventHandler')
    if type(addEventHandler) == 'function' then return addEventHandler(name, handler) end
    return false
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local identifierResolver = options.identifierResolver or defaultIdentifier
    local nameResolver = options.nameResolver or defaultName
    local function identifier(source)
        local ok, value = pcall(identifierResolver, source)
        return ok and value or nil
    end
    local function name(source)
        local ok, value = pcall(nameResolver, source)
        return ok and value or nil
    end
    local adapter, err = Interface.new({
        name = 'standalone',
        available = true,
        capabilities = {
            native = false, identity = true, characterId = true, job = false,
            grade = false, duty = false, availability = true, lifecycle = true,
            money = options.moneyEnabled == true
        },
        getPlayer = function(source)
            local value = identifier(source)
            if not value then return nil end
            return { identifier = value, characterId = value, characterName = name(source) }
        end,
        isPlayerLoaded = options.isPlayerLoaded or function(source) return identifier(source) ~= nil end,
        getIdentifier = function(player) return player.identifier end,
        getCharacterId = function(player) return player.characterId or player.identifier end,
        getCharacterName = function(player) return player.characterName or player.identifier end,
        getJob = function() return { name = 'unassigned', grade = 0, onDuty = true } end,
        getJobName = function() return 'unassigned' end,
        getJobGrade = function() return 0 end,
        isOnDuty = function() return true end,
        onPlayerLoaded = function(handler) return registerEvent(options, options.loadedEvent or 'playerJoining', handler) end,
        onPlayerUnloaded = function(handler) return registerEvent(options, options.unloadedEvent or 'playerDropped', handler) end,
        onJobChanged = function(handler) return registerEvent(options, options.jobEvent or 'nightshift:standalone:jobChanged', handler) end,
        onDutyChanged = function(handler) return registerEvent(options, options.dutyEvent or 'nightshift:standalone:dutyChanged', handler) end
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.FrameworkAdapters.standalone = Adapter
