NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Deposit

local Service = {}
Service.__index = Service

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
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.DEPOSIT_INVALID, message, details)
end

local function timestamp(clock)
    if type(clock) == 'table' and type(clock.timestamp) == 'function' then
        local ok, value = pcall(clock.timestamp, clock)
        if ok and text(value, 64) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function unwrap(result, fallback)
    if type(result) == 'boolean' then return result end
    if type(result) ~= 'table' then return nil, Result.err(fallback, 'money/repository returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function sourceValue(actor)
    if type(actor) == 'number' then actor = { source = actor } end
    if type(actor) ~= 'table' then return nil end
    return integer(actor.source or actor.playerSource, 1)
end

local function isBooking(value)
    return type(value) == 'table' and value.id ~= nil and (value.status ~= nil or value.servicePackage ~= nil or value.agreedPrice ~= nil or value.quote ~= nil)
end

local function normalizeBookingActor(first, second)
    if isBooking(first) and not isBooking(second) then return second, first end
    return first, second
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.depositRepository
    if type(repository) ~= 'table' or type(repository.findByIdempotencyKey) ~= 'function' or type(repository.create) ~= 'function' or type(repository.updateExpectedVersion) ~= 'function' then
        return nil, invalid('deposit service requires a deposit repository')
    end
    local money = options.money or options.moneyAdapter
    if type(money) ~= 'table' or type(money.has) ~= 'function' or type(money.remove) ~= 'function' or type(money.add) ~= 'function' then
        return nil, Result.err(Codes.MONEY_UNAVAILABLE, 'deposit service requires a money adapter')
    end
    local config = copy(options.config or NightShift.DepositConfig or {})
    if config.enabled == nil then config.enabled = false end
    if type(config.enabled) ~= 'boolean' then return nil, invalid('deposit enabled flag must be boolean') end
    local percentage = tonumber(config.percentage or config.percent or 0)
    if not percentage or percentage < 0 or percentage > 100 then return nil, invalid('deposit percentage is invalid') end
    local fixed = config.fixedAmountMinor
    if fixed ~= nil then fixed = integer(fixed, 0, 100000000000); if not fixed then return nil, invalid('fixed deposit amount is invalid') end end
    local account = config.account
    if not text(account, 32) then return nil, invalid('deposit account is required') end
    return setmetatable({ _repository = repository, _money = money, _clock = options.clock, _config = { enabled = config.enabled, percentage = percentage, fixedAmountMinor = fixed, account = account }, _amountResolver = options.amountResolver or options.requiredDepositResolver }, Service)
end

function Service:isEnabled() return self._config.enabled == true end
function Service:configuration() return copy(self._config) end

function Service:_supportsIdempotency()
    if type(self._money.getCapabilities) ~= 'function' then return false end
    local ok, capabilities = pcall(self._money.getCapabilities, self._money)
    return ok and type(capabilities) == 'table' and (capabilities.idempotency == true or capabilities.idempotent_replay == true)
end

function Service:_amount(booking)
    if type(booking) ~= 'table' then return nil, invalid('deposit booking is required') end
    if type(self._amountResolver) == 'function' then
        local ok, value = pcall(self._amountResolver, copy(booking))
        if not ok then return nil, Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit amount resolver failed') end
        value = integer(value, 0, 100000000000)
        if value == nil then return nil, invalid('deposit amount resolver returned an invalid amount') end
        return value
    end
    if self._config.fixedAmountMinor ~= nil then return self._config.fixedAmountMinor end
    local price = booking.agreedPrice or booking.quote or booking.servicePackage or {}
    price = integer(price.amountMinor or price.priceMinor or price.basePriceMinor or price.price, 0, 100000000000)
    if price == nil then return nil, invalid('booking has no server price for deposit calculation') end
    return math.floor((price * self._config.percentage / 100) + 0.5)
end

function Service:_key(booking)
    if type(booking) ~= 'table' or booking.id == nil then return nil end
    return ('deposit:%s'):format(tostring(booking.id))
end

function Service:_find(key)
    local result = self._repository:findByIdempotencyKey(key)
    if type(result) ~= 'table' then return nil, Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit lookup returned an invalid result') end
    if result.ok then return result.value end
    if not notFound(result) then return nil, result end
    return nil
end

function Service:hold(actor, booking, request)
    actor, booking = normalizeBookingActor(actor, booking)
    if not self:isEnabled() then return Result.ok({ bookingId = booking and booking.id, amountMinor = 0, status = 'DISABLED' }, { disabled = true }) end
    if type(booking) ~= 'table' or booking.id == nil then return invalid('deposit booking is required') end
    if not self:_supportsIdempotency() then return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'money adapter cannot guarantee idempotent deposit effects', { bookingId = booking.id }) end
    local key = self:_key(booking)
    local existing, lookupError = self:_find(key)
    if lookupError then return lookupError end
    if existing then return Result.ok(copy(existing), { idempotent = true }) end
    local amount, amountError = self:_amount(booking)
    if amountError then return amountError end
    if amount == 0 then return Result.ok({ bookingId = booking.id, amountMinor = 0, status = 'DISABLED' }, { disabled = true }) end
    local source = sourceValue(actor)
    if not source then return invalid('deposit source is required') end
    local balance = self._money:has(source, self._config.account, amount)
    local balanceValue, balanceError = unwrap(balance, Codes.DEPOSIT_OPERATION_FAILED)
    if balanceError then return balanceError end
    if balanceValue ~= true then return Result.err(Codes.DEPOSIT_INSUFFICIENT_FUNDS, 'deposit funds are insufficient', { bookingId = booking.id, amountMinor = amount }) end
    local removed = self._money:remove(source, self._config.account, amount, 'NightShift deposit hold', key)
    local removedValue, removedError = unwrap(removed, Codes.DEPOSIT_OPERATION_FAILED)
    if removedError then return removedError end
    local deposit, domainError = Domain.new({
        bookingId = booking.id,
        idempotencyKey = key,
        amountMinor = amount,
        currency = (booking.agreedPrice or booking.quote or booking.servicePackage or {}).currency or 'USD',
        status = 'HELD',
        account = self._config.account,
        providerReference = type(removedValue) == 'table' and removedValue.providerReference or nil
    })
    if not deposit then
        local compensation = self._money:add(source, self._config.account, amount, 'NightShift deposit compensation', key .. ':compensate')
        if type(compensation) ~= 'table' or not compensation.ok then
            return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit validation failed and compensation is unknown', { bookingId = booking.id, compensated = false, cause = domainError and domainError.error and domainError.error.code })
        end
        return domainError
    end
    local created = self._repository:create(deposit)
    if type(created) == 'table' and created.ok then
        local value = copy(deposit)
        value.id = created.value and (created.value.insertId or created.value.id)
        return Result.ok(value, { created = true })
    end
    local raced = self:_find(key)
    if raced then
        local compensation = self._money:add(source, self._config.account, amount, 'NightShift deposit race compensation', key .. ':race-compensate')
        if type(compensation) == 'table' and compensation.ok then return Result.ok(copy(raced), { idempotent = true, compensated = true }) end
        return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit race outcome is unknown after duplicate debit', { bookingId = booking.id, compensated = false })
    end
    local compensation = self._money:add(source, self._config.account, amount, 'NightShift deposit persistence compensation', key .. ':persistence-compensate')
    if type(compensation) == 'table' and compensation.ok then
        return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit could not be persisted; debit compensated', { bookingId = booking.id, compensated = true, cause = created and created.error and created.error.code })
    end
    return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit outcome is unknown after persistence failure', { bookingId = booking.id, compensated = false })
