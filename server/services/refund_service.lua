NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

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
    return Result.err(Codes.REFUND_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function unwrap(result, fallback)
    if type(result) == 'boolean' then return result end
    if type(result) ~= 'table' then return nil, Result.err(fallback, 'refund provider returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function bookingId(value)
    return type(value) == 'table' and value.id or value
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
    local repository = options.repository or options.paymentRepository
    if type(repository) ~= 'table' or type(repository.findByIdempotencyKey) ~= 'function' or type(repository.create) ~= 'function' or type(repository.updateExpectedVersion) ~= 'function' then
        return nil, invalid('refund service requires a payment repository')
    end
    local money = options.money or options.moneyAdapter
    if type(money) ~= 'table' or type(money.add) ~= 'function' then return nil, Result.err(Codes.MONEY_UNAVAILABLE, 'refund service requires a money adapter') end
    local config = copy(options.config or NightShift.CancellationConfig or {})
    if config.enabled == nil then config.enabled = true end
    if type(config.enabled) ~= 'boolean' then return nil, invalid('refund enabled flag must be boolean') end
    local account = config.account
    if not text(account, 32) then return nil, invalid('refund account is required') end
    local percentages = config.percentages or config.policy
    if type(percentages) ~= 'table' then return nil, invalid('refund percentages must be a table') end
    local normalized = {}
    for state, percent in pairs(percentages) do
        if type(state) ~= 'string' or not text(state, 32) then return nil, invalid('refund policy state is invalid') end
        percent = tonumber(percent)
        if not percent or percent < 0 or percent > 100 then return nil, invalid('refund policy percentage is invalid', { state = state }) end
        normalized[state:upper()] = percent
    end
    return setmetatable({
        _repository = repository, _money = money, _bookingService = options.bookingService,
        _deposit = options.depositService, _audit = options.auditService or options.audit,
        _config = { enabled = config.enabled, account = account, percentages = normalized, refundDeposit = config.refundDeposit ~= false }
    }, Service)
end

function Service:_recordAudit(actor, bookingOrId, result)
    if type(self._audit) ~= 'table' or type(self._audit.record) ~= 'function' then return end
    local source = type(actor) == 'table' and actor.source or actor
    source = integer(source, 1)
    local value = type(result) == 'table' and result.value or nil
    local errorResult = type(result) == 'table' and (result.error or result) or nil
    local event = {
        actor = source and { source = source, actorType = 'PLAYER' } or nil,
        action = 'refund.apply',
        target = { type = 'BOOKING', ref = tostring(bookingId(bookingOrId)) },
        result = result,
        resultStatus = type(result) == 'table' and result.ok == true and 'OK' or 'ERROR',
        resultCode = errorResult and errorResult.code or nil,
        reason = errorResult and errorResult.message or nil,
        metadata = {
            status = type(value) == 'table' and value.status or nil,
            amountMinor = type(value) == 'table' and value.amountMinor or nil,
            currency = type(value) == 'table' and value.currency or nil
        }
    }
    pcall(self._audit.record, self._audit, event)
end

function Service:isEnabled() return self._config.enabled == true end

function Service:_supportsIdempotency()
    if type(self._money.getCapabilities) ~= 'function' then return false end
    local ok, capabilities = pcall(self._money.getCapabilities, self._money)
    return ok and type(capabilities) == 'table' and (capabilities.idempotency == true or capabilities.idempotent_replay == true)
end

function Service:_loadBooking(value)
    if type(value) == 'table' then return copy(value) end
    if type(self._bookingService) ~= 'table' or type(self._bookingService.get) ~= 'function' then return nil, invalid('booking service is required for booking ID refund') end
    local ok, result = pcall(self._bookingService.get, self._bookingService, value)
    if not ok or type(result) ~= 'table' or not result.ok then return nil, result or invalid('booking lookup failed') end
    return copy(result.value)
end

function Service:_find(key)
    local result = self._repository:findByIdempotencyKey(key)
    if type(result) ~= 'table' then return nil, invalid('refund lookup returned an invalid result') end
    if result.ok then return result.value end
    if not notFound(result) then return nil, result end
    return nil
end

function Service:calculate(booking)
    if type(booking) ~= 'table' or booking.id == nil then return invalid('refund booking is required') end
    local status = type(booking.status) == 'string' and booking.status:upper() or nil
    local percentage = status and self._config.percentages[status]
    if percentage == nil then return Result.err(Codes.REFUND_NOT_ELIGIBLE, 'booking state has no automatic refund policy', { status = status }) end
    local price = booking.agreedPrice or booking.quote or booking.servicePackage or {}
    local amount = integer(price.amountMinor or price.priceMinor or price.basePriceMinor or price.price, 0, 100000000000)
    local currency = type(price.currency) == 'string' and price.currency:upper() or 'USD'
    if not amount or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return invalid('booking frozen price is invalid') end
    return Result.ok({ bookingId = booking.id, status = status, percentage = percentage, amountMinor = math.floor((amount * percentage / 100) + 0.5), currency = currency })
end

function Service:_refund(first, second, request)
    local actor, bookingOrId = normalizeBookingActor(first, second)
    if not self:isEnabled() then return Result.ok({ bookingId = bookingId(bookingOrId), amountMinor = 0, status = 'DISABLED' }, { disabled = true }) end
    local booking, bookingError = self:_loadBooking(bookingOrId)
    if not booking then return bookingError end
    if not self:_supportsIdempotency() then return Result.err(Codes.REFUND_OPERATION_FAILED, 'money adapter cannot guarantee idempotent refund effects', { bookingId = booking.id }) end
    local calculation = self:calculate(booking)
    if not calculation.ok then return calculation end
    local amount = calculation.value.amountMinor
    if amount == 0 then
        local depositResult
        if self._deposit and self._config.refundDeposit and type(self._deposit.retain) == 'function' then
            depositResult = self._deposit:retain(booking, actor)
            if type(depositResult) == 'table' and not depositResult.ok and depositResult.error and depositResult.error.code ~= Codes.DEPOSIT_NOT_FOUND then
                return Result.err(Codes.REFUND_OPERATION_FAILED, 'cancellation has no refund but deposit retention is pending', { cause = depositResult.error.code })
            end
        end
        return Result.ok(calculation.value, { noEffect = true, deposit = depositResult and depositResult.value })
    end
    local key = ('refund:%s'):format(tostring(booking.id))
    local existing, lookupError = self:_find(key)
    if lookupError then return lookupError end
    if existing and (existing.status == 'SUCCEEDED' or existing.status == 'REFUNDED') then return Result.ok(copy(existing), { idempotent = true }) end
    if existing and existing.status == 'FAILED' then return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund previously failed', { idempotent = true }) end
    local source = type(actor) == 'number' and actor or type(actor) == 'table' and actor.source
    source = integer(source, 1)
    if not source then return invalid('refund source is required') end
    local payment = existing
    if not payment then
        local created = self._repository:create({ bookingId = booking.id, idempotencyKey = key, paymentType = 'REFUND', amountMinor = amount, currency = calculation.value.currency, status = 'PENDING' })
        if type(created) ~= 'table' or not created.ok then
            local raced = self:_find(key)
            if raced then payment = raced else return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund intent could not be persisted', { cause = created and created.error and created.error.code }) end
        else
            payment = { id = created.value and (created.value.insertId or created.value.id), bookingId = booking.id, idempotencyKey = key, paymentType = 'REFUND', amountMinor = amount, currency = calculation.value.currency, status = 'PENDING', version = 1 }
        end
    end
    if payment.amountMinor ~= amount or payment.currency ~= calculation.value.currency then return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund intent fingerprint does not match server policy') end
    local ok, raw = pcall(self._money.add, self._money, source, self._config.account, amount, 'NightShift cancellation refund', key)
    if not ok then raw = Result.err(Codes.REFUND_OPERATION_FAILED, 'refund provider call failed') end
    local provider, providerError = unwrap(raw, Codes.REFUND_OPERATION_FAILED)
    if providerError then
        if payment.id then self._repository:updateExpectedVersion(payment.id, payment.version or 1, { status = 'UNKNOWN' }) end
        return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund result is unknown', { status = 'UNKNOWN', cause = providerError.error and providerError.error.code }) end
    local providerReference = type(provider) == 'table' and provider.providerReference or nil
    local updated = payment.id and self._repository:updateExpectedVersion(payment.id, payment.version or 1, { status = 'SUCCEEDED', providerReference = providerReference }) or Result.ok({ version = 2 })
    if type(updated) ~= 'table' or not updated.ok then return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund result could not be persisted', { status = 'UNKNOWN', moneyApplied = true }) end
    local output = copy(payment)
    output.status, output.version = 'SUCCEEDED', updated.value and updated.value.version or (payment.version or 1) + 1
    output.amountMinor, output.percentage = amount, calculation.value.percentage
    if self._deposit and self._config.refundDeposit and type(self._deposit.refund) == 'function' then
        local depositResult = self._deposit:refund(booking, actor, calculation.value.percentage)
        if type(depositResult) == 'table' and not depositResult.ok and depositResult.error and depositResult.error.code ~= Codes.DEPOSIT_NOT_FOUND then
            return Result.err(Codes.REFUND_OPERATION_FAILED, 'refund payment committed but deposit refund is pending', { paymentCommitted = true, cause = depositResult.error.code }) end
    end
    return Result.ok(output)
end

function Service:refund(first, second, request)
    local actor, bookingOrId = normalizeBookingActor(first, second)
    local result = self:_refund(first, second, request)
    self:_recordAudit(actor, bookingOrId, result)
    return result
end

Service.apply = Service.refund
Service.process = Service.refund
Service.calculateRefund = Service.calculate
NightShift.RefundService = Service
NightShift.Services.Refund = Service
