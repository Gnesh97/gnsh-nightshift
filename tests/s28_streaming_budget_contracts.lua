local function check(value, message) assert(value, message) end

local Codes = NightShift.Errors.Codes
local Service = NightShift.NpcStreamingBudgetService
local Result = NightShift.Result
check(type(Service) == 'table' and type(Service.new) == 'function',
    'S28 streaming budget service must be available')

do
    local invalid = Service.new({
        config = { maxActive = 0, maxPerSource = 1, maxPerDistrict = 1, maxTracked = 1, leaseSeconds = 10 }
    })
    check(not invalid, 'zero maxActive must fail closed')
    local invalidScope = Service.new({
        config = { maxActive = 1, maxPerSource = 2, maxPerDistrict = 1, maxTracked = 1, leaseSeconds = 10 }
    })
    check(not invalidScope, 'scope limit above maxActive must fail closed')
end

local now = 100
local budget = assert(Service.new({
    clock = { now = function() return now end },
    config = {
        enabled = true, maxActive = 3, maxPerSource = 2,
        maxPerDistrict = 2, maxTracked = 4, leaseSeconds = 10
    }
}))

local first = budget:request(1, 'npc-worker:one', 'vinewood')
check(first.ok and first.value.leaseToken and first.value.expiresAt == 110,
    'first NPC stream lease should be issued with a bounded expiry')
local duplicate = budget:request(1, 'npc-worker:one', 'vinewood')
check(duplicate.ok and duplicate.value.leaseToken == first.value.leaseToken,
    'duplicate NPC stream lease should be idempotent')
check(duplicate.metadata and duplicate.metadata.idempotent == true,
    'duplicate lease should expose idempotency metadata')
local districtConflict = budget:request(1, 'npc-worker:one', 'vespucci')
check(not districtConflict.ok and districtConflict.error.code == Codes.NPC_STREAMING_BUDGET_CONFLICT,
    'same source and worker cannot move an active lease across districts')

local second = budget:request(1, 'npc-worker:two', 'vinewood')
check(second.ok, 'same source may use its configured burst')
local districtLimited = budget:request(4, 'npc-worker:four', 'vinewood')
check(not districtLimited.ok and districtLimited.error.code == Codes.NPC_STREAMING_DISTRICT_BUDGET_EXHAUSTED,
    'district budget must be enforced')
local sourceLimited = budget:request(1, 'npc-worker:three', 'vespucci')
check(not sourceLimited.ok and sourceLimited.error.code == Codes.NPC_STREAMING_SOURCE_BUDGET_EXHAUSTED,
    'source budget must reject a third active NPC')

local third = budget:request(2, 'npc-worker:three', 'delperro')
check(third.ok, 'another source should receive an independent lease')
local globalLimited = budget:request(3, 'npc-worker:four', 'delperro')
check(not globalLimited.ok and globalLimited.error.code == Codes.NPC_STREAMING_BUDGET_EXHAUSTED,
    'global active budget must be enforced')

local status = assert(budget:status()).value
check(status.active == 3 and status.sourceCounts[1] == 2 and status.districtCounts.vinewood == 2,
    'status must expose bounded aggregate counts')

local released = budget:release(1, 'npc-worker:two')
check(released.ok and released.value.released == true, 'lease release should reclaim one slot')
local releaseAgain = budget:release(1, 'npc-worker:two')
check(releaseAgain.ok and releaseAgain.value.released == false,
    'lease release should be idempotent')
local renewed = budget:renew(1, 'npc-worker:one', 105)
check(renewed.ok and renewed.value.expiresAt == 115, 'active lease should be renewable')

local managedRenewal = assert(Service.new({
    clock = { now = function() return 200 end },
    config = { maxActive = 1, maxPerSource = 1, maxPerDistrict = 1, maxTracked = 1, leaseSeconds = 10 }
}))
check(managedRenewal:request(9, 'npc-worker:managed', 'vinewood').ok,
    'managed renewal fixture should issue a lease')
local sweep = managedRenewal:renewActive(208, function(lease)
    return lease.npcId == 'npc-worker:managed'
end)
check(sweep.ok and sweep.value.renewed == 1,
    'managed renewal should keep active physical NPC leases alive')
local kept = assert(managedRenewal:status(216)).value
check(kept.active == 1 and kept.expired == 0,
    'managed renewal should prevent an active lease from expiring')
local dropped = managedRenewal:renewActive(217, function() return false end)
check(dropped.ok and dropped.value.released == 1 and managedRenewal:status(217).value.active == 0,
    'managed renewal should release leases whose registry binding is gone')

