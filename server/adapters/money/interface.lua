NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Interface = NightShift.MoneyInterface or {}
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

local function normalizeAccounts(value)
    local source = type(value) == 'table' and value or { cash = true, bank = true }
    local accounts = {}
    local hasNamed = false
    for key, item in pairs(source) do
        if type(key) == 'string' then
            hasNamed = true
            if item == true then accounts[key] = true end
        end
    end
    if hasNamed then return accounts end
    for _, name in ipairs(source) do if type(name) == 'string' and name ~= '' then accounts[name] = true end end
    return accounts
end

local function sourceId(source)
    source = tonumber(source)
    return source and source >= 1 and math.floor(source) == source and source or nil
end

local function amountValue(amount)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge or amount <= 0 or math.floor(amount) ~= amount then return nil end
    return amount
end

local function text(value, max)
    if type(value) ~= 'string' then return nil end
    local result = value:match('^%s*(.-)%s*$')
    if result == '' then return nil end
    return result:sub(1, max or 120)
end

local function idempotencyKey(value)
    return type(value) == 'string' and value:match('^%S+$') ~= nil and #value <= 128 and value or nil
end

local function unwrap(value)
    if type(value) == 'table' and value.ok ~= nil then
        if value.ok == true then return true, value.value end
        return false, value.error or value
    end
    return value ~= nil, value
end

local function succeeded(ok, value)
    if not ok then return false end
    if type(value) == 'table' and value.ok ~= nil then return value.ok == true end
    return value == true
end

local function operationError(code, message, details)
    return Result.err(code, message, details)
end

