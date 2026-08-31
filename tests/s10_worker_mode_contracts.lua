local function check(value, message)
    assert(value, message)
end

local Codes = NightShift.Errors.Codes
local District = NightShift.Domain.District
local DistrictService = NightShift.DistrictService
local DemandService = NightShift.DemandService
local AvailabilityService = NightShift.WorkerAvailabilityService
local CustomerService = NightShift.NpcCustomerService
local CandidateController = NightShift.ClientWorkerModeCustomerCandidates

check(type(District) == 'table' and type(District.new) == 'function', 'S10 district domain must be available')
check(type(DistrictService) == 'table' and type(DistrictService.new) == 'function', 'S10 district service must be available')
check(type(DemandService) == 'table' and type(DemandService.new) == 'function', 'S10 demand service must be available')
check(type(AvailabilityService) == 'table' and type(AvailabilityService.new) == 'function', 'S10 worker availability service must be available')
check(type(CustomerService) == 'table' and type(CustomerService.new) == 'function', 'S10 customer service must be available')
check(type(CandidateController) == 'table' and type(CandidateController.new) == 'function', 'S10 client candidate controller must be available')

do
    local normalized, errorResult = NightShift.Validators.validateConfig({
        provider = { mode = 'explicit', name = 'standalone' },
        servicePackages = {},
        locations = {},
        serviceCatalog = { enabled = false, packages = {} },
        pricing = { enabled = false },
        cancellation = { enabled = false },
        npcProfiles = {},
        demand = {
            enabled = true,
            min = 0,
            max = 100,
            window = 60,
            generationIntervalSeconds = 30,
            candidateCooldownSeconds = 45,
            opportunityTtlSeconds = 300,
            maxConcurrentOpportunities = 2,
            districts = {
                vinewood = {
                    baseline = 70,
                    priceModifier = 1.15,
                    riskModifier = 0.2,
                    heatModifier = 0.1,
                    allowedZones = { 'vinewood_hills' },
                    timeCurve = { [18] = 1.2 },
                    dayCurve = { FRIDAY = 1.3 },
                    maxActiveCustomers = 4
                }
            }
        },
        heat = { min = 0, max = 100, decay = 0 }
    })
    check(normalized and not errorResult and normalized.demand.districts.vinewood.baseline == 70, 'rich demand config should normalize')

    local invalid = NightShift.Validators.validateConfig({
        provider = { mode = 'explicit', name = 'standalone' },
        servicePackages = {}, locations = {},
        serviceCatalog = { enabled = false, packages = {} },
        pricing = { enabled = false }, cancellation = { enabled = false }, npcProfiles = {},
        demand = { window = math.huge, districts = {} }, heat = { min = 0, max = 100, decay = 0 }
    })
    check(not invalid, 'unsafe demand window must fail closed')
end

local now = 5 * 3600
local clock = { now = function() return now end }
local districtConfig = {
    districts = {
        vinewood = {
            baseline = 70,
            priceModifier = 1.15,
            riskModifier = 0.2,
            heatModifier = 0.1,
            allowedZones = { 'vinewood_hills', 'east_vinewood' },
            timeCurve = { [5] = 0.9, [18] = 1.2 },
            dayCurve = { FRIDAY = 1.3 },
            maxActiveCustomers = 3
        },
        vespucci = {
            baseline = 40,
            allowedZones = { 'vespucci_beach' },
            maxActiveCustomers = 1
        }
    },
    defaultDistrict = 'vinewood',
    min = 0,
    max = 100,
    window = 60,
    oversupplyPenalty = 0.5,
    recentActivityImpact = 0.1,
    policePressureImpact = 0.2,
    heatImpact = 0.2
}

local districts = assert(DistrictService.new({ config = districtConfig, clock = clock }))
local vinewood = districts:get('VINEWOOD')
check(vinewood and vinewood.id == 'vinewood', 'district lookup must be case-insensitive')
check(vinewood:isZoneAllowed('VINEWOOD_HILLS'), 'district must allow configured discovery zones')
check(not vinewood:isZoneAllowed('unknown_zone'), 'district must reject unknown discovery zones')
check(vinewood:timeMultiplier(18) == 1.2 and vinewood:dayMultiplier('FRIDAY') == 1.3, 'district curves must resolve')
local copied = vinewood:copy()
copied.allowedZones[1] = 'mutated'
check(vinewood.allowedZones[1] == 'vinewood_hills', 'district copies must be immutable')
local unknownDistrict = districts:resolve('unknown')
check(not unknownDistrict.ok and unknownDistrict.error.code == Codes.DISTRICT_NOT_FOUND, 'unknown district must fail closed')

