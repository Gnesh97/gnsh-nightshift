NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Interface = NightShift.MoneyInterface

local function invoke(container, method, ...)
    if type(container) ~= 'table' then return nil end
    local fn = container[method]
    if type(fn) ~= 'function' then return nil end
    local called, value = pcall(fn, container, ...)
    if called and value ~= nil then return value end
    called, value = pcall(fn, ...)
    return called and value or nil
end

local function invokeStatus(container, method, ...)
    if type(container) ~= 'table' or type(container[method]) ~= 'function' then return false end
    local fn = container[method]
    local called, value = pcall(fn, container, ...)
    if called then return value ~= false end
    called, value = pcall(fn, ...)
    return called and value ~= false
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

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local esx = getESX(options)
    local getPlayerFromId = options.getPlayerFromId or (esx and (esx.GetPlayerFromId or esx.getPlayerFromId))
    local function player(source)
        if type(options.playerResolver) == 'function' then
            local ok, value = pcall(options.playerResolver, source)
            if ok then return value end
        end
        if type(getPlayerFromId) ~= 'function' then return nil end
        local ok, value = pcall(getPlayerFromId, source)
        if ok and value ~= nil then return value end
        local called, value = pcall(getPlayerFromId, esx, source)
        return called and value or nil
    end
    local function accountValue(value)
        if type(value) == 'number' then return value end
        if type(value) == 'table' then return tonumber(value.money or value.balance or value.amount) end
        return nil
    end
    local adapter, err = Interface.new({
        name = 'esx',
        available = function() return type(getPlayerFromId) == 'function' or type(options.playerResolver) == 'function' end,
        accounts = options.accounts or { cash = true, bank = true },
        capabilities = { native = true, framework = 'esx', money = true, atomicTransfer = false },
        has = function(source, account, amount)
            local xPlayer = player(source)
            if not xPlayer then return nil end
            local value
            if account == 'cash' then value = invoke(xPlayer, 'getMoney') or xPlayer.money
            else value = accountValue(invoke(xPlayer, 'getAccount', account)) end
            return type(value) == 'number' and value >= amount
        end,
        remove = function(source, account, amount, reason)
            local xPlayer = player(source)
            if not xPlayer then return false end
            if account == 'cash' then return invokeStatus(xPlayer, 'removeMoney', amount, reason or 'NightShift') end
            return invokeStatus(xPlayer, 'removeAccountMoney', account, amount, reason or 'NightShift')
        end,
        add = function(source, account, amount, reason)
            local xPlayer = player(source)
            if not xPlayer then return false end
            if account == 'cash' then return invokeStatus(xPlayer, 'addMoney', amount, reason or 'NightShift') end
            return invokeStatus(xPlayer, 'addAccountMoney', account, amount, reason or 'NightShift')
        end,
        transfer = options.transfer,
        healthCheck = function() return type(getPlayerFromId) == 'function' or type(options.playerResolver) == 'function' end
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.MoneyAdapters.esx = Adapter
