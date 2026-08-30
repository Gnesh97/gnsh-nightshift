local function s11Check(value, message)
    assert(value, message)
end

do
    local now = 1700000000
    local clock = { now = function() return now end, timestamp = function() return '2023-11-14T22:13:20Z' end }
    local service, serviceError = NightShift.NegotiationService.new({
        clock = clock,
        config = { enabled = true, maxRounds = 3, expirySeconds = 300, minimumOfferFactor = 0.75, maximumOfferFactor = 1.25, counterStepFactor = 0.05, counterPatienceCost = 10 }
    })
    s11Check(service and not serviceError, 'negotiation service should construct')
    local actor = { type = 'PLAYER', ref = 'player:7', source = 7 }
    local created = service:createOffer(actor, {
        id = 'neg-1', opportunityKey = 'customer-opportunity:7:1', customerProfileKey = 'npc-customer:7:1',
        servicePackageId = 'standard', basePriceMinor = 500, currency = 'USD', budgetClass = 3,
        priceClass = 3, demandBand = 'HIGH', demandScore = 65
    })
    s11Check(created.ok and created.value.status == 'OFFERED', 'server should create an NPC offer')
    local offer = created.value
    s11Check(offer.currentOfferMinor >= offer.floorMinor and offer.currentOfferMinor <= offer.ceilingMinor, 'offer must be inside server bounds')
    local countered = service:counter(actor, offer.id, offer.floorMinor, offer.version)
    s11Check(countered.ok and countered.value.status == 'COUNTERED', 'in-bound low counter should receive a customer response')
    local accepted = service:counter(actor, offer.id, countered.value.currentOfferMinor, countered.value.version)
    s11Check(accepted.ok and accepted.value.status == 'ACCEPTED', 'customer should accept its current counter')
    s11Check(accepted.value.acceptedPrice and accepted.value.acceptedPrice.amountMinor == accepted.value.currentOfferMinor, 'accepted price must be frozen')
    local replay = service:counter(actor, offer.id, offer.floorMinor, accepted.value.version)
    s11Check(not replay.ok and replay.error.code == 'NEGOTIATION_CONFLICT', 'terminal negotiation must reject replayed counters')
    local remote = service:get(offer.id)
    s11Check(remote.ok and remote.value.workerIdentity == 'player:7', 'negotiation must retain worker binding')
    local identityActor = { type = 'PLAYER', ref = '21:license:abc123|4:char', source = 7 }
    local identityNegotiation = service:createOffer(identityActor, {
        id = 'neg-identity', opportunityKey = 'customer-opportunity:7:identity', customerProfileKey = 'npc-customer:7:identity',
        servicePackageId = 'standard', basePriceMinor = 500, currency = 'USD', budgetClass = 3,
        priceClass = 3, demandBand = 'NORMAL'
    })
    s11Check(identityNegotiation.ok and identityNegotiation.value.workerIdentity == identityActor.ref, 'canonical identity keys must be accepted by negotiation')
    local expired, expiredError = service:createOffer(actor, {
        id = 'neg-expired', opportunityKey = 'customer-opportunity:7:2', customerProfileKey = 'npc-customer:7:2',
        servicePackageId = 'standard', basePriceMinor = 500, currency = 'USD', budgetClass = 3, priceClass = 3,
        expiresAt = now + 1
    })
    s11Check(expired and not expiredError, 'second offer should construct')
    now = now + 2
    local expiryResult = service:get(expired.value.id)
    s11Check(expiryResult.ok and expiryResult.value.status == 'EXPIRED', 'expired negotiation must be server-closed')
end

print('NS-110 tests passed: bounded deterministic offers, counters, frozen acceptance, ownership, replay, and expiry')
