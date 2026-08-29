NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Interface = NightShift.MoneyInterface

local function invoke(container, method, ...)
    if container == nil then return nil end
    local ok, fn = pcall(function() return container[method] end)
    if not ok then return nil end
    if type(fn) ~= 'function' then return nil end
    ok, value = pcall(fn, container, ...)
    if ok and value ~= nil then return value end
    ok, value = pcall(fn, ...)
    return ok and value or nil
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

local function member(container, key)
    if container == nil then return nil end
    local ok, value = pcall(function() return container[key] end)
    return ok and value or nil
end

local function callSource(fn, source, account, amount, reason, core)
    if type(fn) ~= 'function' then return nil end
    local ok, value = pcall(fn, source, account, amount, reason)
    if ok and value ~= nil then return value end
    ok, value = pcall(fn, core, source, account, amount, reason)
    return ok and value or nil
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local core = getCore(options)
    local getMoney = options.getMoney or member(core, 'GetMoney') or member(core, 'getMoney')
    local removeMoney = options.removeMoney or member(core, 'RemoveMoney') or member(core, 'removeMoney')
    local addMoney = options.addMoney or member(core, 'AddMoney') or member(core, 'addMoney')
    local adapter, err = Interface.new({
        name = 'qbox',
        available = function() return type(getMoney) == 'function' and type(removeMoney) == 'function' and type(addMoney) == 'function' end,
        accounts = options.accounts or { cash = true, bank = true },
        capabilities = { native = true, qboxNative = true, framework = 'qbox', money = true, atomicTransfer = false },
        has = function(source, account, amount)
            local value = callSource(getMoney, source, account, nil, nil, core)
            return type(value) == 'number' and value >= amount
        end,
        remove = function(source, account, amount, reason)
            return callSource(removeMoney, source, account, amount, reason or 'NightShift', core) == true
        end,
        add = function(source, account, amount, reason)
            return callSource(addMoney, source, account, amount, reason or 'NightShift', core) == true
        end,
        transfer = options.transfer,
        healthCheck = function() return type(getMoney) == 'function' and type(removeMoney) == 'function' and type(addMoney) == 'function' end
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.MoneyAdapters.qbox = Adapter