local demand = assert(DemandService.new({
    districtService = districts,
    config = districtConfig,
    clock = clock
}))

local fridayHigh = demand:evaluate({ district = 'vinewood', hour = 18, day = 'FRIDAY', activeWorkers = 0 })
check(fridayHigh.ok and fridayHigh.value.score > 70, 'Friday high-demand profile should produce a high score')
check(fridayHigh.value.explanation and fridayHigh.value.factors.dayMultiplier == 1.3, 'demand result must be explainable')
local oversupplied = demand:evaluate({ district = 'vinewood', hour = 18, day = 'FRIDAY', activeWorkers = 20 })
check(oversupplied.ok and oversupplied.value.score < fridayHigh.value.score, 'oversupply must lower demand')
local noWorkers = demand:evaluate({ district = 'vinewood', hour = 18, day = 'FRIDAY', activeWorkers = 0 })
check(noWorkers.ok and noWorkers.value.inputs.activeWorkers == 0, 'demand engine must handle no active workers')

local identityTag = 'license'
local identity = assert(NightShift.IdentityService.new({
    getIdentity = function(source)
        return { identifier = identityTag .. ':' .. tostring(source), characterId = 'char:' .. tostring(source), characterName = 'Worker ' .. tostring(source), job = { name = 'nightshift', onDuty = true }, loaded = true }
    end
}))
local availability = assert(AvailabilityService.new({ identityService = identity, clock = clock }))
local offline = assert(availability:get(10)).value
check(offline.state == 'OFFLINE' and not offline.available, 'worker availability must default to offline')
local available = availability:setAvailable(10, { district = 'vinewood' })
check(available.ok and available.value.state == 'AVAILABLE' and available.value.available, 'worker must explicitly opt in')
local repeated = availability:setAvailable(10, { district = 'vinewood' })
check(repeated.ok and repeated.metadata.idempotent and repeated.value.version == available.value.version, 'repeated availability opt in should be idempotent')
local invalidDistrict = availability:setAvailable(10, { district = 'not a district' })
check(not invalidDistrict.ok and invalidDistrict.error.code == Codes.WORKER_AVAILABILITY_INVALID, 'worker availability must reject unsafe district references')
local locked = availability:lockForBooking(10, 'booking:10')
check(locked.ok and locked.value.state == 'BUSY' and locked.value.bookingId == 'booking:10', 'booking lock must move worker to busy')
local denied = availability:setAvailable(10)
check(not denied.ok and denied.error.code == Codes.WORKER_AVAILABILITY_CONFLICT, 'busy worker cannot opt in twice')
local unlocked = availability:releaseBooking(10, 'booking:10')
check(unlocked.ok and unlocked.value.state == 'AVAILABLE', 'booking release must return worker to available')
local numericLocked = availability:lockForBooking(10, 42)
check(numericLocked.ok and numericLocked.value.state == 'BUSY' and numericLocked.value.bookingId == '42', 'database booking IDs must be normalized before locking availability')
local numericUnlocked = availability:releaseBooking(10, 42)
check(numericUnlocked.ok and numericUnlocked.value.state == 'AVAILABLE', 'numeric booking IDs must release their normalized availability lock')
local reset = availability:reset(10, 'logout')
check(reset.ok and reset.value.state == 'OFFLINE', 'logout must reset transient availability')

local plainIdentityAvailability = assert(AvailabilityService.new({
    identityService = { resolve = function(_, source)
        return { identityKey = 'plain:' .. tostring(source), source = source, job = { onDuty = true } }
    end },
    clock = clock
}))
local plainAvailable = plainIdentityAvailability:setAvailable(11)
check(plainAvailable.ok and plainAvailable.value.identityKey == 'plain:11', 'availability must accept plain identity resolver values')

local duty = true
local dutyAvailability = assert(AvailabilityService.new({
    identityService = { resolve = function(_, source)
        return { identityKey = 'duty:' .. tostring(source), source = source, job = { onDuty = duty } }
    end },
    requireDuty = true,
    clock = clock
}))
check(dutyAvailability:setAvailable(12).ok, 'duty-aware worker should opt in while on duty')
duty = false
local dutyLock = dutyAvailability:lockForBooking(12, 'booking:duty')
check(not dutyLock.ok and dutyLock.error.code == Codes.WORKER_AVAILABILITY_DENIED, 'booking lock must re-check framework duty')