end

function Service:_finalize(targetStatus, booking, actor, percentage)
    if not self:isEnabled() then return Result.ok({ bookingId = booking and booking.id, amountMinor = 0, status = 'DISABLED' }, { disabled = true }) end
    if type(booking) ~= 'table' or booking.id == nil then return invalid('deposit booking is required') end
    if not self:_supportsIdempotency() then return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'money adapter cannot guarantee idempotent deposit effects', { bookingId = booking.id }) end
    local key = self:_key(booking)
    local deposit, lookupError = self:_find(key)
    if lookupError then return lookupError end
    if not deposit then return Result.err(Codes.DEPOSIT_NOT_FOUND, 'held deposit was not found', { bookingId = booking.id }) end
    if deposit.status == 'REFUNDED' or deposit.status == 'PARTIALLY_REFUNDED' or deposit.status == 'RETAINED' then return Result.ok(copy(deposit), { idempotent = true }) end
    if deposit.status ~= 'HELD' and deposit.status ~= 'PENDING' and deposit.status ~= 'UNKNOWN' then return Result.err(Codes.DEPOSIT_ALREADY_FINALIZED, 'deposit is not finalizable', { status = deposit.status }) end
    local amount = deposit.amountMinor
    local refundAmount = targetStatus == 'RETAINED' and 0 or math.floor((amount * (percentage == nil and 100 or percentage) / 100) + 0.5)
    local source = sourceValue(actor)
    if refundAmount > 0 then
        if not source then return invalid('deposit refund source is required') end
        local operationKey = ('deposit:%s:%s'):format(tostring(booking.id), targetStatus == 'RETAINED' and 'retain' or 'refund')
        local added = self._money:add(source, deposit.account or self._config.account, refundAmount, 'NightShift deposit refund', operationKey)
        local addedValue, addedError = unwrap(added, Codes.DEPOSIT_OPERATION_FAILED)
        if addedError then return addedError end
        if addedValue == false then return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit refund failed', { bookingId = booking.id }) end
    end
    local status = targetStatus
    if targetStatus == 'REFUNDED' and refundAmount < amount then status = 'PARTIALLY_REFUNDED' end
    local updated = self._repository:updateExpectedVersion(deposit.id, deposit.version, { status = status })
    if type(updated) ~= 'table' or not updated.ok then return Result.err(Codes.DEPOSIT_OPERATION_FAILED, 'deposit status could not be persisted', { bookingId = booking.id, moneyApplied = refundAmount > 0, cause = updated and updated.error and updated.error.code }) end
    local output = copy(deposit)
    output.status = status
    output.refundedAmountMinor = refundAmount
    output.version = updated.value and updated.value.version or deposit.version + 1
    return Result.ok(output, { amountMinor = refundAmount })
end

function Service:release(first, second)
    local actor, booking = normalizeBookingActor(first, second)
    return self:_finalize('REFUNDED', booking, actor, 100)
end

function Service:refund(first, second, percentage)
    local actor, booking = normalizeBookingActor(first, second)
    if type(actor) == 'number' then
        percentage = actor
        actor = nil
    end
    percentage = percentage == nil and 100 or tonumber(percentage)
    if not percentage or percentage < 0 or percentage > 100 then return invalid('deposit refund percentage is invalid') end
    if percentage == 0 then return self:_finalize('RETAINED', booking, actor, 0) end
    return self:_finalize('REFUNDED', booking, actor, percentage)
end

function Service:retain(first, second)
    local actor, booking = normalizeBookingActor(first, second)
    return self:_finalize('RETAINED', booking, actor, 0)
end

Service.capture = Service.hold
Service.createHold = Service.hold
Service.releaseHold = Service.release
Service.refundHold = Service.refund
NightShift.DepositService = Service
NightShift.Services.Deposit = Service