local function call(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    local ok, value = pcall(fn, ...)
    return ok, value
end

function Interface.new(options)
    options = options or {}
    if type(options) ~= 'table' or type(options.name) ~= 'string' or options.name:match('^%s*$') then
        return nil, NightShift.Errors.create(Codes.MONEY_INVALID_ARGUMENT, 'money adapter name is required')
    end
    if type(options.has) ~= 'function' or type(options.remove) ~= 'function' or type(options.add) ~= 'function' then
        return nil, NightShift.Errors.create(Codes.MONEY_INVALID_ARGUMENT, 'money adapter must expose has, remove, and add')
    end
    local accounts = normalizeAccounts(options.accounts)
    local adapter = setmetatable({
        name = options.name,
        _available = options.available == nil and true or options.available,
        _accounts = accounts,
        _has = options.has,
        _remove = options.remove,
        _add = options.add,
        _transfer = options.transfer,
        _health = options.healthCheck,
        _capabilities = copy(options.capabilities or {})
    }, Adapter)
    adapter._capabilities.provider = adapter.name
    adapter._capabilities.available = adapter._available == true
    adapter._capabilities.atomicTransfer = adapter._capabilities.atomicTransfer == true and type(options.transfer) == 'function'
    return adapter
end

function Interface.isValid(adapter)
    return type(adapter) == 'table' and type(adapter.has) == 'function' and type(adapter.remove) == 'function' and type(adapter.add) == 'function' and type(adapter.getCapabilities) == 'function'
end

function Adapter:isAvailable()
    if type(self._available) == 'function' then
        local ok, value = pcall(self._available)
        return ok and value == true
    end
    return self._available == true
end

function Adapter:_validate(source, account, amount)
    source = sourceId(source)
    if not source then return nil, operationError(Codes.MONEY_INVALID_ARGUMENT, 'source must be a positive integer') end
    account = text(account, 32)
    if not account then return nil, operationError(Codes.MONEY_INVALID_ARGUMENT, 'account must be a non-empty string') end
    if self._accounts[account] ~= true then return nil, operationError(Codes.MONEY_UNSUPPORTED_ACCOUNT, 'account is not supported', { account = account, provider = self.name }) end
    amount = amountValue(amount)
    if not amount then return nil, operationError(Codes.MONEY_INVALID_ARGUMENT, 'amount must be a positive integer') end
    if not self:isAvailable() then return nil, operationError(Codes.MONEY_UNAVAILABLE, 'money provider is unavailable', { provider = self.name }) end
    return { source = source, account = account, amount = amount }
end

function Adapter:has(source, account, amount)
    local input, errorResult = self:_validate(source, account, amount)
    if not input then return errorResult end
    local ok, value = call(self._has, input.source, input.account, input.amount)
    if not ok then return operationError(Codes.MONEY_OPERATION_FAILED, 'money balance check failed', { provider = self.name, account = input.account }) end
    local valid, result = unwrap(value)
    if not valid or type(result) ~= 'boolean' then return operationError(Codes.MONEY_OPERATION_FAILED, 'money provider returned an invalid balance result', { provider = self.name }) end
    return Result.ok(result)
end

function Adapter:remove(source, account, amount, reason, key)
    local input, errorResult = self:_validate(source, account, amount)
    if not input then return errorResult end
    local available = self:has(input.source, input.account, input.amount)
    if not available.ok then return available end
    if available.value ~= true then return operationError(Codes.MONEY_INSUFFICIENT_FUNDS, 'insufficient funds', { source = input.source, account = input.account, amount = input.amount }) end
    local ok, value = call(self._remove, input.source, input.account, input.amount, text(reason, 120), idempotencyKey(key))
    if not succeeded(ok, value) then return operationError(Codes.MONEY_OPERATION_FAILED, 'money removal failed', { provider = self.name, account = input.account, amount = input.amount }) end
    return Result.ok({ source = input.source, account = input.account, amount = input.amount, reason = text(reason, 120) })
end

function Adapter:add(source, account, amount, reason, key)
    local input, errorResult = self:_validate(source, account, amount)
    if not input then return errorResult end
    local ok, value = call(self._add, input.source, input.account, input.amount, text(reason, 120), idempotencyKey(key))
    if not succeeded(ok, value) then return operationError(Codes.MONEY_OPERATION_FAILED, 'money addition failed', { provider = self.name, account = input.account, amount = input.amount }) end
    return Result.ok({ source = input.source, account = input.account, amount = input.amount, reason = text(reason, 120) })
end

function Adapter:transfer(fromSource, toSource, account, amount, reason, key)
    local from = sourceId(fromSource)
    local to = sourceId(toSource)
    if not from or not to or from == to then return operationError(Codes.MONEY_INVALID_ARGUMENT, 'transfer sources must be distinct positive integers') end
    local input, errorResult = self:_validate(from, account, amount)
    if not input then return errorResult end
    local operationKey = idempotencyKey(key)
    if type(self._transfer) == 'function' and self._capabilities.atomicTransfer == true then
        local ok, value = call(self._transfer, from, to, input.account, input.amount, text(reason, 120), operationKey)
        if not succeeded(ok, value) then return operationError(Codes.MONEY_OPERATION_FAILED, 'atomic money transfer failed', { provider = self.name }) end
        return Result.ok({ fromSource = from, toSource = to, account = input.account, amount = input.amount, atomic = true, reason = text(reason, 120) })
    end
    local removed = self:remove(from, input.account, input.amount, reason, operationKey and operationKey .. ':debit' or nil)
    if not removed.ok then return removed end
    local added = self:add(to, input.account, input.amount, reason, operationKey and operationKey .. ':credit' or nil)
    if added.ok then return Result.ok({ fromSource = from, toSource = to, account = input.account, amount = input.amount, atomic = false, reason = text(reason, 120) }) end
    local compensated = self:add(from, input.account, input.amount, 'NightShift transfer compensation', operationKey and operationKey .. ':reverse' or nil)
    return operationError(Codes.MONEY_OPERATION_FAILED, 'money transfer failed', { provider = self.name, atomic = false, compensated = compensated.ok == true })
end

function Adapter:getCapabilities()
    local capabilities = copy(self._capabilities)
    capabilities.available = self:isAvailable()
    capabilities.accounts = copy(self._accounts)
    return capabilities
end

function Adapter:healthCheck()
    if not self:isAvailable() then return operationError(Codes.MONEY_UNAVAILABLE, 'money provider is unavailable', { provider = self.name }) end
    if type(self._health) == 'function' then
        local ok, value = call(self._health)
        if not ok then return operationError(Codes.MONEY_OPERATION_FAILED, 'money provider health check failed', { provider = self.name }) end
        local valid, result = unwrap(value)
        if not valid or result == false then return operationError(Codes.MONEY_OPERATION_FAILED, 'money provider health check failed', { provider = self.name }) end
    end
    return Result.ok({ provider = self.name, available = true, capabilities = self:getCapabilities() })
end

NightShift.MoneyInterface = Interface
NightShift.MoneyInterface.Adapter = Adapter
