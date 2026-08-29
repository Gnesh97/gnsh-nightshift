NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Interface = NightShift.MoneyInterface

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local ledger = type(options.ledger) == 'table' and options.ledger or {}
    local enabled = options.enabled == true
    local adapter, err = Interface.new({
        name = 'standalone',
        available = function()
            return enabled and type(ledger.has) == 'function' and type(ledger.remove) == 'function' and type(ledger.add) == 'function'
        end,
        accounts = options.accounts or { cash = true, bank = true },
        capabilities = { native = false, framework = 'standalone', money = enabled, atomicTransfer = false },
        has = function(source, account, amount)
            return ledger.has(source, account, amount)
        end,
        remove = function(source, account, amount, reason)
            return ledger.remove(source, account, amount, reason or 'NightShift')
        end,
        add = function(source, account, amount, reason)
            return ledger.add(source, account, amount, reason or 'NightShift')
        end,
        transfer = ledger.transfer,
        healthCheck = function()
            return enabled and type(ledger.has) == 'function' and type(ledger.remove) == 'function' and type(ledger.add) == 'function'
        end
    })
    if not adapter then return nil, err end
    return adapter
end

NightShift.MoneyAdapters.standalone = Adapter
