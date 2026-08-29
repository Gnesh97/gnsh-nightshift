local function check(value, message) assert(value, message) end

local NpcProfile = NightShift.Domain.NpcProfile
local NpcProfileRepository = NightShift.Repositories.NpcProfile
local Generator = NightShift.NpcProfileGenerator
local WorkerService = NightShift.NpcWorkerService
local Marketplace = NightShift.MarketplaceQueryService

check(type(NightShift.NpcProfileConfig) == 'table', 'S08 profile config must be available')

do
    local profile, profileError = NpcProfile.new({
        profileKey = 'npc-worker:maya',
        role = 'WORKER',
        profileType = 'SEMI_PERSISTENT',
        alias = ' Maya <script> ',
        appearanceProfileRef = 'appearance:default',
        priceClass = 3,
        rating = 4.8,
        traits = { reliability = 88, discretion = 91, patience = 74, negotiation = 67 },
        homeDistrict = 'vinewood',
        activeDistrict = 'vinewood',
        travelMode = 'VEHICLE',
        availability = 'AVAILABLE',
        generationSeed = 'seed:maya',
        tags = { 'QUIET', 'PREMIUM' }
    })
    check(profile and not profileError, 'NPC profile should normalize without a world ped')
    check(profile.alias == 'Maya script', 'NPC alias must strip unsafe markup')
    check(profile.worldEntity == nil and profile.entity == nil, 'NPC profile must not require a world ped')
    check(profile.traits.reliability == 88 and profile.priceClass == 3, 'NPC profile traits and price class must normalize')
    local valid, validationError = NpcProfile.validate(profile)
    check(valid and not validationError, 'normalized NPC profile should validate')
    local snapshot = NpcProfile.copy(profile)
    snapshot.alias = 'Changed'
    snapshot.traits.reliability = 1
    check(profile.alias == 'Maya script' and profile.traits.reliability == 88, 'NPC profile copy must be immutable')
    local invalid, invalidError = NpcProfile.new({ profileKey = 'npc:invalid', role = 'UNKNOWN', alias = 'x' })
    check(not invalid and invalidError.error.code == NightShift.Errors.Codes.NPC_PROFILE_INVALID, 'unknown NPC role must fail closed')
end

local generatorConfig = {
    seed = 's08-test',
    promotion = { completedBookings = 2 },
    templates = {
        {
            id = 'worker',
            role = 'WORKER',
            profileType = 'SEMI_PERSISTENT',
            weight = 1,
            aliases = { 'Maya', 'Lena' },
            appearanceProfileRefs = { 'appearance:default' },
            priceClass = { min = 2, max = 3 },
            rating = { min = 4.2, max = 4.8 },
            traits = {
                reliability = { min = 70, max = 90 },
                discretion = { min = 70, max = 95 },
                patience = { min = 50, max = 80 },
                negotiation = { min = 40, max = 75 }
            },
            districts = { 'vinewood', 'vespucci' },
            travelModes = { 'VEHICLE', 'WALK' },
            tags = { 'QUIET' }
        },
        {
            id = 'customer',
            role = 'CUSTOMER',
            profileType = 'SEMI_PERSISTENT',
            weight = 1,
            aliases = { 'Client' },
            budgetClass = { min = 1, max = 2 },
            districts = { 'rockford' },
            travelModes = { 'WALK' }
        }
    }
}

local generator = assert(Generator.new({ config = generatorConfig }))

do
    local first = assert(generator:generate({ role = 'WORKER', seed = 'fixed', profileKey = 'npc-worker:fixed' })).value
    local repeatProfile = assert(generator:generate({ role = 'WORKER', seed = 'fixed', profileKey = 'npc-worker:fixed' })).value
    check(first.alias == repeatProfile.alias and first.rating == repeatProfile.rating and first.traits.reliability == repeatProfile.traits.reliability, 'same generator seed must be reproducible')
    check(first.role == 'WORKER' and first.profileType == 'SEMI_PERSISTENT', 'generator must honor role and persistence template')
    check(first.appearanceProfileRef == 'appearance:default', 'generator must assign appearance profile references')
    local second = assert(generator:generate({ role = 'WORKER', seed = 'different', profileKey = 'npc-worker:different' })).value
    check(second.alias ~= first.alias, 'generator must avoid duplicate aliases')
    local promoted = assert(generator:generate({ role = 'WORKER', seed = 'promote', profileKey = 'npc-worker:promote', completedBookings = 2 })).value
    check(promoted.profileType == 'PERSISTENT', 'generator must promote profiles at the configured booking threshold')
    local customer = assert(generator:generate({ role = 'CUSTOMER', seed = 'customer', profileKey = 'npc-customer:customer' })).value
    check(customer.role == 'CUSTOMER' and customer.budgetClass >= 1, 'generator must support customer profiles')
end