local generator = assert(NightShift.NpcProfileGenerator.new({ config = {
    enabled = true,
    seed = 's10-test',
    promotion = { completedBookings = 3 },
    templates = {
        { id = 'customer', role = 'CUSTOMER', profileType = 'SEMI_PERSISTENT', weight = 1,
            aliases = { 'Customer' }, budgetClass = { min = 1, max = 3 },
            districts = { 'vinewood' }, travelModes = { 'WALK' } }
    }
}, clock = clock }))
assert(availability:setAvailable(10, { district = 'vinewood' }))
local customers = assert(CustomerService.new({
    districtService = districts,
    demandService = demand,
    availabilityService = availability,
    generator = generator,
    clock = clock,
    config = {
        enabled = true,
        generationIntervalSeconds = 1,
        candidateCooldownSeconds = 10,
        opportunityTtlSeconds = 60,
        maxConcurrentOpportunities = 2,
        maxActiveLogicalCustomers = 10,
        minimumDemandScore = 1,
        seed = 's10-customer'
    }
}))
local opportunity = customers:generate(10, { district = 'vinewood', zone = 'vinewood_hills', hour = 18, day = 'FRIDAY' })
check(opportunity.ok and opportunity.value.customer.role == 'CUSTOMER', 'available worker should receive a logical customer')
check(opportunity.value.physicalCandidate == nil and opportunity.value.worldTarget == nil, 'customer generation must not require a physical entity')
local cooldown = customers:generate(10, { district = 'vinewood', zone = 'vinewood_hills', hour = 18, day = 'FRIDAY' })
check(not cooldown.ok and cooldown.error.code == Codes.NPC_CUSTOMER_COOLDOWN, 'customer generation must honor cooldown')
now = now + 11
local second = customers:generate(10, { district = 'vinewood', hour = 18, day = 'FRIDAY' })
check(second.ok, 'customer generation should resume after cooldown')
check(second.value.zone == 'vinewood_hills', 'customer generation should use the first configured discovery zone when omitted')
local claimed = customers:claim(10, opportunity.value.opportunityKey)
check(claimed.ok and claimed.value.state == 'CLAIMED', 'customer opportunity should support an explicit claim state')
now = now + 11
local third = customers:generate(10, { district = 'vinewood', zone = 'east_vinewood', hour = 18, day = 'FRIDAY' })
check(not third.ok and third.error.code == Codes.NPC_CUSTOMER_CAPACITY, 'customer generation must cap concurrent opportunities')
local list = assert(customers:list(10)).value
check(#list.items == 1 and customers:activeCount(10) == 2, 'customer list must be scoped while active capacity includes claimed opportunities')
assert(availability:reset(10, 'logout'))
local expiredOnLogout = customers:get(opportunity.value.opportunityKey)
check(expiredOnLogout.ok and expiredOnLogout.value.state == 'EXPIRED', 'logout must expire worker-owned customer opportunities')
check(customers:activeCount(10) == 0, 'expired worker opportunities must release active capacity')
now = now + 11
local notAvailable = customers:generate(10, { district = 'vinewood', zone = 'vinewood_hills' })
check(not notAvailable.ok and notAvailable.error.code == Codes.WORKER_AVAILABILITY_DENIED, 'offline workers must not receive customers')
identityTag = 'new-license'
local availableAgain = availability:setAvailable(10, { district = 'vinewood' })
check(availableAgain.ok and availableAgain.value.identityKey ~= available.value.identityKey, 'source reuse must create a new worker identity')
local staleClaim = customers:claim(10, opportunity.value.opportunityKey)
check(not staleClaim.ok and staleClaim.error.code == Codes.NPC_CUSTOMER_INVALID, 'source reuse must not claim a prior worker opportunity')

local invalidController = CandidateController.new({ enabled = 'yes' })
check(not invalidController, 'client candidate controller must validate enabled flag type')
local controller = assert(CandidateController.new())
local synced = controller:sync({ items = {
    { opportunityKey = 'customer-opportunity:10:1', district = 'vinewood', zone = 'vinewood_hills', alias = 'Customer\nOne', budgetClass = 2, demandScore = 85, demandBand = 'HIGH', generationSeed = 'secret', worldTarget = { x = 1 } }
} })
check(synced.ok and synced.value.items[1].opportunityKey, 'client controller should accept logical candidates')
check(synced.value.items[1].generationSeed == nil and synced.value.items[1].worldTarget == nil, 'client candidates must strip internal seed and coordinates')
check(synced.value.items[1].alias == 'Customer One', 'client candidate aliases must remove control characters')

print('NS-100..NS-103 tests passed: districts, explainable demand, opt-in availability, customer generation, and client candidate sanitization')
