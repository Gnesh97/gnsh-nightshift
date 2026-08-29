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
    return Result.err(Codes.SETTLEMENT_INVALID, message, details)
end

local function notFound(result)
    return type(result) == 'table' and result.ok == false and result.error and result.error.code == Codes.REPOSITORY_NOT_FOUND
end

local function unwrap(result, fallback)
    if type(result) == 'boolean' then return result end
    if type(result) ~= 'table' then return nil, Result.err(fallback, 'financial provider returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value end
    return result
end

local function successful(value)
    if value == true then return true end
    if type(value) == 'table' and value.status then return value.status == 'SUCCEEDED' or value.status == 'COMMITTED' or value.status == 'SUCCESS' end
    return value ~= false and value ~= nil
end

local function bookingId(value)
    if type(value) == 'table' then return value.id end
    return value
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
        return nil, invalid('settlement service requires a payment repository')
    end
    local money = options.money or options.moneyAdapter
    if type(money) ~= 'table' then return nil, Result.err(Codes.MONEY_UNAVAILABLE, 'settlement service requires a money adapter') end
    local config = copy(options.config or NightShift.SettlementConfig or {})
    if config.enabled == nil then config.enabled = false end
    if type(config.enabled) ~= 'boolean' then return nil, invalid('settlement enabled flag must be boolean') end
    local account = config.account
    if not text(account, 32) then return nil, invalid('settlement account is required') end
    return setmetatable({
        _repository = repository,
        _money = money,
        _bookingService = options.bookingService,
        _deposit = options.depositService,
        _clock = options.clock,
        _config = { enabled = config.enabled, account = account },
        _payerResolver = options.payerResolver or options.payerSourceResolver,
        _payeeResolver = options.payeeResolver or options.payeeSourceResolver,
        _commissionHook = options.commissionHook or options.commissionResolver,
        _settled = {}
    }, Service)
end

function Service:isEnabled() return self._config.enabled == true end

function Service:_loadBooking(value)
    if type(value) == 'table' then return copy(value) end
    if type(self._bookingService) ~= 'table' then return nil, invalid('booking service is required for booking ID settlement') end
    local getter = self._bookingService.get or self._bookingService.find
    if type(getter) ~= 'function' then return nil, invalid('booking service cannot load a booking') end
    local ok, result = pcall(getter, self._bookingService, value)
    if not ok or type(result) ~= 'table' or not result.ok then return nil, result or invalid('booking lookup failed') end
    return copy(result.value)
end

function Service:_source(resolver, booking, actor, request, fallback)
    if type(resolver) == 'function' then
        local ok, value = pcall(resolver, copy(booking), copy(actor), copy(request or {}))
        if ok then value = integer(value, 1); if value then return value end end
    end
    return integer(fallback, 1)
end

function Service:_find(key)
    local result = self._repository:findByIdempotencyKey(key)
    if type(result) ~= 'table' then return nil, invalid('settlement lookup returned an invalid result') end
    if result.ok then return result.value end
    if not notFound(result) then return nil, result end
    return nil
end

function Service:_capabilities()
    if type(self._money.getCapabilities) ~= 'function' then return { atomicTransfer = false } end
    local ok, value = pcall(self._money.getCapabilities, self._money)
    return ok and type(value) == 'table' and value or {}
end

function Service:_transfer(booking, actor, request, key, amount, currency)
    local payer = self:_source(self._payerResolver, booking, actor, request, type(actor) == 'table' and actor.source or nil)
    local payeeFallback = type(request) == 'table' and request.payeeSource or booking.workerSource
    local payee = self:_source(self._payeeResolver, booking, actor, request, payeeFallback)
    if not payer or not payee or payer == payee then return nil, Result.err(Codes.SETTLEMENT_NOT_READY, 'settlement payer and payee sources are required') end
    local capabilities = self:_capabilities()
    if type(self._money.transfer) == 'function' and capabilities.atomicTransfer == true and (capabilities.idempotency == true or capabilities.idempotent_replay == true) then
        local ok, value = pcall(self._money.transfer, self._money, payer, payee, self._config.account, amount, 'NightShift settlement', key, currency)
        if not ok then return nil, Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'atomic settlement transfer failed', { status = 'UNKNOWN' }) end
        local normalized, errorResult = unwrap(value, Codes.SETTLEMENT_OPERATION_FAILED)
        if errorResult then return nil, errorResult end
        if not successful(normalized) then
            local providerStatus = type(normalized) == 'table' and type(normalized.status) == 'string' and normalized.status:upper() or nil
            local status = 'UNKNOWN'
            if providerStatus == 'DECLINED' or providerStatus == 'FAILED' then status = 'DECLINED' end
            return nil, Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'atomic settlement transfer was not successful', { status = status })
        end
        return { mode = 'ATOMIC', payerSource = payer, payeeSource = payee, provider = normalized }
    end
    if type(self._money.debit) ~= 'function' or type(self._money.credit) ~= 'function' or type(self._money.reverse) ~= 'function' then
        return nil, Result.err(Codes.SETTLEMENT_NOT_READY, 'money adapter has no safe atomic or compensatable split-leg capability')
    end
    return nil, Result.err(Codes.SETTLEMENT_NOT_READY, 'split-leg settlement requires explicit durable leg support')
end