do
    local calls = {}
    local db = {
        single = function(_, sql, params)
            calls.single = { sql = sql, params = params }
            return NightShift.Result.ok(nil)
        end,
        query = function(_, sql, params)
            calls.query = { sql = sql, params = params }
            return NightShift.Result.ok({})
        end,
        insert = function(_, sql, params)
            calls.insert = { sql = sql, params = params }
            return NightShift.Result.ok({ insertId = 9 })
        end,
        update = function(_, sql, params)
            calls.update = { sql = sql, params = params }
            return NightShift.Result.ok({ affectedRows = 1 })
        end,
        scalar = function() return NightShift.Result.ok(nil) end
    }
    local repository, repositoryError = NpcProfileRepository.new({ db = db })
    check(repository and not repositoryError, 'NPC profile repository should construct with a database adapter')
    local profile = assert(generator:generate({ role = 'WORKER', seed = 'repository', profileKey = 'npc-worker:repository' })).value
    local created = repository:createProfile(profile)
    check(created.ok and calls.insert.sql:find('nightshift_npc_profiles', 1, true), 'NPC profile create must use the repository boundary')
    local worker = repository:createWorker({ workerKey = 'npc-worker:repository', profileId = 9, state = 'AVAILABLE' })
    check(worker.ok and calls.insert.sql:find('nightshift_npc_workers', 1, true), 'NPC worker create must use the worker table')
    local reserve = repository:reserveWorkerAtomic('npc-worker:repository', 'booking:1', 'reservation:npc-worker:repository', 1234)
    check(reserve.ok and calls.update.sql:find('state =', 1, true) and calls.update.sql:find('booking_id', 1, true), 'NPC worker reserve must be atomic and parameterized')
end

local now = 1000
local clock = { now = function() return now end }
local workerService = assert(WorkerService.new({ generator = generator, clock = clock, defaultTtl = 30 }))
local profileOne = assert(generator:generate({ role = 'WORKER', seed = 'pool-one', profileKey = 'npc-worker:pool-one' })).value
local profileTwo = assert(generator:generate({ role = 'WORKER', seed = 'pool-two', profileKey = 'npc-worker:pool-two' })).value
local workerOne = assert(workerService:register(profileOne, { workerKey = 'npc-worker:pool-one', activeDistrict = 'vinewood' })).value
local workerTwo = assert(workerService:register(profileTwo, { workerKey = 'npc-worker:pool-two', activeDistrict = 'vinewood' })).value

do
    local reserved = assert(workerService:reserve(workerOne.workerKey, 'booking:one', { ttlSeconds = 30 })).value
    check(reserved.state == 'RESERVED' and reserved.bookingId == 'booking:one', 'worker reserve should claim an available worker')
    local conflict = workerService:reserve(workerOne.workerKey, 'booking:two', { ttlSeconds = 30 })
    check(not conflict.ok and conflict.error.code == NightShift.Errors.Codes.NPC_WORKER_CONFLICT, 'two bookings must not reserve one NPC worker')
    local idempotent = assert(workerService:reserve(workerOne.workerKey, 'booking:one', { ttlSeconds = 30 })).value
    check(idempotent.id == reserved.id and idempotent.bookingId == 'booking:one', 'same booking reserve should be idempotent')
    local ownerDenied = workerService:release(workerOne.workerKey, 'booking:two')
    check(not ownerDenied.ok and ownerDenied.error.code == NightShift.Errors.Codes.NPC_WORKER_OWNER_MISMATCH, 'worker release must check booking ownership')
    local occupied = assert(workerService:occupy(workerOne.workerKey, 'booking:one')).value
    check(occupied.state == 'OCCUPIED', 'reserved worker should transition to occupied')
    local released = assert(workerService:release(workerOne.workerKey, 'booking:one')).value
    check(released.state == 'AVAILABLE', 'worker release should return the worker to the pool')
end

do
    local expiringProfile = assert(generator:generate({ role = 'WORKER', seed = 'expiring', profileKey = 'npc-worker:expiring' })).value
    local expiring = assert(workerService:register(expiringProfile, { workerKey = 'npc-worker:expiring', expiresAt = 1010 })).value
    check(expiring.profileType == 'SEMI_PERSISTENT', 'test worker should be semi-persistent')
    now = 1011
    local expired = assert(workerService:expire()).value
    check(expired.expired >= 1, 'expired semi-persistent workers should be removed from availability')
    local listed = assert(workerService:listAvailable({ district = 'vinewood' })).value
    for _, card in ipairs(listed.items or listed) do check(card.workerKey ~= 'npc-worker:expiring', 'expired worker must not be listed') end
end

do
    local marketplace = assert(Marketplace.new({
        workerService = workerService,
        maxPageSize = 2,
        etaEstimator = function(worker) return worker.activeDistrict == 'vinewood' and 4 or 9 end
    }))
    local page = assert(marketplace:list({ district = 'vinewood', limit = 2, offset = 0 })).value
    check(#page.items <= 2 and page.limit == 2 and page.offset == 0, 'marketplace must return bounded pagination')
    check(page.items[1] and page.items[1].publicId and page.items[1].alias and page.items[1].etaMinutes == 4, 'marketplace card must expose stable safe fields')
    for key in pairs(page.items[1]) do
        check(key ~= 'traits' and key ~= 'reliability' and key ~= 'discretion' and key ~= 'appearanceProfileRef' and key ~= 'generationSeed', 'marketplace must not expose internal traits')
    end
    local invalid = marketplace:list({ limit = 0 })
    check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.MARKETPLACE_INVALID, 'invalid marketplace pagination must fail closed')
end

print('NS-080..NS-083 tests passed: NPC profiles, deterministic generation, atomic worker availability, and privacy-safe marketplace')
