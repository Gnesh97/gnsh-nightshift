NightShift = NightShift or {}

local readiness = NightShift.Enums.Readiness

local function copyValue(value, seen)
    if NightShift.Validators and type(NightShift.Validators.copy) == 'function' then
        return NightShift.Validators.copy(value)
    end
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copyValue(key, seen)] = copyValue(item, seen) end
    return output
end

local function readConvar(name, fallback)
    local getConvar = type(GetConvar) == 'function' and GetConvar or nil
    if type(getConvar) ~= 'function' then return fallback end
    local ok, value = pcall(getConvar, name, fallback)
    return ok and value or fallback
end

local function persistenceConvarEnabled()
    local value = tostring(readConvar('nightshift_persistence', 'false')):lower()
    return value == 'true' or value == '1'
end

local function applyRuntimeConfig(source)
    if type(source) ~= 'table' or not persistenceConvarEnabled() then return source end
    local output = copyValue(source)
    if rawget(output, 'features') == nil then
        output.features = {}
    elseif type(output.features) ~= 'table' then
        return output
    else
        output.features = copyValue(output.features)
    end
    output.features.persistence = true
    return output
end

local function oxMySqlAvailable()
    local mysql = type(MySQL) == 'table' and MySQL or nil
    if type(mysql) == 'table' then
        for _, operation in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'transaction' }) do
            local target = rawget(mysql, operation)
            if type(target) == 'function' or (type(target) == 'table' and type(target.await) == 'function') then
                return true
            end
        end
    end
    local runtimeExports = exports
    if runtimeExports == nil then return false end
    local ok, oxmysql = pcall(function() return runtimeExports.oxmysql end)
    return ok and oxmysql ~= nil
end

local function createRuntimeDatabaseAdapter()
    if type(GetConvar) ~= 'function' or not oxMySqlAvailable() then return nil end
    local database = NightShift.Database
    local factory = type(database) == 'table' and database.OxMySQL or nil
    if type(database) ~= 'table' or type(database.wrap) ~= 'function' or type(factory) ~= 'table' or type(factory.new) ~= 'function' then
        return nil
    end
    local ok, driver = pcall(factory.new, {})
    if not ok or type(driver) ~= 'table' then return nil end
    local wrappedOk, adapter = pcall(database.wrap, driver)
    if not wrappedOk or type(adapter) ~= 'table' or type(adapter.healthCheck) ~= 'function' then return nil end
    return adapter
end

