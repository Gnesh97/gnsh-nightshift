local function check(value, message)
    assert(value, message)
end

local Codes = NightShift.Errors.Codes
local TravelPlan = NightShift.Domain.TravelPlan
local TravelService = NightShift.NpcTravelService
local EntityRegistry = NightShift.NpcEntityRegistry
local ClientEntityRegistry = NightShift.ClientNpcEntityRegistry
local SpawnService = NightShift.NpcSpawnService
local ClientSpawn = NightShift.ClientNpcSpawn
local Navigation = NightShift.ClientNpcNavigation
local ArrivalService = NightShift.NpcArrivalService
local Despawn = NightShift.ClientNpcDespawn

check(type(TravelPlan) == 'table' and type(TravelPlan.new) == 'function', 'S09 travel plan domain must be available')
check(type(TravelService) == 'table' and type(TravelService.new) == 'function', 'S09 travel service must be available')
check(type(EntityRegistry) == 'table' and type(EntityRegistry.new) == 'function', 'S09 server entity registry must be available')
check(type(ClientEntityRegistry) == 'table' and type(ClientEntityRegistry.new) == 'function', 'S09 client entity registry must be available')
check(type(SpawnService) == 'table' and type(SpawnService.new) == 'function', 'S09 server spawn service must be available')
check(type(ClientSpawn) == 'table' and type(ClientSpawn.new) == 'function', 'S09 client spawn controller must be available')
check(type(Navigation) == 'table' and type(Navigation.new) == 'function', 'S09 navigation controller must be available')
check(type(ArrivalService) == 'table' and type(ArrivalService.new) == 'function', 'S09 arrival service must be available')
check(type(Despawn) == 'table' and type(Despawn.new) == 'function', 'S09 despawn controller must be available')

local now = 1000
local clock = { now = function() return now end }
local destination = {
    locationType = 'CONFIG_LOCATION',
    locationRef = 'configured_default'
}