now = 116
local reclaimed = assert(budget:status()).value
check(reclaimed.active == 0 and reclaimed.expired == 2,
    'expired leases should be reclaimed without a global unbounded scan')
local afterExpiry = budget:request(3, 'npc-worker:four', 'delperro')
check(afterExpiry.ok, 'expiry should restore global capacity')
local remaining = budget:request(4, 'npc-worker:five', 'delperro')
check(remaining.ok, 'released capacity should allow another source')

local byToken = budget:releaseByToken(afterExpiry.value.leaseToken)
check(byToken.ok and byToken.value.released == true, 'lease token release should be supported')
local reset = budget:reset()
check(reset.ok and reset.value.removed == 1, 'reset should clear remaining active leases')

local disabled = assert(Service.new({ config = { enabled = false } }))
local bypassed = disabled:request(1, 'npc-worker:one', 'vinewood', 1)
check(bypassed.ok and bypassed.value.bypassed == true and bypassed.value.leaseToken == nil,
    'disabled budget should report an explicit bypass without creating a lease')

local malformed = budget:request('bad', 'npc-worker:one', 'vinewood')
check(not malformed.ok and malformed.error.code == Codes.NPC_STREAMING_BUDGET_INVALID,
    'invalid stream inputs must fail closed')
local forgedDistrict = budget:request(1, 'npc-worker:one', 'vinewood space')
check(not forgedDistrict.ok and forgedDistrict.error.code == Codes.NPC_STREAMING_BUDGET_INVALID,
    'district names must be bounded tokens')

do
    local SpawnService = NightShift.NpcSpawnService
    local Registry = NightShift.NpcEntityRegistry
    local StateBagPolicy = NightShift.StateBagPolicy
    local spawnBudget = assert(Service.new({
        config = { maxActive = 2, maxPerSource = 2, maxPerDistrict = 2, maxTracked = 2, leaseSeconds = 60 },
        clock = { now = function() return 200 end }
    }))
    local bag = {}
    local statePolicy = assert(StateBagPolicy.new({
        setState = function(entity, key, value) bag[entity] = bag[entity] or {}; bag[entity][key] = value; return true end
    }))
    local travelService = {
        get = function()
            return Result.ok({
                travelKey = 'travel:stream',
                bookingId = 'booking:stream',
                profileKey = 'npc-worker:stream',
                origin = { district = 'vinewood' },
                resolvedDestination = { worldTarget = { kind = 'coords', x = 1, y = 2, z = 3 } }
            })
        end,
        shouldSpawn = function() return Result.ok({ ready = true }) end
    }
    local spawn = assert(SpawnService.new({
        travelService = travelService,
        entityRegistry = Registry.new({ clock = { now = function() return 200 end } }),
        modelAllowlist = { ['a_m_m_business_01'] = true },
        modelResolver = function() return 'a_m_m_business_01' end,
        safeSpawnResolver = function() return { kind = 'coords', x = 1, y = 2, z = 3 } end,
        createServerEntity = function() return { entity = 500, networkId = 50 } end,
        streamingBudget = spawnBudget,
        stateBagPolicy = statePolicy
    }))
    local spawned = spawn:request(7, {
        travelKey = 'travel:stream', bookingId = 'booking:stream', profileKey = 'npc-worker:stream'
    })
    check(spawned.ok and spawned.value.streamingLease and spawned.value.stateBag,
        'spawn should return a physical streaming lease and written state bag metadata')
    check(bag[500] and bag[500]['nightshift:generationToken'] == spawned.value.generationToken,
        'state bag generation must be recreated from the server registry binding')
    local forgedConfirm = spawn:confirmSpawn(7, {
        profileKey = 'npc-worker:stream', travelKey = 'travel:stream', bookingId = 'booking:stream',
        generationToken = spawned.value.generationToken, entity = 501, networkId = 51
    })
    check(not forgedConfirm.ok and forgedConfirm.error.code == Codes.ENTITY_GENERATION_MISMATCH,
        'client must not replace a server-owned NPC entity binding')
    local observedConfirm = spawn:confirmSpawn(7, {
        profileKey = 'npc-worker:stream', travelKey = 'travel:stream', bookingId = 'booking:stream',
        generationToken = spawned.value.generationToken, entity = 500, networkId = 50
    })
    check(observedConfirm.ok and observedConfirm.metadata and observedConfirm.metadata.observed == true,
        'matching server-owned NPC confirmation should remain observational')
    local releasedSpawn = spawn:release(7, 'npc-worker:stream')
    check(releasedSpawn.ok and releasedSpawn.value.released == true,
        'spawn service must expose a bounded release path for despawn cleanup')
end

print('NS-282 tests passed: bounded NPC streaming leases, source/district/global limits, expiry, release, and bypass policy')
