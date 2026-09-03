local function check(value, message) assert(value, message) end
local Result = NightShift.Result

local payment
local repository = {}
function repository:findByIdempotencyKey()
    if not payment then return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'payment missing') end
    return Result.ok(payment)
end
function repository:create(value)
    payment = NightShift.Validators.copy(value)
    payment.id, payment.version = 1, 1
    return Result.ok({ id = 1, insertId = 1 })
end
function repository:updateExpectedVersion(id, version, changes)
    if not payment or id ~= payment.id or version ~= payment.version then
        return Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'payment version mismatch')
    end
    for key, value in pairs(changes) do payment[key] = NightShift.Validators.copy(value) end
    payment.version = version + 1
    return Result.ok({ id = id, version = payment.version })
end

local booking = {
    id = 77, version = 1, status = 'COMPLETED', workerSource = 20,
    agreedPrice = { amountMinor = 1000, currency = 'USD' }
}
local bookingService = {
    settle = function(_, actor, id, version)
        return Result.ok({ id = id, version = version + 1, status = 'SETTLED', actor = actor })
    end
}
local money = {
    getCapabilities = function() return { atomicTransfer = true, idempotency = true } end,
    transfer = function(_, payer, payee, account, amount, _, key)
        check(payer == 10 and payee == 20 and account == 'virtual' and amount == 1000
            and key == 'settlement:77:transfer', 'settlement transfer must remain server-authoritative')
        return Result.ok({ status = 'SUCCEEDED', providerReference = 'tx-77' })
    end
}
local service = assert(NightShift.SettlementService.new({
    repository = repository, money = money, bookingService = booking,
    config = { enabled = true, account = 'virtual' },
    payerResolver = function() return 10 end,
    payeeResolver = function() return 20 end,
    commissionSplitResolver = function()
        return { allocations = {
            { role = 'WORKER', percentage = 50 },
            { role = 'AGENCY', percentage = 30, ref = 'downtown' },
            { role = 'VENUE', amountMinor = 100, ref = 'club-1' }
        } }
    end
}))
service._bookingService = bookingService
local request = {}
local first = service:settle({ source = 10 }, booking, request)
check(first.ok and first.value.payment.commissionSnapshot, 'settlement should persist a commission snapshot')
local snapshot = first.value.payment.commissionSnapshot
check(snapshot.amountMinor == 1000 and snapshot.allocations[1].amountMinor == 600
    and snapshot.allocations[2].amountMinor == 300 and snapshot.allocations[3].amountMinor == 100,
    'commission split should allocate deterministic worker remainder')
local retry = service:settle({ source = 10 }, booking, {
    commissionSplit = { allocations = { { role = 'WORKER', percentage = 100 } } }
})
check(retry.ok and retry.metadata.idempotent and retry.value.payment.commissionSnapshot.allocations[2].amountMinor == 300,
    'retry must reuse the first immutable commission snapshot')

print('NS-233 tests passed: immutable worker/agency/venue split, persistence, and idempotent retry')