do
    local plan, planError = TravelPlan.new({
        travelKey = 'travel:booking:one:npc-worker:one',
        bookingId = 'booking:one',
        workerKey = 'npc-worker:one',
        profileKey = 'npc-worker:one',
        origin = { district = 'vinewood', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default' },
        destination = destination,
        mode = 'VEHICLE',
        etaSeconds = 60,
        startedAt = 1000,
        expectedArrivalAt = 1060,
        progress = 0.1,
        spawnThreshold = 0.5
    })
    check(plan and not planError, 'travel plan should normalize without a world entity')
    check(plan.state == 'TRAVELLING' and plan.progress == 0.1, 'travel plan should track logical progress')
    check(plan.worldEntity == nil and plan.entity == nil, 'travel plan must not require a ped')
    check(not plan:isSpawnReady(), 'travel plan should remain below spawn threshold')
    local advanced = plan:advance(0.6, 1030)
    check(advanced.ok and advanced.value:isSpawnReady(), 'travel plan should become spawn-ready by progress')
    local recovered = advanced.value:markRecovery('STUCK', 1040)
    check(recovered.ok and recovered.value.recoveryState == 'STUCK' and recovered.value.state == 'RECOVERING', 'travel recovery state should be explicit')
    local snapshot = TravelPlan.copy(recovered.value)
    snapshot.origin.district = 'edited'
    check(recovered.value.origin.district == 'vinewood', 'travel plan copies must be immutable')

    local invalid, invalidError = TravelPlan.new({
        travelKey = 'travel:invalid',
        bookingId = 'booking:invalid',
        workerKey = 'npc-worker:invalid',
        profileKey = 'npc-worker:invalid',
        origin = { district = 'vinewood' },
        destination = { coords = { x = 1, y = 2, z = 3 } },
        mode = 'WALK',
        etaSeconds = 10
    })
    check(not invalid and invalidError.error.code == Codes.TRAVEL_INVALID, 'arbitrary destination coordinates must be rejected')
end

local locationService = {
    resolve = function(_, source, request)
        check(source == 42 and request.locationType == 'CONFIG_LOCATION', 'travel resolver should receive server source and typed location')
        return NightShift.Result.ok({
            locationType = request.locationType,
            locationRef = request.locationRef,
            worldTarget = { kind = 'coords', x = 100.0, y = 200.0, z = 30.0, heading = 90.0 },
            route = { reachable = true, distance = 25.0 }
        })
    end
}

local travelService = assert(TravelService.new({
    locationService = locationService,
    clock = clock,
    config = { spawnThreshold = 0.5 },
    etaEstimator = function() return 60 end
}))

local created = travelService:create(42, {
    bookingId = 'booking:one',
    workerKey = 'npc-worker:one',
    profileKey = 'npc-worker:one',
    origin = { district = 'vinewood', locationType = 'CONFIG_LOCATION', locationRef = 'configured_default' },
    destination = destination,
    mode = 'VEHICLE'
})
check(created.ok, 'travel service should create a logical plan')
local travel = created.value
check(travel.travelKey and travel.expectedArrivalAt == 1060 and travel.state == 'TRAVELLING', 'travel service should compute a deterministic ETA')
check(travel.resolvedDestination and travel.resolvedDestination.worldTarget.x == 100.0, 'travel plan should retain server-resolved destination metadata')
check(travel.entity == nil, 'travel creation must not require entity presence')

local progress = travelService:updateProgress(travel.travelKey, 0.7, 1040)
check(progress.ok and progress.value:isSpawnReady(), 'travel progress update should be monotonic and spawn-aware')
local conflict = travelService:create(42, {
    travelKey = travel.travelKey,
    bookingId = 'booking:other',
    workerKey = 'npc-worker:one',
    profileKey = 'npc-worker:one',
    origin = { district = 'vinewood' },
    destination = destination,
    mode = 'WALK'
})
check(not conflict.ok and conflict.error.code == Codes.TRAVEL_CONFLICT, 'travel key reuse with another booking must fail closed')

local serverRegistry = assert(EntityRegistry.new({ clock = clock }))
local registered = serverRegistry:register('npc-worker:one', {
    bookingId = 'booking:one',
    travelKey = travel.travelKey,
    owner = 42,
    entity = 900,
    networkId = 77
})
check(registered.ok and registered.value.generationToken, 'server registry should issue a generation token')
local generationToken = registered.value.generationToken
local ownerChanged = serverRegistry:updateOwner('npc-worker:one', generationToken, 43)
check(ownerChanged.ok and ownerChanged.value.owner == 43, 'entity ownership changes should be tolerated')
local deleted = serverRegistry:markDeleted('npc-worker:one', generationToken)
check(deleted.ok and deleted.value.entity == nil and deleted.value.bookingId == 'booking:one', 'ped deletion must preserve logical booking mapping')
check(serverRegistry:validate('npc-worker:one', generationToken, { travelKey = travel.travelKey, bookingId = 'booking:one' }).ok, 'deleted physical entity should remain logically validateable')
local replacement = serverRegistry:register('npc-worker:one', {
    bookingId = 'booking:one', travelKey = travel.travelKey, owner = 42, entity = 901, networkId = 78
})
check(replacement.ok and replacement.value.generation > registered.value.generation, 'deleted entities should be replaceable with a fresh generation')

local spawnRegistry = assert(EntityRegistry.new({ clock = clock }))
local spawnService = assert(SpawnService.new({
    travelService = travelService,
    entityRegistry = spawnRegistry,
    clock = clock,
    modelAllowlist = { ['a_m_m_business_01'] = true },
    modelResolver = function() return 'a_m_m_business_01' end,
    safeSpawnResolver = function(source, plan)
        check(source == 42 and plan.travelKey == travel.travelKey, 'spawn resolver must use trusted travel context')
        return { kind = 'coords', x = 101.0, y = 201.0, z = 30.0, heading = 90.0 }
    end
}))

local forgedSpawn = spawnService:request(42, {
    travelKey = travel.travelKey,
    bookingId = 'booking:one',
    profileKey = 'npc-worker:one',
    model = 'forged_model',
    coords = { x = 9999, y = 9999, z = 9999 }
})
check(not forgedSpawn.ok and forgedSpawn.error.code == Codes.NPC_SPAWN_UNAUTHORIZED, 'client model and coordinates must never control spawn')

local authorization = assert(spawnService:request(42, {
    travelKey = travel.travelKey,
    bookingId = 'booking:one',
    profileKey = 'npc-worker:one'
})).value
check(authorization.serverOwned and authorization.model == 'a_m_m_business_01', 'spawn authorization must be server-owned and allowlisted')
check(authorization.candidate.x == 101.0 and authorization.entity == nil, 'spawn authorization should contain only a safe candidate')

local clientEntityDeleted = false
local clientRegistry = assert(ClientEntityRegistry.new({
    entityExists = function() return not clientEntityDeleted end
}))
local createCalls = 0
local clientSpawn = assert(ClientSpawn.new({
    registry = clientRegistry,
    modelAllowlist = { ['a_m_m_business_01'] = true },
    loadModel = function(model) check(model == 'a_m_m_business_01', 'client must use server model'); return true end,
    createPed = function(model, candidate)
        createCalls = createCalls + 1
        check(model == 'a_m_m_business_01' and candidate.x == 101.0, 'client must use server candidate')
        return { entity = 701, networkId = 88 }
    end
}))
local spawned = clientSpawn:spawn(authorization)
check(spawned.ok and createCalls == 1, 'client should create one controlled entity')
local clientBinding = assert(clientRegistry:get('npc-worker:one')).value
check(clientBinding.bookingId == nil and clientBinding.travelKey == nil, 'client entity registry must not become a business-state store')
local forgedAuthorization = clientSpawn:spawn({
    serverOwned = true,
    profileKey = authorization.profileKey,
    generationToken = authorization.generationToken,
    model = 'forged_model',
    candidate = authorization.candidate
})
check(not forgedAuthorization.ok and forgedAuthorization.error.code == Codes.NPC_SPAWN_MODEL_NOT_ALLOWED, 'client must reject forged model metadata')

local serverConfirmed = spawnService:confirmSpawn(42, {
    profileKey = authorization.profileKey,
    travelKey = authorization.travelKey,
    bookingId = authorization.bookingId,
    generationToken = authorization.generationToken,
    entity = 701,
    networkId = 88
})
check(serverConfirmed.ok and serverConfirmed.value.entity == 701, 'server should bind the spawned entity with its generation token')

local distance = 20
local playerDistance = 0
local arrivalEvents, recoveryEvents = 0, {}
local navigation = assert(Navigation.new({
    clock = clock,
    registry = clientRegistry,
    arrivalRadius = 4,
    navigationTimeout = 120,
    stuckTimeout = 10,
    playerAwayDistance = 50,
    entityExists = function(entity) return entity == 701 end,
    distance = function() return distance end,
    playerDistance = function() return playerDistance end,
    moveTo = function() return true end,
    onArrival = function(context) arrivalEvents = arrivalEvents + 1; check(context.generationToken == authorization.generationToken, 'arrival event should retain generation context') end,
    onRecovery = function(reason) recoveryEvents[#recoveryEvents + 1] = reason end
}))
local navigationStart = navigation:start({
    serverOwned = true,
    profileKey = authorization.profileKey,
    generationToken = authorization.generationToken,
    entity = 701,
    target = authorization.candidate,
    travelKey = authorization.travelKey,
    bookingId = authorization.bookingId
})
check(navigationStart.ok, 'navigation should start from a server-owned context')
now = 1010
check(navigation:tick().ok, 'navigation tick should advance while travelling')
distance = 3
now = 1015
local arrived = navigation:tick()
check(arrived.ok and arrived.value.state == 'ARRIVED' and arrivalEvents == 1, 'navigation should emit arrival only inside the radius')

local stuckDistance = 20
local stuckNavigation = assert(Navigation.new({
    clock = clock,
    registry = clientRegistry,
    arrivalRadius = 4,
    navigationTimeout = 120,
    stuckTimeout = 5,
    entityExists = function() return true end,
    distance = function() return stuckDistance end,
    playerDistance = function() return 0 end,
    moveTo = function() return true end,
    onRecovery = function(reason) recoveryEvents[#recoveryEvents + 1] = reason end
}))
check(stuckNavigation:start({
    serverOwned = true, profileKey = authorization.profileKey, generationToken = authorization.generationToken,
    entity = 701, target = authorization.candidate
}).ok, 'stuck navigation should start')
now = 1020
stuckNavigation:tick()
now = 1027
local stuck = stuckNavigation:tick()
check(not stuck.ok and stuck.error.code == Codes.NPC_NAVIGATION_STUCK, 'navigation should detect a stalled ped')

playerDistance = 100
local awayNavigation = assert(Navigation.new({
    clock = clock, registry = clientRegistry, playerAwayDistance = 50,
    entityExists = function() return true end, distance = function() return 20 end,
    playerDistance = function() return playerDistance end, moveTo = function() return true end
}))
check(awayNavigation:start({ serverOwned = true, profileKey = authorization.profileKey, generationToken = authorization.generationToken, entity = 701, target = authorization.candidate }).ok, 'player-away navigation should start')
local away = awayNavigation:tick()
check(not away.ok and away.error.code == Codes.NPC_NAVIGATION_PLAYER_AWAY, 'navigation should recover when player moves away')

local deletedNow = false
local deletedNavigation = assert(Navigation.new({
    clock = clock, registry = clientRegistry, entityExists = function() return not deletedNow end,
    distance = function() return 20 end, playerDistance = function() return 0 end, moveTo = function() return true end
}))
check(deletedNavigation:start({ serverOwned = true, profileKey = authorization.profileKey, generationToken = authorization.generationToken, entity = 701, target = authorization.candidate }).ok, 'deleted-ped navigation should start')
deletedNow = true
local deletedTick = deletedNavigation:tick()
check(not deletedTick.ok and deletedTick.error.code == Codes.NPC_NAVIGATION_ENTITY_DELETED, 'navigation should detect deleted peds')

local markArrivalCalls = 0
local bookingService = {
    markArrival = function(_, actor, bookingId, expected, verifier)
        check(actor.type == 'PLAYER' and actor.ref == '42' and bookingId == 'booking:one', 'arrival should use the server player actor')
        check(type(verifier) == 'function' and verifier() == true, 'booking transition must receive a trusted verifier')
        markArrivalCalls = markArrivalCalls + 1
        return NightShift.Result.ok({ id = bookingId, status = 'ARRIVED', version = (expected or 1) + 1 })
    end
}
local arrivalService = assert(ArrivalService.new({
    travelService = travelService,
    entityRegistry = spawnRegistry,
    bookingService = bookingService,
    clock = clock,
    distanceCheck = function() return true end
}))
local arrival = arrivalService:accept(42, {
    travelKey = authorization.travelKey,
    bookingId = authorization.bookingId,
    profileKey = authorization.profileKey,
    generationToken = authorization.generationToken,
    entity = 701,
    networkId = 88,
    expectedVersion = 1
})
check(arrival.ok and markArrivalCalls == 1, 'server should accept only validated arrival context')
local spoof = arrivalService:accept(42, {
    travelKey = authorization.travelKey,
    bookingId = authorization.bookingId,
    profileKey = authorization.profileKey,
    generationToken = 'npc:forged',
    entity = 701,
    networkId = 88
})
check(not spoof.ok and (spoof.error.code == Codes.NPC_ARRIVAL_SPOOF or spoof.error.code == Codes.ENTITY_GENERATION_MISMATCH), 'arrival spoof must be rejected')

local returned = false
local deletedEntity = false
local despawn = assert(Despawn.new({
    registry = clientRegistry,
    fadeOut = function(entity) check(entity == 701, 'despawn should fade the bound entity'); return true end,
    deleteEntity = function(entity) deletedEntity = entity == 701; return true end,
    onReturn = function(context) returned = context.generationToken == authorization.generationToken end
}))
local cleanup = despawn:despawn({
    serverOwned = true,
    profileKey = authorization.profileKey,
    generationToken = authorization.generationToken,
    entity = 701,
    returnWorker = true
})
check(cleanup.ok and deletedEntity and returned and clientRegistry:get(authorization.profileKey).ok == false, 'despawn should clean physical entity and client registry mapping')

local bootOk, bootResult = NightShift.Server.bootstrap({ config = NightShift.DefaultConfig })
check(bootOk and bootResult.services and bootResult.services.services and
    bootResult.services.services.npcTravel and bootResult.services.services.npcEntityRegistry and
    bootResult.services.services.npcSpawn and bootResult.services.services.npcArrival,
    'S09 services should be wired into deferred bootstrap')

print('NS-090..NS-094 tests passed: logical travel, entity generations, controlled spawn, validated navigation/arrival, and cleanup')