local defaultStages = {
    config = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local source = NightShift.DefaultConfig
        if type(context) == 'table' and rawget(context, 'config') ~= nil then
            source = rawget(context, 'config')
        elseif type(options) == 'table' and rawget(options, 'config') ~= nil then
            source = rawget(options, 'config')
        end
        source = applyRuntimeConfig(source)
        local resolver = options.resolveProvider
        if type(context) == 'table' and rawget(context, 'resolveProvider') ~= nil then
            resolver = rawget(context, 'resolveProvider')
        end
        if resolver == nil and type(context) == 'table' and type(context.providerResolver) == 'table' and type(context.providerResolver.detectProvider) == 'function' then
            resolver = function() return context.providerResolver:detectProvider() end
        end
        if resolver == nil and type(options.providerResolver) == 'table' and type(options.providerResolver.detectProvider) == 'function' then
            resolver = function() return options.providerResolver:detectProvider() end
        end
        if resolver == nil and NightShift.ProviderResolver and type(NightShift.ProviderResolver.detectForConfig) == 'function' then
            resolver = function(registry)
                return NightShift.ProviderResolver.detectForConfig({
                    registry = registry,
                    frameworkAdapters = options.frameworkAdapters,
                    frameworkFactories = options.frameworkFactories,
                    frameworkOptions = options.frameworkOptions,
                    resourceState = options.resourceState,
                    resourceNames = options.resourceNames
                })
            end
        end
        local normalized, err = NightShift.Validators.validateConfig(source, {
            registry = options.providerRegistry,
            resolveProvider = resolver
        })
        if not normalized then return NightShift.Result.err(err) end
        return { ok = true, config = normalized }
    end,
    db = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local configResult = bootstrap and bootstrap.results and bootstrap.results.config or {}
        local config = configResult.config or configResult.value and configResult.value.config or NightShift.DefaultConfig
        local adapter = options.databaseAdapter
        if type(context) == 'table' and rawget(context, 'databaseAdapter') ~= nil then adapter = rawget(context, 'databaseAdapter') end
        if adapter == nil and type(context) == 'table' and rawget(context, 'database') ~= nil then adapter = rawget(context, 'database') end
        if adapter == nil then adapter = options.database end
        local persistence = config.features and config.features.persistence == true
        if adapter == nil and persistence then adapter = createRuntimeDatabaseAdapter() end
        if adapter == nil then
            if config.environment == 'development' and not persistence then
                return { ok = true, deferred = true, reason = 'database adapter not configured' }
            end
            return NightShift.Result.err(NightShift.Errors.Codes.DB_UNAVAILABLE, 'database adapter is required for this environment', { stage = 'db' })
        end
        if type(adapter) ~= 'table' or type(adapter.healthCheck) ~= 'function' then
            return NightShift.Result.err(NightShift.Errors.Codes.DB_UNAVAILABLE, 'database adapter does not expose healthCheck', { stage = 'db' })
        end
        local runner = options.migrationRunner
        if type(context) == 'table' and rawget(context, 'migrationRunner') ~= nil then runner = rawget(context, 'migrationRunner') end
        if not runner then
            if not NightShift.Migrations or not NightShift.Migrations.Runner then
                return NightShift.Result.err(NightShift.Errors.Codes.MIGRATION_DB_UNAVAILABLE, 'migration runner is unavailable', { stage = 'db' })
            end
            runner = NightShift.Migrations.Runner.new({
                db = adapter,
                migrations = options.migrations,
                loadFile = options.loadMigration,
                logger = options.logger
            })
        end
        if type(runner) ~= 'table' or type(runner.run) ~= 'function' then
            return NightShift.Result.err(NightShift.Errors.Codes.MIGRATION_DB_UNAVAILABLE, 'migration runner is unavailable', { stage = 'db' })
        end
        local migrationResult = runner:run()
        if type(migrationResult) ~= 'table' or not migrationResult.ok then return migrationResult end
        return { ok = true, database = adapter, migrations = migrationResult }
    end,
    adapters = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local configResult = bootstrap and bootstrap.results and bootstrap.results.config or {}
        local config = configResult.config or configResult.value and configResult.value.config or NightShift.DefaultConfig
        local resolver
        if type(context) == 'table' and type(context.providerResolver) == 'table' then resolver = context.providerResolver end
        if not resolver and type(options.providerResolverRuntime) == 'table' then resolver = options.providerResolverRuntime end
        if not resolver and type(options.providerResolver) == 'table' then resolver = options.providerResolver end
        if not resolver and NightShift.ProviderResolver and type(NightShift.ProviderResolver.new) == 'function' then
            resolver = NightShift.ProviderResolver.new({
                registry = options.providerRegistry,
                frameworkAdapters = options.frameworkAdapters,
                frameworkFactories = options.frameworkFactories,
                frameworkOptions = options.frameworkOptions,
                moneyAdapters = options.moneyAdapters,
                moneyFactories = options.moneyFactories,
                moneyOptions = options.moneyOptions,
                optionalProviders = options.optionalProviders,
                optionalFactories = options.optionalFactories,
                resourceState = options.resourceState,
                resourceNames = options.resourceNames,
                dependencies = options.providerDependencies,
                requireResourceState = options.requireResourceState,
                logger = options.logger
            })
        end
        if not resolver or type(resolver.resolve) ~= 'function' then
            return { ok = true, deferred = true, reason = 'provider resolver not configured' }
        end
        local resolved = resolver:resolve(config, context)
        if type(resolved) ~= 'table' or resolved.ok ~= true then return resolved end
        return { ok = true, providers = resolved.value, capabilities = resolved.value and resolved.value.capabilities, diagnostics = resolved.value and resolved.value.diagnostics }
    end,
    repositories = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local dbResult = bootstrap and bootstrap.results and bootstrap.results.db or {}
        local configResult = bootstrap and bootstrap.results and bootstrap.results.config or {}
        local config = configResult.config or configResult.value and configResult.value.config or NightShift.DefaultConfig
        local database = options.databaseAdapter or options.database
        if type(context) == 'table' then
            database = rawget(context, 'databaseAdapter') or rawget(context, 'database') or database
        end
        database = database or dbResult.database
        if database == nil then
            if config.environment == 'development' and not (config.features and config.features.persistence == true) then
                return { ok = true, deferred = true, reason = 'database adapter not configured' }
            end
            return NightShift.Result.err(NightShift.Errors.Codes.DB_UNAVAILABLE, 'profile repositories require a database adapter', { stage = 'repositories' })
        end
        if type(database) ~= 'table' then return NightShift.Result.err(NightShift.Errors.Codes.DB_UNAVAILABLE, 'profile database adapter is invalid', { stage = 'repositories' }) end
        local worker = options.workerProfileRepository
        local client = options.clientProfileRepository
        local booking = options.bookingRepository
        local bookingEvent = options.bookingEventRepository
        local deposit = options.depositRepository
        local payment = options.paymentRepository
        local location = options.locationRepository
        local locationReservation = options.locationReservationRepository
        local npcProfile = options.npcProfileRepository or options.npcProfilesRepository
        if type(context) == 'table' then
            worker = rawget(context, 'workerProfileRepository') or worker
            client = rawget(context, 'clientProfileRepository') or client
            booking = rawget(context, 'bookingRepository') or booking
            bookingEvent = rawget(context, 'bookingEventRepository') or bookingEvent
            deposit = rawget(context, 'depositRepository') or deposit
            payment = rawget(context, 'paymentRepository') or payment
            location = rawget(context, 'locationRepository') or location
            locationReservation = rawget(context, 'locationReservationRepository') or locationReservation
            npcProfile = rawget(context, 'npcProfileRepository') or rawget(context, 'npcProfilesRepository') or npcProfile
        end
        if worker == nil and NightShift.Repositories and NightShift.Repositories.WorkerProfile then
            local created, err = NightShift.Repositories.WorkerProfile.new({ db = database })
            if not created then return err end
            worker = created
        end
        if client == nil and NightShift.Repositories and NightShift.Repositories.ClientProfile then
            local created, err = NightShift.Repositories.ClientProfile.new({ db = database })
            if not created then return err end
            client = created
        end
        if booking == nil and NightShift.Repositories and NightShift.Repositories.Booking then
            local created, err = NightShift.Repositories.Booking.new({ db = database })
            if not created then return err end
            booking = created
        end
        if bookingEvent == nil and NightShift.Repositories and NightShift.Repositories.BookingEvent then
            local created, err = NightShift.Repositories.BookingEvent.new({ db = database })
            if not created then return err end
            bookingEvent = created
        end
        if deposit == nil and NightShift.Repositories and NightShift.Repositories.Deposit then
            local created, err = NightShift.Repositories.Deposit.new({ db = database })
            if not created then return err end
            deposit = created
        end
        if payment == nil and NightShift.Repositories and NightShift.Repositories.Payment then
            local created, err = NightShift.Repositories.Payment.new({ db = database })
            if not created then return err end
            payment = created
        end
        if location == nil and NightShift.Repositories and NightShift.Repositories.Location then
            local created, err = NightShift.Repositories.Location.new({ db = database })
            if not created then return err end
            location = created
        end
        if locationReservation == nil and NightShift.Repositories and NightShift.Repositories.LocationReservation then
            local created, err = NightShift.Repositories.LocationReservation.new({ db = database })
            if not created then return err end
            locationReservation = created
        end
        if npcProfile == nil and NightShift.Repositories and NightShift.Repositories.NpcProfile then
            local created, err = NightShift.Repositories.NpcProfile.new({ db = database })
            if not created then return err end
            npcProfile = created
        end
        if type(worker) ~= 'table' or type(client) ~= 'table' or type(booking) ~= 'table' or type(bookingEvent) ~= 'table' then
            return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_INVALID, 'profile/booking repositories are unavailable', { stage = 'repositories' })
        end
        return { ok = true, repositories = {
            workerProfile = worker,
            clientProfile = client,
            booking = booking,
            bookingEvent = bookingEvent,
            deposit = deposit,
            payment = payment,
            location = location,
            locationReservation = locationReservation,
            npcProfile = npcProfile
        } }
    end,
    services = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local adapterResult = bootstrap and bootstrap.results and bootstrap.results.adapters or {}
        local repositoryResult = bootstrap and bootstrap.results and bootstrap.results.repositories or {}
        local providers = adapterResult.providers or adapterResult.value and adapterResult.value.providers or {}
        local repositories = repositoryResult.repositories or repositoryResult.value and repositoryResult.value.repositories or {}
        local configResult = bootstrap and bootstrap.results and bootstrap.results.config or {}
        local config = configResult.config or configResult.value and configResult.value.config or NightShift.DefaultConfig
        local features = type(config.features) == 'table' and config.features or {}
        local framework = options.frameworkAdapter or providers.framework
        local money = options.moneyAdapter or options.money or providers.money
        if type(context) == 'table' then framework = rawget(context, 'frameworkAdapter') or framework end
        if type(context) == 'table' then money = rawget(context, 'moneyAdapter') or rawget(context, 'money') or money end
        local databaseDeferred = repositoryResult.deferred == true
        local demandConfig = config.demand or config.demandConfig or NightShift.DemandConfig or {}
        local districtService = options.districtService or options.districts
        if districtService == nil and NightShift.DistrictService then
            local created, err = NightShift.DistrictService.new({ config = demandConfig, clock = options.clock })
            if not created then return err end
            districtService = created
        end
        local workerAvailability = options.workerAvailabilityService or options.workerAvailability
        if workerAvailability == nil and NightShift.WorkerAvailabilityService then
            local created, err = NightShift.WorkerAvailabilityService.new({
                framework = framework,
                clock = options.clock,
                requireDuty = options.workerRequireDuty == true,
                persistProfile = options.workerAvailabilityPersist == true
            })
            if not created then return err end
            workerAvailability = created
        end
        local demandService = options.demandService or options.demand
        if demandService == nil and NightShift.DemandService and districtService then
            local created, err = NightShift.DemandService.new({
                districtService = districtService,
                availabilityService = workerAvailability,
                config = demandConfig,
                enabled = features.demand == true,
                clock = options.clock,
                activeWorkersResolver = options.activeWorkersResolver,
                recentActivityResolver = options.recentActivityResolver,
                policePressureResolver = options.policePressureResolver,
                heatResolver = options.heatResolver,
                eventResolver = options.demandEventResolver,
                weatherResolver = options.demandWeatherResolver
            })
            if not created then return err end
            demandService = created
        end
        local vehicleLocation = options.vehicleLocationService
        if vehicleLocation == nil and NightShift.VehicleLocationService and type(options.getVehicle) == 'function' then
            local created, err = NightShift.VehicleLocationService.new({
                getVehicle = options.getVehicle,
                hasAccess = options.vehicleAccessCheck,
                isAllowedZone = options.vehicleZoneCheck,
                waterCheck = options.locationWaterCheck,
                bookingLookup = options.vehicleBookingLookup,
                assignmentCheck = options.vehicleAssignmentCheck,
                npcNearby = options.vehicleNpcNearby,
                clock = options.clock,
                maxSpeed = options.vehicleMaxSpeed,
                requirePrivate = options.vehicleRequirePrivate
            })
            if not created then return err end
            vehicleLocation = created
        end
        local locationService = options.locationService
        if locationService == nil and NightShift.LocationService then
            local locationProviders = providers.optional or providers
            local created, err = NightShift.LocationService.new({
                locations = config.locations,
                repository = repositories.location,
                providers = options.locationProviders or locationProviders,
                clock = options.clock,
                accessCheck = options.locationAccessCheck,
                zoneCheck = options.locationZoneCheck,
                interiorCheck = options.locationInteriorCheck,
                waterCheck = options.locationWaterCheck,
                routeCheck = options.locationRouteCheck,
                vehicleService = vehicleLocation
            })
            if not created then return err end
            locationService = created
        end
        local locationReservation = options.locationReservationService
        if locationReservation == nil and locationService and NightShift.LocationReservationService then
            local locks = options.locationLocks
            if locks == nil and NightShift.Reservations then
                local created, err = NightShift.Reservations.new({ clock = options.clock, defaultTtl = options.locationReservationTtl or 300 })
                if not created then return err end
                locks = created
            end
            local created, err = NightShift.LocationReservationService.new({
                locationService = locationService,
                repository = repositories.locationReservation,
                locks = locks,
                providers = options.locationProviders or providers.optional or providers,
                clock = options.clock,
                defaultTtl = options.locationReservationTtl
            })
            if not created then return err end
            locationReservation = created
        end
        local npcProfileGenerator = options.npcProfileGenerator or options.npcGenerator
        if npcProfileGenerator == nil and NightShift.NpcProfileGenerator then
            local created, err = NightShift.NpcProfileGenerator.new({
                config = config.npcProfileConfig or NightShift.NpcProfileConfig,
                repository = repositories.npcProfile,
                clock = options.clock
            })
            if not created then return err end
            npcProfileGenerator = created
        end
        local npcWorker = options.npcWorkerService or options.npcWorker
        if npcWorker == nil and NightShift.NpcWorkerService then
            local npcConfig = config.npcProfileConfig or NightShift.NpcProfileConfig or {}
            local poolConfig = type(npcConfig.workerPool) == 'table' and npcConfig.workerPool or {}
            local created, err = NightShift.NpcWorkerService.new({
                generator = npcProfileGenerator,
                repository = repositories.npcProfile,
                locks = options.npcWorkerLocks,
                clock = options.clock,
                defaultTtl = options.npcWorkerReservationTtl or poolConfig.reservationTtl
            })
            if not created then return err end
            npcWorker = created
        end
        local marketplace = options.marketplaceQueryService or options.marketplaceService
        if marketplace == nil and NightShift.MarketplaceQueryService and npcWorker then
            local npcConfig = config.npcProfileConfig or NightShift.NpcProfileConfig or {}
            local marketplaceConfig = type(npcConfig.marketplace) == 'table' and npcConfig.marketplace or {}
            local created, err = NightShift.MarketplaceQueryService.new({
                workerService = npcWorker,
                maxPageSize = options.marketplaceMaxPageSize or marketplaceConfig.maxPageSize or 50,
                etaEstimator = options.marketplaceEtaEstimator,
                clock = options.clock
            })
            if not created then return err end
            marketplace = created
        end
        local streamingConfig = config.npcStreaming or NightShift.NpcStreamingConfig or {}
        local npcTravel = options.npcTravelService or options.npcTravel
        if npcTravel == nil and NightShift.NpcTravelService then
            local created, err = NightShift.NpcTravelService.new({
                locationService = locationService,
                clock = options.clock,
                config = streamingConfig,
                etaEstimator = options.npcTravelEtaEstimator
            })
            if not created then return err end
            npcTravel = created
        end
        local npcEntityRegistry = options.npcEntityRegistry or options.npcEntityService
        if npcEntityRegistry == nil and NightShift.NpcEntityRegistry then
            local created, err = NightShift.NpcEntityRegistry.new({ clock = options.clock })
            if not created then return err end
            npcEntityRegistry = created
        end
        local npcSpawn = options.npcSpawnService or options.npcSpawn
        if npcSpawn == nil and NightShift.NpcSpawnService and npcTravel and npcEntityRegistry then
            local created, err = NightShift.NpcSpawnService.new({
                travelService = npcTravel,
                entityRegistry = npcEntityRegistry,
                locationService = locationService,
                clock = options.clock,
                config = streamingConfig,
                modelAllowlist = options.npcModelAllowlist or streamingConfig.modelAllowlist,
                modelResolver = options.npcModelResolver,
                safeSpawnResolver = options.npcSafeSpawnResolver,
                appearanceResolver = options.npcAppearanceResolver,
                createServerEntity = options.createNpcServerEntity
            })
            if not created then return err end
            npcSpawn = created
        end
        local npcArrival = options.npcArrivalService or options.npcArrival
        if npcArrival == nil and NightShift.NpcArrivalService and npcTravel and npcEntityRegistry then
            local created, err = NightShift.NpcArrivalService.new({
                travelService = npcTravel,
                entityRegistry = npcEntityRegistry,
                bookingService = options.bookingService,
                clock = options.clock,
                distanceCheck = options.npcArrivalDistanceCheck,
                maxDistance = options.npcMaxPlausibleArrivalDistance or streamingConfig.maxPlausibleArrivalDistance
            })
            if not created then return err end
            npcArrival = created
        end
        local npcCustomer = options.npcCustomerService or options.npcCustomer
        if npcCustomer == nil and NightShift.NpcCustomerService and districtService and demandService and workerAvailability and npcProfileGenerator then
            local created, err = NightShift.NpcCustomerService.new({
                districtService = districtService,
                demandService = demandService,
                availabilityService = workerAvailability,
                generator = npcProfileGenerator,
                config = demandConfig,
                enabled = features.demand == true,
                clock = options.clock,
                districtResolver = options.workerDistrictResolver,
                zoneResolver = options.discoveryZoneResolver
            })
            if not created then return err end
            npcCustomer = created
        end
        if framework == nil or databaseDeferred then
            return { ok = true, deferred = true, reason = framework == nil and 'framework adapter not configured' or 'profile repositories deferred', services = {
                location = locationService, locationReservation = locationReservation, vehicleLocation = vehicleLocation,
                npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, marketplace = marketplace,
                npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer
            } }
        end
        local catalog = options.serviceCatalog
        if catalog == nil and features.serviceCatalog ~= false and NightShift.ServiceCatalog then
            local created, err = NightShift.ServiceCatalog.new({ config = config.serviceCatalog })
            if not created then return err end
            catalog = created
        end
        local pricing = options.pricingService
        if pricing == nil and features.pricing ~= false and NightShift.PricingService then
            local created, err = NightShift.PricingService.new({ catalog = catalog, config = config.pricing, clock = options.clock })
            if not created then return err end
            pricing = created
        end
        local negotiation = options.negotiationService or options.negotiation
        if negotiation == nil and NightShift.NegotiationService then
            local created, err = NightShift.NegotiationService.new({ config = config.negotiation or NightShift.NegotiationConfig, clock = options.clock })
            if not created then return err end
            negotiation = created
        end
        local moneyAvailable = type(money) == 'table' and type(money.has) == 'function' and type(money.remove) == 'function' and type(money.add) == 'function'
        if moneyAvailable and type(money.isAvailable) == 'function' then
            local ok, available = pcall(money.isAvailable, money)
            moneyAvailable = ok and available == true
        end
        local deposit = options.depositService
        if deposit == nil and features.deposits == true and moneyAvailable and NightShift.DepositService and repositories.deposit then
            local depositConfig = config.deposit or config.deposits or { enabled = true, percentage = 0, account = 'cash' }
            local created, err = NightShift.DepositService.new({ repository = repositories.deposit, money = money, config = depositConfig, clock = options.clock })
            if not created then return err end
            deposit = created
        end
        local settlement = options.settlementService
        local refund = options.refundService
        local identity = options.identityService
        if identity == nil and NightShift.IdentityService then
            local created, err = NightShift.IdentityService.new({ framework = framework })
            if not created then return err end
            identity = created
        end
        if workerAvailability then
            if workerAvailability._identity == nil then workerAvailability._identity = identity end
            if workerAvailability._profile == nil then workerAvailability._profile = options.workerProfileService end
            if framework and type(framework.onPlayerUnloaded) == 'function' then
                pcall(framework.onPlayerUnloaded, framework, function(value)
                    local source = type(value) == 'table' and value.source or value
                    if source ~= nil then workerAvailability:reset(source, 'logout') end
                end)
            end
        end
        local worker = options.workerProfileService
        if worker == nil and NightShift.WorkerProfileService and repositories.workerProfile and identity then
            local created, err = NightShift.WorkerProfileService.new({ identityService = identity, repository = repositories.workerProfile })
            if not created then return err end
            worker = created
        end
        if workerAvailability and workerAvailability._profile == nil and worker then
            workerAvailability._profile = worker
        end
        local client = options.clientProfileService
        if client == nil and NightShift.ClientProfileService and repositories.clientProfile and identity then
            local created, err = NightShift.ClientProfileService.new({ identityService = identity, repository = repositories.clientProfile })
            if not created then return err end
            client = created
        end
        local permissions = options.permissionService
        if permissions == nil and NightShift.PermissionService and identity then
            local created, err = NightShift.PermissionService.new({
                framework = framework,
                identityService = identity,
                config = options.permissionConfig,
                aceChecker = options.aceChecker,
                provider = options.permissionProvider
            })
            if not created then return err end
            permissions = created
        end
        if not identity or not worker or not client or not permissions then
            return { ok = true, deferred = true, reason = 'identity/profile services unavailable', services = {
                location = locationService, locationReservation = locationReservation, vehicleLocation = vehicleLocation,
                npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, marketplace = marketplace,
                npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer
            } }
        end
        local bookingTimeline = options.bookingTimelineService
        if bookingTimeline == nil and NightShift.BookingTimelineService and repositories.bookingEvent then
            local created, err = NightShift.BookingTimelineService.new({ repository = repositories.bookingEvent, clock = options.clock })
            if not created then return err end
            bookingTimeline = created
        end
        local reservationService = options.bookingReservationService
        if reservationService == nil and NightShift.BookingReservationService and NightShift.Reservations then
            local locks, lockError = NightShift.Reservations.new({ clock = options.clock })
            if not locks then return lockError end
            local created, err = NightShift.BookingReservationService.new({ locks = locks, provider = options.reservationProvider, clock = options.clock })
            if not created then return err end
            reservationService = created
        end
        local booking = options.bookingService
        if booking == nil and NightShift.BookingService and repositories.booking and bookingTimeline then
            local created, err = NightShift.BookingService.new({
                repository = repositories.booking,
                timelineService = bookingTimeline,
                reservationService = reservationService,
                permissionService = permissions,
                catalogResolver = options.catalogResolver or catalog,
                quoteResolver = options.quoteResolver or pricing,
                locationResolver = locationService,
                clock = options.clock
            })
            if not created then return err end
            booking = created
        end
        if settlement == nil and features.payments == true and moneyAvailable and NightShift.SettlementService and repositories.payment then
            local paymentConfig = config.payment or config.payments or { enabled = true, account = 'cash' }
            local created, err = NightShift.SettlementService.new({ repository = repositories.payment, money = money, bookingService = booking, config = paymentConfig, clock = options.clock, depositService = deposit })
            if not created then return err end
            settlement = created
        end
        if refund == nil and features.refunds ~= false and moneyAvailable and NightShift.RefundService and repositories.payment then
            local created, err = NightShift.RefundService.new({ repository = repositories.payment, money = money, bookingService = booking, config = config.cancellation, clock = options.clock, depositService = deposit })
            if not created then return err end
            refund = created
        end
        local appointmentSession = options.appointmentSessionService or options.appointmentSession
        if appointmentSession == nil and NightShift.AppointmentSessionService and booking then
            local created, err = NightShift.AppointmentSessionService.new({
                bookingService = booking,
                locationService = locationService,
                config = config.appointmentSession or NightShift.AppointmentSessionConfig,
                clock = options.clock,
                locationVerifier = options.appointmentLocationVerifier or options.appointmentProximityCheck,
                allowConfiguredLocation = options.appointmentAllowConfiguredLocation == true
            })
            if not created then return err end
            appointmentSession = created
        end
        local workerMode = options.workerModeService or options.workerMode
        if workerMode == nil and NightShift.WorkerModeService and negotiation and npcCustomer and workerAvailability and booking then
            local created, err = NightShift.WorkerModeService.new({
                customerService = npcCustomer,
                negotiationService = negotiation,
                workerAvailabilityService = workerAvailability,
                bookingService = booking,
                serviceCatalog = catalog,
                locationService = locationService,
                locationReservationService = locationReservation,
                appointmentSessionService = appointmentSession,
                settlementService = settlement,
                workerProfileService = worker,
                clock = options.clock
            })
            if not created then return err end
            workerMode = created
        end
        if not bookingTimeline or not reservationService or not booking then
            return { ok = true, deferred = true, reason = 'booking services unavailable', services = {
                location = locationService, locationReservation = locationReservation, vehicleLocation = vehicleLocation,
                npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, marketplace = marketplace,
                npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer
            } }
        end
        if npcArrival and npcArrival._booking == nil then npcArrival._booking = booking end
        return { ok = true, services = {
            identity = identity,
            workerProfile = worker,
            clientProfile = client,
            permissions = permissions,
            bookingTimeline = bookingTimeline,
            bookingReservation = reservationService,
            booking = booking,
            serviceCatalog = catalog,
            pricing = pricing,
            negotiation = negotiation,
            appointmentSession = appointmentSession,
            workerMode = workerMode,
            deposit = deposit,
            settlement = settlement,
            refund = refund,
            location = locationService,
            locationReservation = locationReservation,
            vehicleLocation = vehicleLocation,
            npcProfileGenerator = npcProfileGenerator,
            npcWorker = npcWorker,
            marketplace = marketplace,
            npcTravel = npcTravel,
            npcEntityRegistry = npcEntityRegistry,
            npcSpawn = npcSpawn,
            npcArrival = npcArrival,
            district = districtService,
            demand = demandService,
            workerAvailability = workerAvailability,
            npcCustomer = npcCustomer
        } }
    end
}
for _, stage in ipairs(NightShift.Constants.STAGES) do
    if not defaultStages[stage] then
        defaultStages[stage] = function() return { ok = true, deferred = true } end
    end
