NightShift = NightShift or {}
NightShift.MoneyAdapters = NightShift.MoneyAdapters or {}

local Interface = NightShift.MoneyInterface
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('^%S+$') ~= nil and #value <= (maxLength or 128)
end

local function fingerprint(fromSource, toSource, account, amount, currency)
    return table.concat({ tostring(fromSource), tostring(toSource), account, tostring(amount), currency or '' }, ':')
end

local Adapter = {}

function Adapter.new(options)
    options = options or {}
    local enabled = options.enabled == true
    local operations = {}
    local adapter, errorResult = Interface.new({
        name = 'development-dry-run',
        available = enabled,
        accounts = options.accounts or { virtual = true },
        capabilities = {
            native = false,
            framework = 'development',
            money = enabled,
            dryRun = true,
            atomicTransfer = true,
            idempotency = true,
            idempotent_replay = true
        },
        has = function() return true end,
        remove = function() return true end,
        add = function() return true end,
        transfer = function() return true end,
        healthCheck = function() return enabled end
    })
    if not adapter then return nil, errorResult end

    adapter.transfer = function(self, fromSource, toSource, account, amount, reason, key, currency)
        local input, validationError = self:_validate(fromSource, account, amount)
        if not input then return validationError end
        toSource = tonumber(toSource)
        if not toSource or toSource < 1 or math.floor(toSource) ~= toSource or toSource == input.source then
            return Result.err(Codes.MONEY_INVALID_ARGUMENT, 'transfer sources must be distinct positive integers')
        end
        if not text(key) then return Result.err(Codes.MONEY_INVALID_ARGUMENT, 'transfer idempotency key is required') end
        currency = type(currency) == 'string' and currency:upper() or 'USD'
        if currency:match('^[A-Z][A-Z][A-Z]$') == nil then
            return Result.err(Codes.MONEY_INVALID_ARGUMENT, 'transfer currency is invalid')
        end
        local expected = fingerprint(input.source, toSource, input.account, input.amount, currency)
        local existing = operations[key]
        if existing then
            if existing.fingerprint ~= expected then
                return Result.err(Codes.MONEY_INVALID_ARGUMENT, 'transfer idempotency key fingerprint does not match')
            end
            return Result.ok(copy(existing.value), { idempotent = true })
        end
        local value = {
            status = 'SUCCEEDED',
            provider = 'development-dry-run',
            providerReference = ('dry-run:%s'):format(key),
            fromSource = input.source,
            toSource = toSource,
            account = input.account,
            amount = input.amount,
            currency = currency,
            reason = type(reason) == 'string' and reason:sub(1, 120) or 'NightShift settlement',
            dryRun = true
        }
        operations[key] = { fingerprint = expected, value = copy(value) }
        return Result.ok(value)
    end

    return adapter
end

NightShift.MoneyAdapters.development = Adapter
NightShift.DevelopmentMoneyAdapter = Adapter