function Service:settle(first, second, request)
    local actor, bookingOrId = normalizeBookingActor(first, second)
    if not self:isEnabled() then return Result.err(Codes.SETTLEMENT_NOT_READY, 'settlement is disabled') end
    if type(self._bookingService) ~= 'table' or type(self._bookingService.settle) ~= 'function' then
        return Result.err(Codes.SETTLEMENT_NOT_READY, 'booking service is required for canonical settlement transition')
    end
    local booking, bookingError = self:_loadBooking(bookingOrId)
    if not booking then return bookingError end
    if booking.status == 'SETTLED' then
        local existing = self:_find(('settlement:%s'):format(tostring(booking.id)))
        if existing then return Result.ok({ booking = booking, payment = existing, status = 'SETTLED' }, { idempotent = true }) end
        return Result.err(Codes.SETTLEMENT_ALREADY_PROCESSED, 'booking is already settled') end
    if booking.status ~= 'COMPLETED' then return Result.err(Codes.SETTLEMENT_NOT_READY, 'only completed bookings can be settled', { status = booking.status }) end
    local price = booking.agreedPrice
    if type(price) ~= 'table' then return Result.err(Codes.SETTLEMENT_NOT_READY, 'booking has no frozen agreed price') end
    local amount = integer(price.amountMinor, 1, 100000000000)
    local currency = type(price.currency) == 'string' and price.currency:upper() or nil
    if not amount or not currency or currency:match('^[A-Z][A-Z][A-Z]$') == nil then return invalid('booking agreed price is invalid') end
    local key = ('settlement:%s'):format(tostring(booking.id))
    local existing, lookupError = self:_find(key)
    if lookupError then return lookupError end
    if existing and (existing.status == 'DECLINED' or existing.status == 'FAILED') then return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement previously failed', { status = existing.status, idempotent = true }) end
    if existing and existing.status == 'SUCCEEDED' then
        if self._settled[tostring(booking.id)] or booking.status == 'SETTLED' then
            return Result.ok({ booking = booking, payment = existing, status = 'SETTLED' }, { idempotent = true })
        end
        local transitioned = self._bookingService and type(self._bookingService.settle) == 'function' and self._bookingService:settle(actor, booking.id, booking.version) or Result.ok(booking)
        if type(transitioned) ~= 'table' or not transitioned.ok then return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'payment succeeded but booking transition is pending', { paymentCommitted = true, cause = transitioned and transitioned.error and transitioned.error.code }) end
        self._settled[tostring(booking.id)] = true
        return Result.ok({ booking = transitioned.value or transitioned, payment = existing, status = 'SETTLED' }, { idempotent = true }) end
    local payment = existing
    if not payment then
        local created = self._repository:create({ bookingId = booking.id, idempotencyKey = key, paymentType = 'SETTLEMENT', amountMinor = amount, currency = currency, status = 'PENDING' })
        if type(created) ~= 'table' or not created.ok then
            local raced = self:_find(key)
            if raced then payment = raced else return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement intent could not be persisted', { cause = created and created.error and created.error.code }) end
        else
            payment = { id = created.value and (created.value.insertId or created.value.id), bookingId = booking.id, idempotencyKey = key, paymentType = 'SETTLEMENT', amountMinor = amount, currency = currency, status = 'PENDING', version = 1 }
        end
    end
    if payment.amountMinor ~= amount or payment.currency ~= currency then return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement intent fingerprint does not match booking', { status = 'UNKNOWN' }) end
    local transfer, transferError = self:_transfer(booking, actor, request, key .. ':transfer', amount, currency)
    if not transfer then
        local failureStatus = transferError and transferError.details and transferError.details.status == 'DECLINED' and 'DECLINED' or 'UNKNOWN'
        if payment.id then self._repository:updateExpectedVersion(payment.id, payment.version or 1, { status = failureStatus }) end
        return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement financial operation did not commit', { status = failureStatus, cause = transferError and transferError.error and transferError.error.code }) end
    local providerReference = type(transfer.provider) == 'table' and transfer.provider.providerReference or nil
    local updated = payment.id and self._repository:updateExpectedVersion(payment.id, payment.version or 1, { status = 'SUCCEEDED', providerReference = providerReference }) or Result.ok({ version = 2 })
    if type(updated) ~= 'table' or not updated.ok then return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement payment result could not be persisted', { status = 'UNKNOWN', paymentCommitted = true }) end
    local committed = copy(payment)
    committed.status, committed.mode = 'SUCCEEDED', transfer.mode
    committed.version = updated.value and updated.value.version or (payment.version or 1) + 1
    if self._deposit and type(self._deposit.retain) == 'function' then
        local finalized = self._deposit:retain(booking, actor)
        if type(finalized) ~= 'table' or not finalized.ok and finalized.error and finalized.error.code ~= Codes.DEPOSIT_NOT_FOUND then
            return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement payment committed but deposit finalization is pending', { paymentCommitted = true, cause = finalized and finalized.error and finalized.error.code }) end
    end
    local commission
    if type(self._commissionHook) == 'function' then
        local ok, value = pcall(self._commissionHook, copy(booking), copy(committed), copy(request or {}))
        if not ok then
            return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement commission hook failed', { paymentCommitted = true })
        end
        if value == false or (type(value) == 'table' and value.ok == false) then
            return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement commission hook rejected the payment', { paymentCommitted = true })
        end
        commission = type(value) == 'table' and value.value or value
    end
    local transitioned = self._bookingService and type(self._bookingService.settle) == 'function' and self._bookingService:settle(actor, booking.id, booking.version) or Result.ok(copy(booking))
    if type(transitioned) ~= 'table' or not transitioned.ok then return Result.err(Codes.SETTLEMENT_OPERATION_FAILED, 'settlement payment committed but booking transition is pending', { paymentCommitted = true, cause = transitioned and transitioned.error and transitioned.error.code }) end
    self._settled[tostring(booking.id)] = true
    return Result.ok({ booking = transitioned.value or transitioned, payment = committed, commission = commission, status = 'SETTLED' })
end

Service.process = Service.settle
Service.execute = Service.settle
NightShift.SettlementService = Service
NightShift.Services.Settlement = Service