end

local function failure(stage, reason)
    if type(reason) == 'table' and reason.code and reason.message then
        local copy = {}
        for key, value in pairs(reason) do copy[key] = value end
        copy.stage = copy.stage or stage
        return copy
    end
    return NightShift.Errors.create(NightShift.Errors.Codes.BOOTSTRAP_STAGE, ('Required stage "%s" failed'):format(stage), {
        stage = stage,
        reason = tostring(reason or 'unknown failure')
    })
end

local Bootstrap = {}
Bootstrap.__index = Bootstrap

function Bootstrap.new(options)
    options = options or {}
    local stageInitializers = options.stages or {}
    local instance = setmetatable({
        readiness = readiness.STARTING,
        error = nil,
        results = {},
        cleanup = {},
        cleanupComplete = false,
        stages = {},
        options = options
    }, Bootstrap)
    for _, stage in ipairs(NightShift.Constants.STAGES) do
        instance.stages[stage] = stageInitializers[stage] or defaultStages[stage]
    end
    instance:registerStopHook()
    return instance
end

function Bootstrap:boot(context)
    if self.readiness == readiness.STOPPED then
        return false, self.error
    end
    self.readiness = readiness.STARTING
    for _, stage in ipairs(NightShift.Constants.STAGES) do
        local initializer = self.stages[stage]
        local ok, result = pcall(initializer, context, self)
        if not ok then
            self.readiness = readiness.FAILED
            self.error = failure(stage, result)
            return false, self.error
        end
        local stageSucceeded = result == true or (type(result) == 'table' and result.ok ~= false and result.success ~= false and (result.ok == true or result.success == true))
        if not stageSucceeded then
            self.readiness = readiness.FAILED
            self.error = failure(stage, type(result) == 'table' and result or 'initializer returned no success result')
            return false, self.error
        end
        self.results[stage] = result
    end
    self.readiness = readiness.READY
    self.error = nil
    return true, self.results
