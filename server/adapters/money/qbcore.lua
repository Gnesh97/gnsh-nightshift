NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Interface = NightShift.MoneyInterface

local function invoke(container, method, ...)
    if type(container) ~= 'table' then return nil end
    local fn = container[method]
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, container, ...)
    if ok and value ~= nil then return value end
    ok, value = pcall(fn, ...)
    return ok and value or nil
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

local function playerFunctions(player)
    if type(player) ~= 'table' then return nil end
    return player.Functions or player.functions or player
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local core = getCore(options)
    local functions = core and core.Functions
    local playerResolver = options.playerResolver
    if type(playerResolver) ~= 'function' and type(functions) == 'table' then
        playerResolver = function(source) return invoke(functions, 'GetPlayer', source) end
    end
    local function player(source)
        if type(playerResolver) ~= 'function' then return nil end
        local ok, value = pcall(playerResolver, source)
        return ok and value or nil
    end
    local function callPlayer(source, method, ...)
        return invoke(playerFunctions(player(source)), method, ...)
    end
    local adapter, err = Interface.new({
        name = 'qbcore',
        available = function() return type(playerResolver) == 'function' end,
        accounts = options.accounts or { cash = true, bank = true },
        capabilities = { native = true, framework = 'qbcore', money = true, atomicTransfer = false },
        has = function(source, account, amount)
            local value = callPlayer(source, 'GetMoney', account)
            return type(value) == 'number' and value >= amount
        end,
        remove = function(source, account, amount, reason)
            local value = callPlayer(source, 'RemoveMoney', account, amount, reason or 'NightShift')
            return value == true
        end,
        add = function(source, account, amount, reason)
            local value = callPlayer(source, 'AddMoney', account, amount, reason or 'NightShift')
            return value == true
        end,
        transfer = options.transfer,
        healthCheck = function() return type(playerResolver) == 'function' end
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.MoneyAdapters.qbcore = Adapter