end

function Bootstrap:onCleanup(callback)
    if type(callback) == 'function' and not self.cleanupComplete then
        self.cleanup[#self.cleanup + 1] = callback
    end
    return self
end

function Bootstrap:stop(resourceName)
    if self.cleanupComplete then
        return self.readiness == readiness.STOPPED
    end
    self.cleanupComplete = true
    local cleanupErrors = {}
    for _, callback in ipairs(self.cleanup) do
        local ok, err = pcall(callback, self)
        if not ok then cleanupErrors[#cleanupErrors + 1] = tostring(err) end
    end
    self.readiness = readiness.STOPPED
    if NightShift.Server and NightShift.Server.instance == self then
        NightShift.Server.readiness = self.readiness
        NightShift.Server.error = self.error
    end
    if #cleanupErrors > 0 then
        self.error = NightShift.Errors.create('CLEANUP_FAILED', 'One or more cleanup callbacks failed', {
            resource = resourceName,
            failures = cleanupErrors
        })
    end
    if NightShift.Server and NightShift.Server.instance == self then
        NightShift.Server.readiness = self.readiness
        NightShift.Server.error = self.error
    end
    return true, self.error
end

function Bootstrap:registerStopHook()
    local addEventHandler = rawget(_G, 'AddEventHandler')
    if type(addEventHandler) ~= 'function' then return false end
    local getResourceName = rawget(_G, 'GetCurrentResourceName')
    local ownName = type(getResourceName) == 'function' and getResourceName() or nil
    if ownName == nil then return false end
    addEventHandler('onResourceStop', function(resourceName)
        if resourceName == ownName then self:stop(resourceName) end
    end)
    return true
end

NightShift.ServerBootstrap = Bootstrap
Bootstrap.applyRuntimeConfig = applyRuntimeConfig
Bootstrap.createRuntimeDatabaseAdapter = createRuntimeDatabaseAdapter
NightShift.Server = NightShift.Server or {}
NightShift.Server.readiness = readiness.STARTING

local function logRuntimeBootstrap(ok, result)
    if type(rawget(_G, 'GetCurrentResourceName')) ~= 'function' then return end
    if type(NightShift.Logger) ~= 'table' or type(NightShift.Logger.new) ~= 'function' then return end
    local logger = NightShift.Logger.new()
    if ok then
        local configResult = type(result) == 'table' and result.config or {}
        local dbResult = type(result) == 'table' and result.db or {}
        local config = type(configResult) == 'table' and (configResult.config or configResult.value and configResult.value.config or {}) or {}
        local migrations = type(dbResult) == 'table' and (dbResult.migrations or dbResult.value and dbResult.value.migrations or {}) or {}
        local migrationValue = type(migrations) == 'table' and (migrations.value or migrations) or {}
        local persistence = config.features and config.features.persistence == true
        local database = type(dbResult) == 'table' and dbResult.database ~= nil
        local migrationVersion = migrationValue.currentVersion or 'deferred'
        pcall(logger.info, logger, 'bootstrap', ('NightShift server ready (persistence=%s database=%s migration=%s)'):format(tostring(persistence), tostring(database), tostring(migrationVersion)), {
            persistence = persistence,
            database = database,
            migrationVersion = migrationVersion
        })
        return
    end
    local resultValue = type(result) == 'table' and result or {}
    local errorValue = resultValue.error or resultValue
    if type(errorValue) ~= 'table' then errorValue = {} end
    local code = resultValue.code or errorValue.code or 'BOOTSTRAP_FAILED'
    local details = type(errorValue.details) == 'table' and errorValue.details or {}
    local stage = resultValue.stage or errorValue.stage or details.stage or 'unknown'
    local function boundedString(value, fallback)
        if type(value) ~= 'string' then return fallback end
        local normalized = value:gsub('[%c]+', ' ')
        if #normalized > 160 then normalized = normalized:sub(1, 160) end
        return normalized
    end
    local message = boundedString(errorValue.message, 'unknown startup error')
    local path = boundedString(details.path, nil) or boundedString(details.field, nil)
    local cause = boundedString(details.cause, nil)
    local suffix = (' message=%s%s%s'):format(message, path and (' path=' .. path) or '', cause and (' cause=' .. cause) or '')
    pcall(logger.error, logger, 'bootstrap', ('NightShift server startup failed (code=%s stage=%s)%s'):format(tostring(code), tostring(stage), suffix), {
        code = code,
        stage = stage,
        message = message,
        path = path,
        cause = cause
    })
end

NightShift.Server.bootstrap = function(options, context)
    local instance = Bootstrap.new(options)
    NightShift.Server.instance = instance
    local ok, result = instance:boot(context)
    NightShift.Server.readiness = instance.readiness
    NightShift.Server.error = instance.error
    logRuntimeBootstrap(ok, result)
    return ok, result
end

-- A FiveM resource script executes on load; start the server lifecycle here so
-- `ensure nightshift` cannot leave the resource in STARTING without an
-- explicit external call. Tests and embedders can still create isolated
-- Bootstrap instances through the exported constructor.
if not NightShift.Server.instance then
    NightShift.Server.bootstrap()
end

-- The resource manifest normally loads the development smoke module after this
-- file. Load it from the resource filesystem as a fallback too: a running
-- FXServer may have cached the manifest before a newly added development file
-- existed, and a resource restart alone does not always refresh that file list.
-- FiveM natives are exposed through the script global lookup, not reliably as
-- raw entries in _G. Keep the raw fallback for isolated test/embedded hosts.
local loadResourceFile = type(LoadResourceFile) == 'function' and LoadResourceFile or rawget(_G, 'LoadResourceFile')
local getCurrentResourceName = type(GetCurrentResourceName) == 'function' and GetCurrentResourceName or rawget(_G, 'GetCurrentResourceName')
if type(loadResourceFile) == 'function' and type(getCurrentResourceName) == 'function' then
    local resourceName = getCurrentResourceName()
    local source = loadResourceFile(resourceName, 'server/dev/s10_smoke.lua')
    if type(source) == 'string' and type(load) == 'function' then
        local chunk, loadError = load(source, ('@%s/server/dev/s10_smoke.lua'):format(resourceName), 't', _ENV)
        if type(chunk) == 'function' then
            local ok, runtimeError = pcall(chunk)
            if not ok and type(print) == 'function' then
                print(('[gnsh-nightshift] S10 smoke command loader failed: %s'):format(tostring(runtimeError):sub(1, 160)))
            end
        elseif type(print) == 'function' then
            print(('[gnsh-nightshift] S10 smoke command loader failed: %s'):format(tostring(loadError):sub(1, 160)))
        end
    end
end
