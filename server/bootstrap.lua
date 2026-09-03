NightShift = NightShift or {}

local readiness = NightShift.Enums.Readiness
-- DEGRADED is intentionally declared at the bootstrap boundary so older
-- shared enum files remain load-compatible with the runtime readiness contract.
readiness.DEGRADED = readiness.DEGRADED or 'DEGRADED'

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

local function optionalConvar(name)
    local value = tostring(readConvar(name, ''))
    if value == '' then return nil end
    -- String selectors (environment/provider/framework/money) must not
    -- interpret boolean fallbacks returned by permissive test doubles or
    -- missing convars as real selector values.
    local normalized = value:lower()
    if normalized == 'true' or normalized == 'false' or normalized == '1'
        or normalized == '0' or normalized == 'yes' or normalized == 'no' then
        return nil
    end
    return value
end

local function booleanConvar(name)
    local value = tostring(readConvar(name, ''))
    if value == '' then return nil end
    value = value:lower()
    if value == 'true' or value == '1' or value == 'yes' then return true end
    if value == 'false' or value == '0' or value == 'no' then return false end
    return nil
end

local function applyRuntimeConfig(source)
    if type(source) ~= 'table' then return source end
    local output = copyValue(source)
    local changed = false
    if rawget(output, 'features') == nil then
        output.features = {}
        changed = true
    elseif type(output.features) ~= 'table' then
        return output
    else
        output.features = copyValue(output.features)
    end
    local environment = optionalConvar('nightshift_environment')
    if environment ~= nil then output.environment = environment:lower(); changed = true end
    local provider = optionalConvar('nightshift_provider')
    if provider ~= nil then output.provider = { mode = 'explicit', name = provider }; changed = true end
    local framework = optionalConvar('nightshift_framework')
    if framework ~= nil then output.framework = framework; changed = true end
    local moneyProvider = optionalConvar('nightshift_money_provider')
    if moneyProvider ~= nil then output.moneyProvider = moneyProvider; changed = true end
    local persistence = booleanConvar('nightshift_persistence')
    if persistence ~= nil then output.features.persistence = persistence; changed = true end
    if persistenceConvarEnabled() then output.features.persistence = true; changed = true end
    for _, featureName in ipairs({ 'payments', 'developmentSettlement', 'physicalNpc', 'deposits' }) do
        local configured = booleanConvar('nightshift_' .. featureName)
        if configured ~= nil then output.features[featureName] = configured; changed = true end
    end
    if output.environment == 'production' or output.environment == 'prod' then
        if output.features.developmentSettlement ~= false then
            output.features.developmentSettlement = false
            changed = true
        end
    end
    local recoveryApply = booleanConvar('nightshift_recovery_apply')
    local productionEnvironment = output.environment == 'production' or output.environment == 'prod'
    if output.recovery == nil and productionEnvironment then
        -- A custom production config may omit the recovery table entirely.
        -- Materialize the canonical policy so startup recovery is apply-mode
        -- by default; an explicit convar can still turn it off and fail
        -- readiness instead of silently falling back to dry-run.
        output.recovery = copyValue(NightShift.RecoveryConfig or {})
        changed = true
    end
    if type(output.recovery) == 'table' then
        output.recovery = copyValue(output.recovery)
        if recoveryApply ~= nil then
            output.recovery.apply = recoveryApply
            changed = true
        elseif productionEnvironment then
            output.recovery.apply = true
            changed = true
        end
    end
    return changed and output or source
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

local function syntheticDevelopmentSource(reference, avoid)
    local value = tostring(reference or 'nightshift-npc')
    local hash = 17
    for index = 1, #value do hash = (hash * 31 + string.byte(value, index)) % 15000 end
    local source = 50000 + hash
    if source == avoid then source = source + 1 end
    if source > 64999 then source = 50000 end
    return source
end

local function developmentPayerResolver(booking, actor, request)
    local requested = type(request) == 'table' and tonumber(request.payerSource) or nil
    if requested and requested >= 1 and math.floor(requested) == requested then return requested end
    local workerSource = type(request) == 'table' and tonumber(request.payeeSource) or nil
    if not workerSource and type(actor) == 'table' then workerSource = tonumber(actor.source) end
    if not workerSource and type(booking) == 'table' then workerSource = tonumber(booking.workerSource) end
    local reference = type(booking) == 'table' and (booking.clientRef or booking.clientProfileId or booking.clientProfileKey) or nil
    return syntheticDevelopmentSource(reference, workerSource)
end

local function developmentPayeeResolver(booking, actor, request)
    local requested = type(request) == 'table' and tonumber(request.payeeSource) or nil
    if requested and requested >= 1 and math.floor(requested) == requested and requested ~= (actor and tonumber(actor.source) or nil) then
        return requested
    end
    local reference = type(booking) == 'table' and (booking.workerRef or booking.workerProfileId or booking.workerProfileKey) or 'nightshift-npc'
    return syntheticDevelopmentSource(reference, actor and tonumber(actor.source) or nil)
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
        local agency = options.agencyRepository
        local review = options.reviewRepository
        local favorite = options.favoriteRepository
        local relationship = options.relationshipRepository
        local blacklist = options.blacklistRepository
        local audit = options.auditRepository
        local analytics = options.analyticsRepository
        local idempotency = options.idempotencyRepository or options.idempotency
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
            agency = rawget(context, 'agencyRepository') or agency
            review = rawget(context, 'reviewRepository') or review
            favorite = rawget(context, 'favoriteRepository') or favorite
            relationship = rawget(context, 'relationshipRepository') or relationship
            blacklist = rawget(context, 'blacklistRepository') or blacklist
            audit = rawget(context, 'auditRepository') or audit
            analytics = rawget(context, 'analyticsRepository') or analytics
            idempotency = rawget(context, 'idempotencyRepository') or rawget(context, 'idempotency') or idempotency
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
        if agency == nil and NightShift.Repositories and NightShift.Repositories.Agency then
            local created, err = NightShift.Repositories.Agency.new({ db = database })
            if not created then return err end
            agency = created
        end
        if review == nil and NightShift.Repositories and NightShift.Repositories.Review then
            local created, err = NightShift.Repositories.Review.new({ db = database })
            if not created then return err end
            review = created
        end
        if favorite == nil and NightShift.Repositories and NightShift.Repositories.Favorite then
            local created, err = NightShift.Repositories.Favorite.new({ db = database })
            if not created then return err end
            favorite = created
        end
        if relationship == nil and NightShift.Repositories and NightShift.Repositories.Relationship then
            local created, err = NightShift.Repositories.Relationship.new({ db = database })
            if not created then return err end
            relationship = created
        end
        if blacklist == nil and NightShift.Repositories and NightShift.Repositories.Blacklist then
            local created, err = NightShift.Repositories.Blacklist.new({ db = database })
            if not created then return err end
            blacklist = created
        end
        if audit == nil and NightShift.Repositories and NightShift.Repositories.Audit then
            local created, err = NightShift.Repositories.Audit.new({ db = database })
            if not created then return err end
            audit = created
        end
        if analytics == nil and NightShift.Repositories and NightShift.Repositories.Analytics then
            local created, err = NightShift.Repositories.Analytics.new({ db = database })
            if not created then return err end
            analytics = created
        end
        if idempotency == nil and NightShift.Repositories and NightShift.Repositories.Idempotency then
            local created, err = NightShift.Repositories.Idempotency.new({ db = database })
            if not created then return err end
            idempotency = created
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
            npcProfile = npcProfile,
            agency = agency,
            review = review,
            favorite = favorite,
            relationship = relationship,
            blacklist = blacklist,
            audit = audit,
            analytics = analytics,
            idempotency = idempotency
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
        local auditService = options.auditService or options.audit
        local analyticsService = options.analyticsService or options.analytics
        local diagnosticsService = options.diagnosticsService or options.diagnostics
        local idempotencyStore = options.idempotencyStore or options.idempotencyService or options.idempotency
        local domainEvents = options.domainEvents or options.domainEventService
        local recoveryService = options.recoveryService or options.recovery
        local rateLimiter = options.rateLimiter or options.rateLimit
        local actionTokens = options.actionTokenStore or options.actionTokens
        local eventBus = options.eventBus
        if eventBus == nil and NightShift.EventBus and type(NightShift.EventBus.new) == 'function' then
            local eventClock = type(options.clock) == 'table' and type(options.clock.timestamp) == 'function' and options.clock or nil
            local createdEventBus = NightShift.EventBus.new({ clock = eventClock, logger = options.logger })
            if type(createdEventBus) == 'table' then eventBus = createdEventBus end
        end
        local summaryCache = options.summaryCache or options.analyticsCache
        if summaryCache == nil and features.analytics ~= false and NightShift.SummaryCache then
            local created, err = NightShift.SummaryCache.new({
                config = config.analyticsCache or NightShift.AnalyticsCacheConfig,
                clock = options.clock
            })
            if not created then return err end
            summaryCache = created
        end
        if type(context) == 'table' then framework = rawget(context, 'frameworkAdapter') or framework end
        if type(context) == 'table' then money = rawget(context, 'moneyAdapter') or rawget(context, 'money') or money end
        local databaseDeferred = repositoryResult.deferred == true
        if auditService == nil and features.audit ~= false and NightShift.AuditService and repositories.audit then
            local created, err = NightShift.AuditService.new({
                repository = repositories.audit, clock = options.clock
            })
            if not created then return err end
            auditService = created
        end
        if analyticsService == nil and features.analytics ~= false and NightShift.AnalyticsService and repositories.analytics then
            local created, err = NightShift.AnalyticsService.new({
                repository = repositories.analytics, clock = options.clock,
                cache = summaryCache, eventBus = eventBus,
                cacheEvents = options.analyticsCacheEvents
            })
            if not created then return err end
            analyticsService = created
        end
        if idempotencyStore == nil and features.idempotency ~= false and NightShift.IdempotencyStore then
            local created, err = NightShift.IdempotencyStore.new({
                repository = repositories.idempotency,
                clock = options.clock,
                ttlSeconds = options.idempotencyTtlSeconds,
                maxEntries = options.idempotencyMaxEntries
            })
            if not created then return err end
            idempotencyStore = created
        end
        if domainEvents == nil and features.domainEvents ~= false and NightShift.DomainEvents and eventBus then
            local created, err = NightShift.DomainEvents.new({
                eventBus = eventBus,
                native = options.domainEventsNative
            })
            if not created then return err end
            local attached, attachError = created:attach()
            if type(attached) ~= 'table' or attached.ok ~= true then return attachError or attached end
            domainEvents = created
        end
        local securityConfig = config.security or NightShift.SecurityConfig or {}
        if rateLimiter == nil and features.security ~= false and NightShift.RateLimiter then
            local created, err = NightShift.RateLimiter.new({
                config = securityConfig, clock = options.clock
            })
            if not created then
                if securityConfig.enabled == true then return err end
            else
                rateLimiter = created
            end
        end
        if actionTokens == nil and features.security ~= false and NightShift.ActionTokenStore then
            local created, err = NightShift.ActionTokenStore.new({
                config = securityConfig, environment = config.environment,
                clock = options.clock, audit = auditService
            })
            if not created then
                if securityConfig.enabled == true then return err end
            else
                actionTokens = created
            end
        end
        local phoneRegistry = options.phoneProviderRegistry or options.phoneRegistry
        if phoneRegistry == nil and NightShift.Phone and NightShift.Phone.ProviderRegistry then
            local created, err = NightShift.Phone.ProviderRegistry.new({
                defaultProvider = options.phoneDefaultProvider,
                providers = options.phoneProviders,
                logger = options.logger
            })
            if not created then return err end
            phoneRegistry = created
        end
        if type(options.phoneAdapters) == 'table' and NightShift.PhoneAdapters
            and phoneRegistry and type(phoneRegistry.register) == 'function' then
            for providerName, adapterOptions in pairs(options.phoneAdapters) do
                local definition = NightShift.PhoneAdapters[providerName]
                if type(definition) == 'table' and type(definition.new) == 'function' then
                    local adapter, adapterError = definition.new(adapterOptions)
                    if not adapter then
                        if options.requirePhoneAdapters == true then return adapterError end
                    else
                        local registration = phoneRegistry:register(providerName, adapter, {
                            resource = type(adapterOptions) == 'table' and adapterOptions.resource or nil
                        })
                        if type(registration) ~= 'table' or registration.ok ~= true then
                            if options.requirePhoneAdapters == true then return registration end
                        end
                    end
                elseif options.requirePhoneAdapters == true then
                    return NightShift.Result.err(NightShift.Errors.Codes.PROVIDER_INVALID, 'phone adapter is not registered', { provider = providerName })
                end
            end
        elseif type(options.phoneAdapters) == 'table' and options.requirePhoneAdapters == true then
            return NightShift.Result.err(NightShift.Errors.Codes.PROVIDER_INVALID,
                'phone provider registry cannot register adapters', { stage = 'services' })
        end
        -- Location providers are optional integrations.  Build their
        -- registries here so LocationService receives one stable, typed
        -- provider map regardless of which motel/housing resources are
        -- installed on the server.
        local optionalProviders = type(providers.optional) == 'table' and providers.optional or {}
        local configLocationProvider = options.configLocationProvider or options.configLocationsProvider
        if configLocationProvider == nil and NightShift.OptionalProviders
            and NightShift.OptionalProviders.ConfigLocations then
            local configuredLocations = options.configLocations
            if configuredLocations == nil then configuredLocations = config.locations end
            local created, err = NightShift.OptionalProviders.ConfigLocations.new({
                locations = configuredLocations,
                clock = options.clock,
                accessCheck = options.configLocationAccessCheck or options.locationAccessCheck
            })
            if not created then return err end
            configLocationProvider = created
        end
        local motelRegistry = options.motelProviderRegistry or options.motelRegistry
        if motelRegistry == nil and NightShift.Motel and NightShift.Motel.ProviderRegistry then
            local motelProviders = options.motelProviders
            if type(motelProviders) ~= 'table' and optionalProviders.motel then
                motelProviders = { motel = optionalProviders.motel }
            end
            local created, err = NightShift.Motel.ProviderRegistry.new({
                defaultProvider = options.motelDefaultProvider,
                providers = motelProviders,
                logger = options.logger
            })
            if not created then return err end
            motelRegistry = created
        end
        local housingRegistry = options.housingProviderRegistry or options.housingRegistry
        if housingRegistry == nil and NightShift.Housing and NightShift.Housing.ProviderRegistry then
            local housingProviders = options.housingProviders
            if type(housingProviders) ~= 'table' and optionalProviders.housing then
                housingProviders = { housing = optionalProviders.housing }
            end
            local created, err = NightShift.Housing.ProviderRegistry.new({
                defaultProvider = options.housingDefaultProvider,
                providers = housingProviders,
                logger = options.logger
            })
            if not created then return err end
            housingRegistry = created
        end
        local locationProviderApi = options.locationProviderApi or options.locationProviderAPI
        if locationProviderApi == nil and NightShift.Server
            and NightShift.Server.LocationProviderApi then
            local created, err = NightShift.Server.LocationProviderApi.new({ logger = options.logger })
            if not created then return err end
            locationProviderApi = created
        end
        if locationProviderApi and type(options.customLocationProviders) == 'table'
            and type(locationProviderApi.register) == 'function' then
            for providerName, provider in pairs(options.customLocationProviders) do
                if type(provider) == 'table' then
                    local definition = {}
                    for key, value in pairs(provider) do definition[key] = value end
                    if definition.id == nil and definition.name == nil then definition.id = providerName end
                    local registered = locationProviderApi:register(definition)
                    if type(registered) ~= 'table' or registered.ok ~= true then
                        if options.requireLocationProviders == true then return registered end
                    end
                elseif options.requireLocationProviders == true then
                    return NightShift.Result.err(NightShift.Errors.Codes.PROVIDER_INVALID,
                        'location provider must be a table', { provider = providerName })
                end
            end
        end
        if locationProviderApi and options.installLocationProviderApi ~= false
            and type(locationProviderApi.installSurface) == 'function' then
            local installed, installError = locationProviderApi:installSurface(options.locationProviderApiSurface)
            if type(installed) ~= 'table' or installed.ok ~= true then
                if options.requireLocationProviderApi == true then return installError or installed end
            end
        end
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
        local heatService = options.heatService or options.heat
        if heatService == nil and features.heat ~= false and NightShift.HeatService then
            local created, err = NightShift.HeatService.new({
                config = config.heat or NightShift.HeatConfig,
                clock = options.clock,
                districtResolver = options.heatDistrictResolver or options.eventDistrictResolver
            })
            if not created then return err end
            heatService = created
        end
        if heatService and eventBus and options.attachHeatEvents ~= false
            and type(heatService.attach) == 'function' then
            local attached, attachError = heatService:attach(eventBus, options.heatEventNames)
            if type(attached) ~= 'table' or attached.ok ~= true then
                if options.requireHeatEvents == true then return attachError or attached end
            end
        end
        local feedbackService = options.demandHeatFeedbackService
            or options.demandFeedbackService or options.demandHeatFeedback
        if feedbackService == nil and features.demandHeatFeedback ~= false
            and NightShift.DemandHeatFeedbackService then
            local created, err = NightShift.DemandHeatFeedbackService.new({
                config = config.demandHeatFeedback or config.demandFeedback
                    or NightShift.DemandHeatFeedbackConfig,
                heatService = heatService,
                heatResolver = options.heatResolver,
                clock = options.clock
            })
            if not created then return err end
            feedbackService = created
        end
        local viceService = options.viceService or options.vice
        if viceService == nil and features.vice == true and NightShift.ViceService then
            local optionalProviders = type(providers.optional) == 'table' and providers.optional or {}
            local dispatchProvider = options.viceDispatchProvider or options.dispatchProvider
                or providers.dispatch or optionalProviders.dispatch
            local created, err = NightShift.ViceService.new({
                config = config.vice or NightShift.ViceConfig,
                heatService = heatService,
                districtPressureResolver = options.districtPressureResolver
                    or options.vicePressureResolver,
                archetypeResolver = options.viceArchetypeResolver,
                dispatch = dispatchProvider,
                clock = options.clock
            })
            if not created then return err end
            viceService = created
        end
        local demandService = options.demandService or options.demand
        if demandService == nil and NightShift.DemandService and districtService then
            local heatResolver = options.heatResolver
            if heatResolver == nil and heatService and type(heatService.get) == 'function' then
                heatResolver = function(request, context)
                    local district = type(context) == 'table' and context.district or nil
                    district = type(district) == 'table' and district.id or district
                    local result = heatService:get({
                        playerKey = type(request) == 'table' and request.playerKey or nil,
                        district = district,
                        now = type(request) == 'table' and request.now or nil
                    })
                    if type(result) == 'table' and result.ok then
                        return result.value and result.value.districtPressure or 0
                    end
                    return 0
                end
            end
            local created, err = NightShift.DemandService.new({
                districtService = districtService,
                availabilityService = workerAvailability,
                config = demandConfig,
                enabled = features.demand == true,
                clock = options.clock,
                activeWorkersResolver = options.activeWorkersResolver,
                recentActivityResolver = options.recentActivityResolver,
                policePressureResolver = options.policePressureResolver,
                heatResolver = heatResolver,
                eventResolver = options.demandEventResolver,
                weatherResolver = options.demandWeatherResolver,
                feedbackService = feedbackService
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
        local locationProviders = {}
        local explicitLocationProviders = type(options.locationProviders) == 'table'
        local configuredProviderMap = options.locationProviders
        if type(configuredProviderMap) ~= 'table' then
            configuredProviderMap = type(providers.optional) == 'table' and providers.optional or providers
        end
        if type(configuredProviderMap) == 'table' then
            for providerName, provider in pairs(configuredProviderMap) do
                locationProviders[providerName] = provider
            end
        end
        local function addLocationProvider(providerName, provider, replace)
            if providerName and provider and (replace == true or locationProviders[providerName] == nil) then
                locationProviders[providerName] = provider
            end
        end
        local function registryHasProvider(registry)
            if type(registry) ~= 'table' or type(registry.list) ~= 'function' then return registry ~= nil end
            local listed = registry:list()
            return type(listed) == 'table' and listed.ok == true
                and type(listed.value) == 'table' and #listed.value > 0
        end
        if registryHasProvider(motelRegistry) then
            addLocationProvider('motel', motelRegistry, not explicitLocationProviders)
        end
        if registryHasProvider(housingRegistry) then
            addLocationProvider('housing', housingRegistry, not explicitLocationProviders)
        end
        -- Config locations participate in the same validation/reservation
        -- lifecycle as optional providers.  This keeps opening hours, access,
        -- and provider-side holds authoritative even with no external
        -- housing resource installed.
        if configLocationProvider then
            addLocationProvider('config', configLocationProvider, not explicitLocationProviders)
        end
        if locationProviderApi and type(locationProviderApi.getProviderMap) == 'function' then
            local customMap = locationProviderApi:getProviderMap()
            if type(customMap) == 'table' then
                for providerName, provider in pairs(customMap) do
                    addLocationProvider(providerName, provider)
                end
            end
        end
        local locationDefinitions = config.locations
        if type(options.configLocations) == 'table' and options.configLocations ~= config.locations then
            local merged = {}
            local seen = {}
            for _, location in ipairs(config.locations or {}) do
                local id = type(location) == 'table' and (location.id or location.locationRef)
                if id == nil or not seen[id] then
                    merged[#merged + 1] = location
                    if id ~= nil then seen[id] = true end
                end
            end
            for _, location in ipairs(options.configLocations) do
                local id = type(location) == 'table' and (location.id or location.locationRef)
                if id == nil or not seen[id] then
                    merged[#merged + 1] = location
                    if id ~= nil then seen[id] = true end
                end
            end
            locationDefinitions = merged
        end
        local typedDefinitions = {}
        for index, location in ipairs(locationDefinitions or {}) do
            local definition = location
            local locationType = type(location) == 'table'
                and tostring(location.locationType or location.type or ''):upper() or ''
            if locationType == 'CONFIG_LOCATION' and type(location) == 'table'
                and location.provider == nil then
                definition = copyValue(location)
                definition.provider = 'config'
            end
            typedDefinitions[index] = definition
        end
        locationDefinitions = typedDefinitions
        local locationService = options.locationService
        if locationService == nil and NightShift.LocationService then
            local created, err = NightShift.LocationService.new({
                locations = locationDefinitions,
                repository = repositories.location,
                providers = locationProviders,
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
        if locationProviderApi and locationService
            and type(locationProviderApi.attachLocationService) == 'function' then
            local attached, attachError = locationProviderApi:attachLocationService(locationService)
            if type(attached) ~= 'table' or attached.ok ~= true then
                if options.requireLocationProviderApi == true then return attachError or attached end
            end
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
                providers = locationProviders,
                clock = options.clock,
                defaultTtl = options.locationReservationTtl
            })
            if not created then return err end
            locationReservation = created
        end
        local pickupLocation = options.pickupLocationService or options.pickupLocation
        local pickupVehicle = options.pickupVehicleService or options.pickupVehicle
        local pickupMode = options.pickupModeService or options.pickupMode
        local dualTravel = options.dualTravelService or options.dualTravel
        if pickupLocation == nil and NightShift.PickupLocationService then
            local created, err = NightShift.PickupLocationService.new({
                candidates = config.pickupLocations or NightShift.PickupLocationConfig,
                locationService = locationService,
                locationReservationService = locationReservation,
                bookingLookup = options.pickupBookingLookup,
                routeCheck = options.pickupRouteCheck or options.pickupNavigationCheck,
                blockedZoneCheck = options.pickupBlockedZoneCheck or options.pickupZoneCheck,
                minDistance = options.pickupMinimumDistance,
                maxDistance = options.pickupMaximumDistance,
                reservationTtlSeconds = options.pickupReservationTtlSeconds,
                clock = options.clock
            })
            if not created then return err end
            pickupLocation = created
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
        local npcPool
        -- A logical worker pool is only materialized when physical NPC mode is
        -- enabled.  Standalone/contract boots may still expose the worker
        -- service without requiring a database-backed ped pool.
        if npcWorker and type(npcWorker.ensurePool) == 'function'
            and features.physicalNpc == true
            and (config.npcProfileConfig == nil or config.npcProfileConfig.enabled ~= false) then
            local npcConfig = config.npcProfileConfig or NightShift.NpcProfileConfig or {}
            local poolConfig = type(npcConfig.workerPool) == 'table' and npcConfig.workerPool or {}
            local ensured, ensureError = npcWorker:ensurePool({
                targetSize = options.npcPoolTargetSize or poolConfig.targetSize,
                seed = options.npcPoolSeed or 'bootstrap'
            })
            if type(ensured) ~= 'table' or ensured.ok ~= true then
                local environment = tostring(config.environment or 'development'):lower()
                local strict = environment == 'production' or environment == 'prod'
                    or (type(config.features) == 'table' and config.features.persistence == true)
                    or options.requireNpcPool == true
                if strict then return ensureError or ensured end
            else
                npcPool = ensured.value
            end
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
        local networkConfig = type(config.network) == 'table' and config.network or {}
        local npcStreamingBudget = options.npcStreamingBudgetService or options.npcStreamingBudget
        if npcStreamingBudget == nil and NightShift.NpcStreamingBudgetService then
            local budgetConfig = type(streamingConfig.budget) == 'table' and streamingConfig.budget or {}
            local created, err = NightShift.NpcStreamingBudgetService.new({
                clock = options.clock,
                config = budgetConfig
            })
            if not created then return err end
            npcStreamingBudget = created
        end
        local entityOwnershipPolicy = options.entityOwnershipPolicy or options.entityOwnership
        if entityOwnershipPolicy == nil and NightShift.EntityOwnershipPolicy then
            local ownershipConfig = options.entityOwnershipConfig
                or networkConfig.entityOwnership or networkConfig.ownership
            local created, err = NightShift.EntityOwnershipPolicy.new({ config = ownershipConfig })
            if not created then return err end
            entityOwnershipPolicy = created
        end
        local stateBagPolicy = options.stateBagPolicy or options.stateBags
        if stateBagPolicy == nil and NightShift.StateBagPolicy then
            local stateConfig = options.stateBagConfig
                or networkConfig.stateBag or networkConfig.stateBags
            local created, err = NightShift.StateBagPolicy.new({
                config = stateConfig,
                setState = options.setEntityState,
                getState = options.getEntityState
            })
            if not created then return err end
            stateBagPolicy = created
        end
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
            local created, err = NightShift.NpcEntityRegistry.new({
                clock = options.clock,
                ownershipPolicy = entityOwnershipPolicy
            })
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
                streamingBudget = npcStreamingBudget,
                stateBagPolicy = stateBagPolicy,
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
                locationProviders = locationProviders, configLocations = configLocationProvider,
                motelProviders = motelRegistry, housingProviders = housingRegistry,
                locationProviderApi = locationProviderApi,
                pickupLocation = pickupLocation, pickupVehicle = pickupVehicle, pickupMode = pickupMode, dualTravel = dualTravel,
                npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, npcPool = npcPool, marketplace = marketplace,
                npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                npcStreamingBudget = npcStreamingBudget, entityOwnershipPolicy = entityOwnershipPolicy,
                stateBagPolicy = stateBagPolicy,
                district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer,
                 heat = heatService, demandHeatFeedback = feedbackService, vice = viceService,
                 eventBus = eventBus, summaryCache = summaryCache, phone = phoneRegistry,
                 agency = agencyService, agencyBooking = agencyBookingService, venue = venueService,
                 audit = auditService, analytics = analyticsService, diagnostics = diagnosticsService,
                 idempotency = idempotencyStore, domainEvents = domainEvents, recovery = recoveryService,
                 rateLimiter = rateLimiter, actionTokens = actionTokens
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
            local pricingDemandResolver = options.pricingDemandResolver
            if pricingDemandResolver == nil and demandService and type(demandService.evaluate) == 'function' then
                pricingDemandResolver = function(request)
                    local evaluated = demandService:evaluate(request)
                    if type(evaluated) == 'table' and evaluated.ok == true and type(evaluated.value) == 'table' then
                        return evaluated.value.score or evaluated.value.demandScore
                    end
                    return nil
                end
            end
            local pricingModifierResolver = options.pricingModifierResolver
            if pricingModifierResolver == nil and feedbackService and type(feedbackService.apply) == 'function' then
                pricingModifierResolver = function(request)
                    local demandValue
                    if demandService and type(demandService.evaluate) == 'function' then
                        local evaluated = demandService:evaluate(request)
                        if type(evaluated) == 'table' and evaluated.ok == true then demandValue = evaluated.value end
                    end
                    local feedbackRequest = copyValue(request)
                    if type(demandValue) == 'table' then
                        feedbackRequest.district = feedbackRequest.district or demandValue.district
                        feedbackRequest.demandScore = feedbackRequest.demandScore or demandValue.score or demandValue.demandScore
                        local inputs = type(demandValue.inputs) == 'table' and demandValue.inputs or {}
                        feedbackRequest.heat = feedbackRequest.heat or inputs.heat
                        feedbackRequest.activeWorkers = feedbackRequest.activeWorkers or inputs.activeWorkers
                        feedbackRequest.supplyCapacity = feedbackRequest.supplyCapacity or inputs.supplyCapacity
                    end
                    local applied = feedbackService:apply(feedbackRequest)
                    if type(applied) == 'table' and applied.ok == true and type(applied.value) == 'table' then
                        return applied.value.pricingModifier
                    end
                    return nil
                end
            end
            local created, err = NightShift.PricingService.new({
                catalog = catalog, config = config.pricing, clock = options.clock,
                demandResolver = pricingDemandResolver,
                pricingModifierResolver = pricingModifierResolver
            })
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
        local agencyService = options.agencyService or options.agency
        local agencyBookingService = options.agencyBookingService or options.agencyBooking
        local venueService = options.venueService or options.venue
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
                provider = options.permissionProvider,
                auditService = auditService
            })
            if not created then return err end
            permissions = created
        end
        if diagnosticsService == nil and features.diagnostics ~= false and NightShift.DiagnosticsService then
            local adminCheck = options.diagnosticsAdminCheck
            if adminCheck == nil and permissions and type(permissions.isAllowed) == 'function' then
                adminCheck = function(source)
                    return tonumber(source) == 0 or permissions:isAllowed(source, 'admin.manage') == true
                end
            end
            local dbStage = bootstrap and bootstrap.results and bootstrap.results.db or {}
            local database = dbStage.database or dbStage.value and dbStage.value.database
            local created, err = NightShift.DiagnosticsService.new({
                database = database,
                bookingRepository = repositories.booking,
                paymentRepository = repositories.payment,
                locationReservationRepository = repositories.locationReservation,
                analyticsService = analyticsService,
                auditService = auditService,
                providers = adapterResult.capabilities or providers,
                adminCheck = adminCheck
            })
            if not created then return err end
            diagnosticsService = created
        end
        if not identity or not worker or not client or not permissions then
            return { ok = true, deferred = true, reason = 'identity/profile services unavailable', services = {
                location = locationService, locationReservation = locationReservation, vehicleLocation = vehicleLocation,
                locationProviders = locationProviders, configLocations = configLocationProvider,
                motelProviders = motelRegistry, housingProviders = housingRegistry,
                locationProviderApi = locationProviderApi,
                pickupLocation = pickupLocation, pickupVehicle = pickupVehicle, pickupMode = pickupMode, dualTravel = dualTravel,
                 npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, npcPool = npcPool, marketplace = marketplace,
                 npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                 npcStreamingBudget = npcStreamingBudget, entityOwnershipPolicy = entityOwnershipPolicy,
                 stateBagPolicy = stateBagPolicy,
                 district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer,
                 heat = heatService, demandHeatFeedback = feedbackService, vice = viceService,
                 phone = phoneRegistry,
                 agency = agencyService, agencyBooking = agencyBookingService, venue = venueService,
                  audit = auditService, analytics = analyticsService, diagnostics = diagnosticsService,
                  idempotency = idempotencyStore, domainEvents = domainEvents, recovery = recoveryService,
                  rateLimiter = rateLimiter, actionTokens = actionTokens
            } }
        end
        local blacklistService = options.blacklistService
        if blacklistService == nil and NightShift.BlacklistService and repositories.blacklist and identity then
            local created, err = NightShift.BlacklistService.new({
                repository = repositories.blacklist, identityService = identity,
                agencyResolver = options.blacklistAgencyResolver
            })
            if not created then return err end
            blacklistService = created
        end
        if marketplace and blacklistService and marketplace._blacklist == nil then marketplace._blacklist = blacklistService end
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
        local scheduleConflict = options.scheduleConflictService or options.scheduleConflict
        if scheduleConflict == nil and NightShift.ScheduleConflictService and repositories.booking then
            local created, err = NightShift.ScheduleConflictService.new({
                repository = repositories.booking,
                config = config.scheduling or NightShift.SchedulingConfig,
                clock = options.clock
            })
            if not created then return err end
            scheduleConflict = created
        end
        if booking == nil and NightShift.BookingService and repositories.booking and bookingTimeline then
            local created, err = NightShift.BookingService.new({
                repository = repositories.booking,
                timelineService = bookingTimeline,
                reservationService = reservationService,
                permissionService = permissions,
                catalogResolver = options.catalogResolver or catalog,
                quoteResolver = options.quoteResolver or pricing,
                locationResolver = locationService,
                eventBus = eventBus,
                districtResolver = options.bookingDistrictResolver or options.eventDistrictResolver,
                clock = options.clock,
                scheduleConflictService = scheduleConflict
            })
            if not created then return err end
            booking = created
        end
        if agencyService == nil and features.agencies ~= false and NightShift.AgencyService
            and repositories.agency then
            local adminCheck = options.agencyAdminCheck
            if adminCheck == nil and permissions and type(permissions.isAllowed) == 'function' then
                adminCheck = function(source)
                    if tonumber(source) == 0 then return true end
                    return permissions:isAllowed(source, 'agency.manage') == true
                end
            end
            local created, err = NightShift.AgencyService.new({
                repository = repositories.agency,
                adminCheck = adminCheck
            })
            if not created then return err end
            agencyService = created
        end
        if venueService == nil and features.venues ~= false and NightShift.VenueService then
            local venueAdminCheck = options.venueAdminCheck
            if venueAdminCheck == nil and permissions and type(permissions.isAllowed) == 'function' then
                venueAdminCheck = function(source)
                    if tonumber(source) == 0 then return true end
                    return permissions:isAllowed(source, 'venue.manage') == true
                end
            end
            local created, err = NightShift.VenueService.new({
                repository = options.venueRepository or repositories.venue,
                venues = options.venues or config.venues or NightShift.VenueConfig,
                clock = options.clock,
                adminCheck = venueAdminCheck,
                auditService = auditService
            })
            if not created then return err end
            venueService = created
        end
        if agencyBookingService == nil and features.agencies ~= false
            and NightShift.AgencyBookingService and agencyService and booking then
            local created, err = NightShift.AgencyBookingService.new({
                agencyService = agencyService,
                bookingService = booking,
                workerAvailabilityService = workerAvailability
            })
            if not created then return err end
            agencyBookingService = created
        end
        local incidentService = options.incidentService or options.incident
        if incidentService == nil and features.incidents ~= false and NightShift.IncidentService and repositories.booking and bookingTimeline then
            local created, err = NightShift.IncidentService.new({
                repository = repositories.booking,
                timelineService = bookingTimeline,
                eventBus = eventBus,
                clock = options.clock
            })
            if not created then return err end
            incidentService = created
        end
        local disputeService = options.disputeService or options.dispute
        if disputeService == nil and features.disputes ~= false and NightShift.DisputeService and repositories.booking and bookingTimeline then
            local created, err = NightShift.DisputeService.new({
                repository = repositories.booking,
                timelineService = bookingTimeline,
                paymentResolver = options.disputePaymentResolver or options.paymentStateResolver,
                paymentService = options.disputePaymentService
            })
            if not created then return err end
            disputeService = created
        end
        local safetyService = options.safetyService or options.safety
        if safetyService == nil and features.safety ~= false and NightShift.SafetyService and booking then
            local optionalProviders = type(providers.optional) == 'table' and providers.optional or {}
            local dispatchProvider = options.safetyDispatchProvider or options.dispatchProvider or providers.dispatch or optionalProviders.dispatch
            local securityProvider = options.safetySecurityProvider or options.securityProvider or providers.security or optionalProviders.security
            local created, err = NightShift.SafetyService.new({
                bookingService = booking,
                dispatch = dispatchProvider,
                security = securityProvider,
                clock = options.clock,
                checkInIntervalSeconds = options.safetyCheckInIntervalSeconds
            })
            if not created then return err end
            safetyService = created
        end
        if vehicleLocation and vehicleLocation._bookingLookup == nil and booking and type(booking.get) == 'function' then
            vehicleLocation._bookingLookup = function(bookingId)
                local value = booking:get(bookingId)
                if type(value) == 'table' and value.ok ~= nil then return value.ok and value.value or nil end
                return value
            end
        end
        local pickupVehicleResolver = options.pickupVehicleResolver or vehicleLocation
        if pickupVehicle == nil and NightShift.PickupVehicleService and booking and pickupVehicleResolver then
            local created, err = NightShift.PickupVehicleService.new({
                bookingService = booking,
                identityService = identity,
                vehicleLocationService = pickupVehicleResolver,
                seatCheck = options.pickupSeatCheck or options.vehicleSeatCheck,
                npcNearby = options.pickupNpcNearby or options.vehicleNpcNearby,
                accessCheck = options.pickupVehicleAccessCheck,
                allowVehicleChange = options.pickupAllowVehicleChange == true,
                onEnter = options.pickupVehicleOnEnter,
                clock = options.clock
            })
            if not created then return err end
            pickupVehicle = created
        end
        local clientBooking = options.clientBookingQueryService or options.clientBookingQuery
        if clientBooking == nil and NightShift.ClientBookingQueryService and repositories.booking and identity then
            local created, err = NightShift.ClientBookingQueryService.new({
                repository = repositories.booking,
                identityService = identity,
                clientProfileService = client,
                workerService = npcWorker,
                maxPageSize = options.clientBookingMaxPageSize,
                etaResolver = options.clientBookingEtaResolver,
                clock = options.clock
            })
            if not created then return err end
            clientBooking = created
        end
        local clientBookingCommands = options.clientBookingCommandService or options.clientBookingCommands
        if clientBookingCommands == nil and NightShift.ClientBookingCommandService and repositories.booking and booking and pricing and identity and npcWorker and reservationService then
            local created, err = NightShift.ClientBookingCommandService.new({
                repository = repositories.booking,
                bookingService = booking,
                pricingService = pricing,
                identityService = identity,
                workerService = npcWorker,
                reservationService = reservationService,
                reservationTtlSeconds = options.clientBookingReservationTtlSeconds,
                quoteWindowSeconds = options.clientBookingQuoteWindowSeconds or pricing and pricing._config and pricing._config.quoteTtlSeconds,
                clock = options.clock
            })
            if not created then return err end
            clientBookingCommands = created
        end
        if settlement == nil and features.payments == true and moneyAvailable and NightShift.SettlementService and repositories.payment then
            local paymentConfig = config.payment or config.payments or { enabled = true, account = 'cash' }
            local created, err = NightShift.SettlementService.new({
                repository = repositories.payment, money = money, bookingService = booking,
                config = paymentConfig, clock = options.clock, depositService = deposit,
                commissionSplitResolver = options.commissionSplitResolver or options.settlementSplitResolver,
                commissionHook = options.commissionHook or options.commissionResolver,
                timelineService = bookingTimeline, auditService = auditService
            })
            if not created then return err end
            settlement = created
        end
        if settlement == nil and config.environment == 'development' and features.payments ~= true and features.developmentSettlement == true and NightShift.DevelopmentMoneyAdapter and NightShift.SettlementService and repositories.payment and booking then
            local developmentMoney, moneyError = NightShift.DevelopmentMoneyAdapter.new({ enabled = true })
            if not developmentMoney then return moneyError end
            local created, err = NightShift.SettlementService.new({
                repository = repositories.payment,
                money = developmentMoney,
                bookingService = booking,
                config = { enabled = true, account = 'virtual' },
                payerResolver = developmentPayerResolver,
                payeeResolver = developmentPayeeResolver,
                clock = options.clock,
                depositService = deposit,
                commissionSplitResolver = options.commissionSplitResolver or options.settlementSplitResolver,
                commissionHook = options.commissionHook or options.commissionResolver,
                timelineService = bookingTimeline,
                auditService = auditService
            })
            if not created then return err end
            settlement = created
            if type(print) == 'function' then print('[gnsh-nightshift] development settlement enabled (dry-run; no money effects)') end
        end
        if refund == nil and features.refunds ~= false and moneyAvailable and NightShift.RefundService and repositories.payment then
            local created, err = NightShift.RefundService.new({
                repository = repositories.payment, money = money, bookingService = booking,
                config = config.cancellation, clock = options.clock, depositService = deposit,
                auditService = auditService
            })
            if not created then return err end
            refund = created
        end
        local appointmentSession = options.appointmentSessionService or options.appointmentSession
        if appointmentSession == nil and NightShift.AppointmentSessionService and booking then
            local created, err = NightShift.AppointmentSessionService.new({
                bookingService = booking,
                locationService = locationService,
                config = config.appointmentSession or NightShift.AppointmentSessionConfig,
                environment = config.environment,
                clock = options.clock,
                locationVerifier = options.appointmentLocationVerifier or options.appointmentProximityCheck,
                allowConfiguredLocation = options.appointmentAllowConfiguredLocation
            })
            if not created then return err end
            appointmentSession = created
        end
        if pickupMode == nil and NightShift.PickupModeService and booking and repositories.booking and identity and npcWorker and pickupLocation and pickupVehicle then
            local created, err = NightShift.PickupModeService.new({
                bookingService = booking,
                repository = repositories.booking,
                identityService = identity,
                workerService = npcWorker,
                locationService = locationService,
                locationReservationService = locationReservation,
                pickupLocationService = pickupLocation,
                pickupVehicleService = pickupVehicle,
                depositService = deposit,
                travelService = npcTravel,
                spawnService = npcSpawn,
                arrivalService = npcArrival,
                entityRegistry = npcEntityRegistry,
                appointmentSessionService = appointmentSession,
                settlementService = settlement,
                reservationTtlSeconds = options.pickupReservationTtlSeconds or options.clientModeReservationTtlSeconds or options.clientBookingReservationTtlSeconds,
                travelMode = options.pickupTravelMode or options.clientModeTravelMode,
                originResolver = options.pickupOriginResolver,
                clock = options.clock
            })
            if not created then return err end
            pickupMode = created
        end
        if dualTravel == nil and NightShift.DualTravelService and booking and repositories.booking and identity and npcWorker and locationService and locationReservation then
            local proximity = options.dualClientProximityCheck or options.meetThereProximityCheck
            if proximity == nil and appointmentSession and type(appointmentSession._verifyLocation) == 'function' then
                proximity = function(playerSource, currentBooking, _, payload)
                    local actor = { type = 'PLAYER', ref = currentBooking.clientRef, source = playerSource }
                    local request = { locationType = currentBooking.locationType, locationRef = currentBooking.locationRef, position = payload and payload.position }
                    local ok = appointmentSession:_verifyLocation(actor, currentBooking, request)
                    return ok == true
                end
            end
            local created, err = NightShift.DualTravelService.new({
                bookingService = booking, repository = repositories.booking, identityService = identity,
                workerService = npcWorker, locationService = locationService,
                locationReservationService = locationReservation, depositService = deposit,
                refundService = refund, travelService = npcTravel, spawnService = npcSpawn,
                arrivalService = npcArrival, appointmentSessionService = appointmentSession,
                settlementService = settlement, clientProximityCheck = proximity,
                gracePeriodSeconds = options.dualGracePeriodSeconds or options.meetThereGracePeriodSeconds,
                reservationTtlSeconds = options.dualReservationTtlSeconds or options.clientModeReservationTtlSeconds,
                travelMode = options.dualTravelMode or options.clientModeTravelMode,
                originResolver = options.dualOriginResolver or options.meetThereOriginResolver, clock = options.clock
            })
            if not created then return err end
            dualTravel = created
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
        local clientMode = options.clientModeService or options.clientMode
        if clientMode == nil and features.clientMode ~= false and NightShift.ClientModeService and repositories.booking and booking and identity and npcWorker then
            local created, err = NightShift.ClientModeService.new({
                bookingService = booking,
                repository = repositories.booking,
                identityService = identity,
                workerService = npcWorker,
                locationService = locationService,
                locationReservationService = locationReservation,
                depositService = deposit,
                travelService = npcTravel,
                spawnService = npcSpawn,
                arrivalService = npcArrival,
                appointmentSessionService = appointmentSession,
                settlementService = settlement,
                pickupModeService = pickupMode,
                dualTravelService = dualTravel,
                reservationTtlSeconds = options.clientModeReservationTtlSeconds or options.clientBookingReservationTtlSeconds,
                travelMode = options.clientModeTravelMode,
                originResolver = options.clientModeOriginResolver,
                clock = options.clock
            })
            if not created then return err end
            clientMode = created
        end
        if clientBookingCommands and clientMode then clientBookingCommands._clientMode = clientMode end
        local reputation = options.reputationService or options.reputation
        if reputation == nil and features.reputation ~= false and NightShift.ReputationService and
            repositories.workerProfile and repositories.clientProfile then
            local created, err = NightShift.ReputationService.new({
                workerProfileRepository = repositories.workerProfile,
                clientProfileRepository = repositories.clientProfile,
                npcProfileRepository = repositories.npcProfile,
                npcWorkerService = npcWorker,
                identityService = identity,
                projectionRepository = repositories.bookingEvent,
                config = config.reputation or NightShift.ReputationConfig,
                clock = options.clock
            })
            if not created then return err end
            reputation = created
        end
        if reputation and eventBus and type(reputation.subscribe) == 'function' then
            local subscribed, subscribeError = reputation:subscribe(eventBus)
            if type(subscribed) ~= 'table' or not subscribed.ok then return subscribeError or subscribed end
        end
        local reviewService = options.reviewService or options.review
        if reviewService == nil and features.reputation ~= false and NightShift.ReviewService and repositories.review and booking then
            local created, err = NightShift.ReviewService.new({
                repository = repositories.review,
                bookingService = booking,
                identityService = identity,
                clientProfileService = client,
                clientProfileRepository = repositories.clientProfile,
                npcWorkerService = npcWorker,
                workerProfileService = worker,
                npcProfileRepository = repositories.npcProfile,
                config = config.reputation or NightShift.ReputationConfig
            })
            if not created then return err end
            reviewService = created
        end
        local favoriteService = options.favoriteService or options.favorite
        if favoriteService == nil and features.reputation ~= false and NightShift.FavoriteService and repositories.favorite and identity and npcWorker then
            local created, err = NightShift.FavoriteService.new({
                repository = repositories.favorite,
                identityService = identity,
                clientProfileService = client,
                clientProfileRepository = repositories.clientProfile,
                npcWorkerService = npcWorker,
                config = config.reputation or NightShift.ReputationConfig,
                persistentOnly = options.favoritePersistentOnly
            })
            if not created then return err end
            favoriteService = created
        end
        local relationshipService = options.relationshipService or options.relationship
        if relationshipService == nil and features.reputation ~= false and NightShift.RelationshipService and repositories.relationship then
            local created, err = NightShift.RelationshipService.new({
                repository = repositories.relationship,
                identityService = identity,
                clientProfileService = client,
                clientProfileRepository = repositories.clientProfile,
                npcWorkerService = npcWorker,
                clientBookingCommandService = clientBookingCommands,
                projectionRepository = repositories.bookingEvent,
                config = config.reputation or NightShift.ReputationConfig
            })
            if not created then return err end
            relationshipService = created
        end
        if relationshipService and eventBus and type(relationshipService.subscribe) == 'function' then
            local subscribed, subscribeError = relationshipService:subscribe(eventBus)
            if type(subscribed) ~= 'table' or not subscribed.ok then return subscribeError or subscribed end
        end
        local bookAgain = options.bookAgainService or options.bookAgain
        if bookAgain == nil and features.reputation ~= false and NightShift.BookAgainService and clientBookingCommands and npcWorker then
            local created, err = NightShift.BookAgainService.new({
                clientBookingCommandService = clientBookingCommands,
                npcWorkerService = npcWorker,
                relationshipService = relationshipService,
                bookingService = booking,
                clock = options.clock
            })
            if not created then return err end
            bookAgain = created
        end
        if recoveryService == nil and features.recovery ~= false and NightShift.RecoveryService
            and repositories.booking and type(repositories.booking.findAll) == 'function' then
            local created, err = NightShift.RecoveryService.new({
                bookingRepository = repositories.booking,
                bookingService = booking,
                bookingReservationService = reservationService,
                locationReservationService = locationReservation,
                locationReservationRepository = repositories.locationReservation,
                npcProfileRepository = repositories.npcProfile,
                npcWorkerService = npcWorker,
                workerAvailabilityService = workerAvailability,
                clientModeService = clientMode,
                workerModeService = workerMode,
                npcTravelService = npcTravel,
                npcEntityRegistry = npcEntityRegistry,
                depositService = deposit,
                refundService = refund,
                settlementService = settlement,
                auditService = auditService,
                eventBus = eventBus,
                clock = options.clock,
                config = config.recovery,
                environment = config.environment,
                settlementRecoveryResolver = options.settlementRecoveryResolver or options.recoverySettlementResolver,
                systemActor = options.recoverySystemActor,
                actorResolver = options.recoveryActorResolver
            })
            if not created then
                if config.recovery and config.recovery.required == true then return err end
            else
                recoveryService = created
            end
        end
        if not bookingTimeline or not reservationService or not booking then
            return { ok = true, deferred = true, reason = 'booking services unavailable', services = {
                location = locationService, locationReservation = locationReservation, vehicleLocation = vehicleLocation,
                locationProviders = locationProviders, configLocations = configLocationProvider,
                motelProviders = motelRegistry, housingProviders = housingRegistry,
                locationProviderApi = locationProviderApi,
                pickupLocation = pickupLocation, pickupVehicle = pickupVehicle, pickupMode = pickupMode, dualTravel = dualTravel,
                npcProfileGenerator = npcProfileGenerator, npcWorker = npcWorker, npcPool = npcPool, marketplace = marketplace,
                npcTravel = npcTravel, npcEntityRegistry = npcEntityRegistry, npcSpawn = npcSpawn, npcArrival = npcArrival,
                npcStreamingBudget = npcStreamingBudget, entityOwnershipPolicy = entityOwnershipPolicy,
                stateBagPolicy = stateBagPolicy,
                district = districtService, demand = demandService, workerAvailability = workerAvailability, npcCustomer = npcCustomer,
                heat = heatService, demandHeatFeedback = feedbackService, vice = viceService,
                clientBooking = clientBooking, clientBookingCommands = clientBookingCommands, clientMode = clientMode,
                  eventBus = eventBus, summaryCache = summaryCache, reputation = reputation, review = reviewService,
                favorite = favoriteService, relationship = relationshipService, blacklist = blacklistService,
                 bookAgain = bookAgain, incident = incidentService, dispute = disputeService, safety = safetyService,
                 idempotency = idempotencyStore, domainEvents = domainEvents, recovery = recoveryService,
                 rateLimiter = rateLimiter, actionTokens = actionTokens
            } }
        end
        if npcArrival and npcArrival._booking == nil then npcArrival._booking = booking end
        if npcArrival and npcArrival._actorResolver == nil and identity then
            npcArrival._actorResolver = function(playerSource)
                local resolved = identity:resolve(playerSource)
                if type(resolved) == 'table' and resolved.ok and resolved.value then
                    local reference = resolved.value.identityKey or resolved.value.key
                    if reference then return { type = 'PLAYER', ref = reference, source = playerSource } end
                end
                return { type = 'PLAYER', ref = tostring(playerSource), source = playerSource }
            end
        end
        local function cleanupPlayer(playerSource, reason)
            if playerSource == nil then return end
            if type(recoveryService) == 'table' and type(recoveryService.disconnect) == 'function' then
                return recoveryService:disconnect(playerSource, reason or 'player-disconnected')
            end
            local results = {}
            if type(workerMode) == 'table' and type(workerMode.disconnect) == 'function' then
                results[#results + 1] = workerMode:disconnect(playerSource, reason or 'player-disconnected')
            end
            if type(clientMode) == 'table' and type(clientMode.disconnect) == 'function' then
                results[#results + 1] = clientMode:disconnect(playerSource, reason or 'player-disconnected')
            end
            if type(workerAvailability) == 'table' and type(workerAvailability.reset) == 'function' then
                results[#results + 1] = workerAvailability:reset(playerSource, reason or 'player-disconnected')
            end
            return results
        end
        local addEventHandler = rawget(_G, 'AddEventHandler')
        if type(addEventHandler) == 'function' and (recoveryService or workerMode or clientMode) then
            addEventHandler('playerDropped', function(reason)
                cleanupPlayer(source, reason or 'player-dropped')
            end)
        end
        if type(bootstrap.onCleanup) == 'function' and (recoveryService or workerMode or clientMode) then
            bootstrap:onCleanup(function()
                local getPlayers = rawget(_G, 'GetPlayers')
                if type(getPlayers) ~= 'function' then return end
                local players = getPlayers()
                if type(players) ~= 'table' then return end
                for _, playerSource in ipairs(players) do
                    cleanupPlayer(playerSource, 'resource-stopping')
                end
            end)
        end
        if framework and (recoveryService or clientMode) and type(framework.onPlayerUnloaded) == 'function' then
            pcall(framework.onPlayerUnloaded, framework, function(value)
                local playerSource = type(value) == 'table' and value.source or value
                if playerSource == nil then return end
                cleanupPlayer(playerSource, 'framework-player-unloaded')
            end)
        end
        return { ok = true, services = {
            identity = identity,
            workerProfile = worker,
            clientProfile = client,
            permissions = permissions,
            bookingTimeline = bookingTimeline,
            bookingReservation = reservationService,
            booking = booking,
            eventBus = eventBus,
            reputation = reputation,
            review = reviewService,
            favorite = favoriteService,
            relationship = relationshipService,
            blacklist = blacklistService,
            bookAgain = bookAgain,
            incident = incidentService,
            dispute = disputeService,
            safety = safetyService,
            clientBooking = clientBooking,
            clientBookingCommands = clientBookingCommands,
            serviceCatalog = catalog,
            pricing = pricing,
            negotiation = negotiation,
            appointmentSession = appointmentSession,
            workerMode = workerMode,
            clientMode = clientMode,
            pickupLocation = pickupLocation,
            pickupVehicle = pickupVehicle,
            pickupMode = pickupMode,
            dualTravel = dualTravel,
            deposit = deposit,
            settlement = settlement,
            refund = refund,
            location = locationService,
            locationReservation = locationReservation,
            locationProviders = locationProviders,
            configLocations = configLocationProvider,
            motelProviders = motelRegistry,
            housingProviders = housingRegistry,
            locationProviderApi = locationProviderApi,
            vehicleLocation = vehicleLocation,
            npcProfileGenerator = npcProfileGenerator,
            npcWorker = npcWorker,
            npcPool = npcPool,
            marketplace = marketplace,
            npcTravel = npcTravel,
            npcEntityRegistry = npcEntityRegistry,
            npcSpawn = npcSpawn,
            npcArrival = npcArrival,
            npcStreamingBudget = npcStreamingBudget,
            entityOwnershipPolicy = entityOwnershipPolicy,
            stateBagPolicy = stateBagPolicy,
            district = districtService,
            demand = demandService,
            heat = heatService,
            demandHeatFeedback = feedbackService,
            vice = viceService,
            phone = phoneRegistry,
            workerAvailability = workerAvailability,
            npcCustomer = npcCustomer,
            scheduleConflict = scheduleConflict,
            agency = agencyService,
            agencyBooking = agencyBookingService,
            venue = venueService,
            audit = auditService,
            analytics = analyticsService,
            summaryCache = summaryCache,
            diagnostics = diagnosticsService,
            idempotency = idempotencyStore,
            domainEvents = domainEvents,
            recovery = recoveryService,
            rateLimiter = rateLimiter,
            actionTokens = actionTokens
        } }
    end
}

defaultStages.jobs = function(context, bootstrap)
    local options = bootstrap and bootstrap.options or {}
    local serviceResult = bootstrap and bootstrap.results and bootstrap.results.services or {}
    local repositoryResult = bootstrap and bootstrap.results and bootstrap.results.repositories or {}
    local services = serviceResult.services or serviceResult.value and serviceResult.value.services or {}
    local repositories = repositoryResult.repositories or repositoryResult.value and repositoryResult.value.repositories or {}
    local configResult = bootstrap and bootstrap.results and bootstrap.results.config or {}
    local config = configResult.config or configResult.value and configResult.value.config or NightShift.DefaultConfig
    local features = type(config.features) == 'table' and config.features or {}
    local schedulingConfig = config.scheduling or NightShift.SchedulingConfig or {}
    local recoveryConfig = config.recovery or NightShift.RecoveryConfig or {}
    local recoveryService = options.recoveryService or options.recovery or services.recovery
    local productionEnvironment = tostring(config.environment or ''):lower() == 'production'
        or tostring(config.environment or ''):lower() == 'prod'
    if productionEnvironment and (features.recovery == false or recoveryConfig.enabled == false
        or NightShift.StartupRecoveryJob == nil) then
        return NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_REQUIRED,
            'production startup recovery is required before READY')
    end
    local startupRecovery, recoverySummary
    if features.recovery ~= false and recoveryConfig.enabled ~= false and NightShift.StartupRecoveryJob then
        if type(recoveryService) == 'table' and type(recoveryService.runOnce) == 'function' then
            local created, err = NightShift.StartupRecoveryJob.new({
                recoveryService = recoveryService, config = recoveryConfig, clock = options.clock,
                environment = config.environment
            })
            if created then
                startupRecovery = created
                if options.runStartupRecovery ~= false then
                    local result = startupRecovery:runOnce(nil)
                    if type(result) == 'table' and result.ok then
                        recoverySummary = result.value
                    elseif recoveryConfig.required == true
                        or tostring(config.environment or ''):lower() == 'production'
                        or tostring(config.environment or ''):lower() == 'prod'
                        or options.requireRecoveryJob == true then
                        return result
                    else
                        recoverySummary = { deferred = true, failed = 1 }
                    end
                elseif productionEnvironment then
                    return NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_REQUIRED,
                        'production startup recovery cannot be skipped before READY')
                end
            elseif recoveryConfig.required == true
                or tostring(config.environment or ''):lower() == 'production'
                or tostring(config.environment or ''):lower() == 'prod'
                or options.requireRecoveryJob == true then
                return err
            end
        elseif recoveryConfig.required == true
            or tostring(config.environment or ''):lower() == 'production'
            or tostring(config.environment or ''):lower() == 'prod'
            or options.requireRecoveryJob == true then
            return NightShift.Result.err(NightShift.Errors.Codes.RECOVERY_NOT_READY, 'startup recovery service is unavailable')
        end
    end
    local heat = options.heatService or services.heat
    local heatDecay = options.heatDecayJob or options.heatDecay
    if heatDecay == nil and features.heat ~= false and heat and NightShift.HeatDecayJob then
        local created, err = NightShift.HeatDecayJob.new({
            heatService = heat,
            config = config.heat or NightShift.HeatConfig,
            clock = options.clock
        })
        if not created then return err end
        heatDecay = created
    end
    local runtimeLoop = type(CreateThread) == 'function' and type(Wait) == 'function'
    local heatStarted = false
    local streamingBudget = options.npcStreamingBudgetService or options.npcStreamingBudget or services.npcStreamingBudget
    local streamingStarted = false
    local function isStreamingLeaseActive(lease)
        local registry = options.npcEntityRegistry or options.npcEntityService or services.npcEntityRegistry
        if type(registry) ~= 'table' or type(registry.get) ~= 'function' then return false end
        if type(lease) ~= 'table' or type(lease.npcId) ~= 'string' then return false end
        local current = registry:get(lease.npcId)
        if type(current) ~= 'table' or current.ok ~= true or type(current.value) ~= 'table' then return false end
        local state = tostring(current.value.state or ''):upper()
        local entity = current.value.entity
        if state ~= 'BOUND' or entity == nil then return false end
        local doesEntityExist = type(DoesEntityExist) == 'function' and DoesEntityExist or rawget(_G, 'DoesEntityExist')
        if type(doesEntityExist) == 'function' then
            local ok, exists = pcall(doesEntityExist, entity)
            if not ok or exists ~= true then return false end
        end
        return true
    end
    local function startStreamingBudget()
        if streamingBudget == nil or type(streamingBudget.start) ~= 'function' then
            return { ok = true, skipped = true }
        end
        if options.startNpcStreamingBudget == false then
            return { ok = true, skipped = true, disabled = true }
        end
        if not runtimeLoop then
            return { ok = true, skipped = true, runtimeUnavailable = true }
        end
        local started = streamingBudget:start({ isLeaseActive = isStreamingLeaseActive })
        if type(started) == 'table' and started.ok == true then
            local value = type(started.value) == 'table' and started.value or {}
            streamingStarted = value.running == true
        end
        return started
    end
    local streamingStart = startStreamingBudget()
    if type(streamingStart) ~= 'table' or not streamingStart.ok then
        if options.requireNpcStreamingBudget == true then return streamingStart end
    end
    if type(bootstrap.onCleanup) == 'function' then
        bootstrap:onCleanup(function()
            if streamingStarted and streamingBudget and type(streamingBudget.stop) == 'function' then
                streamingBudget:stop()
            end
        end)
    end
    local function startHeatDecay()
        if heatDecay == nil or options.startHeatDecayJob == false then
            return { ok = true, skipped = true }
        end
        if not runtimeLoop then
            return NightShift.Result.err(NightShift.Errors.Codes.HEAT_OPERATION_FAILED, 'heat decay runtime loop is unavailable')
        end
        local started = heatDecay:start()
        if type(started) == 'table' and started.ok then heatStarted = true end
        return started
    end
    if features.scheduling == false or schedulingConfig.enabled == false then
        local started, startError = startHeatDecay()
        if type(started) ~= 'table' or not started.ok then
            if options.requireHeatDecayJob == true then return startError or started end
        end
        if type(bootstrap.onCleanup) == 'function' then
            bootstrap:onCleanup(function()
                if heatStarted and type(heatDecay.stop) == 'function' then heatDecay:stop() end
            end)
        end
        return { ok = true, skipped = true, reason = 'scheduling disabled',
            jobs = { heatDecay = heatDecay, npcStreamingBudget = streamingBudget, startupRecovery = startupRecovery },
            recoverySummary = recoverySummary,
            started = { heatDecay = heatStarted, npcStreamingBudget = streamingStarted } }
    end
    local booking = options.bookingService or services.booking
    local repository = options.bookingRepository or repositories.booking
    if type(booking) ~= 'table' or type(repository) ~= 'table' then
        local started, startError = startHeatDecay()
        if type(started) ~= 'table' or not started.ok then
            if options.requireHeatDecayJob == true then return startError or started end
        end
        if type(bootstrap.onCleanup) == 'function' then
            bootstrap:onCleanup(function()
                if heatStarted and type(heatDecay.stop) == 'function' then heatDecay:stop() end
            end)
        end
        return { ok = true, deferred = true, reason = 'booking services unavailable',
            jobs = { heatDecay = heatDecay, npcStreamingBudget = streamingBudget, startupRecovery = startupRecovery },
            recoverySummary = recoverySummary,
            started = { heatDecay = heatStarted, npcStreamingBudget = streamingStarted } }
    end
    local scheduler = options.scheduledBookingJob or options.schedulingJob
    if scheduler == nil and NightShift.ScheduledBookingJob then
        local created, err = NightShift.ScheduledBookingJob.new({
            repository = repository,
            bookingService = booking,
            config = schedulingConfig,
            clock = options.clock,
            activationOptions = options.scheduledActivationOptions
        })
        if not created then return err end
        scheduler = created
    end
    local noShow = options.noShowJob
    if noShow == nil and NightShift.NoShowJob then
        local created, err = NightShift.NoShowJob.new({
            repository = repository,
            bookingService = booking,
            refundService = options.refundService or services.refund,
            depositService = options.depositService or services.deposit,
            reputationService = options.reputationService or services.reputation,
            incidentService = options.incidentService or services.incident,
            eventBus = options.eventBus or services.eventBus,
            config = schedulingConfig,
            clock = options.clock,
            refundActorResolver = options.noShowRefundActorResolver
        })
        if not created then return err end
        noShow = created
    end
    if type(scheduler) ~= 'table' or type(noShow) ~= 'table' then
        return { ok = true, deferred = true, reason = 'scheduling jobs unavailable',
            jobs = { npcStreamingBudget = streamingBudget, startupRecovery = startupRecovery },
            recoverySummary = recoverySummary,
            started = { heatDecay = heatStarted, npcStreamingBudget = streamingStarted } }
    end
    local started = { scheduledBooking = false, noShow = false, heatDecay = false,
        npcStreamingBudget = streamingStarted }
    local heatStart, heatStartError = startHeatDecay()
    if type(heatStart) ~= 'table' or not heatStart.ok then
        if options.requireHeatDecayJob == true then return heatStartError or heatStart end
    end
    started.heatDecay = heatStarted
    if options.startSchedulingJobs ~= false and runtimeLoop then
        local scheduledStart = scheduler:start()
        if type(scheduledStart) ~= 'table' or not scheduledStart.ok then
            if options.requireSchedulingJobs == true then return scheduledStart end
        else
            started.scheduledBooking = true
        end
        local noShowStart = noShow:start()
        if type(noShowStart) ~= 'table' or not noShowStart.ok then
            if options.requireSchedulingJobs == true then return noShowStart end
        else
            started.noShow = true
        end
    end
    if type(bootstrap.onCleanup) == 'function' then
        bootstrap:onCleanup(function()
            if type(scheduler.stop) == 'function' then scheduler:stop() end
            if type(noShow.stop) == 'function' then noShow:stop() end
            if heatStarted and type(heatDecay.stop) == 'function' then heatDecay:stop() end
        end)
    end
    return { ok = true,
        jobs = { scheduledBooking = scheduler, noShow = noShow, startupRecovery = startupRecovery },
        recoverySummary = recoverySummary, started = started }
end

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
    local degraded = false
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
        if type(result) == 'table' and result.deferred == true then
            local configResult = self.results.config or {}
            local config = configResult.config or configResult.value and configResult.value.config or {}
            local environment = tostring(config.environment or 'development'):lower()
            local strict = environment == 'production' or environment == 'prod'
                or (type(config.features) == 'table' and config.features.persistence == true)
                or self.options.failClosed == true
            if strict then
                self.readiness = readiness.FAILED
                self.error = failure(stage, {
                    code = 'BOOTSTRAP_DEPENDENCY_UNAVAILABLE',
                    message = 'required runtime dependency is unavailable',
                    details = { stage = stage, reason = result.reason }
                })
                return false, self.error
            end
            degraded = true
        end
        self.results[stage] = result
    end
    self.readiness = degraded and readiness.DEGRADED or readiness.READY
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
Bootstrap.developmentPayerResolver = developmentPayerResolver
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

-- FiveM can retain a resource manifest snapshot while files are being added to
-- a running development resource. Load the development-only money adapter
-- before the first bootstrap so the settlement stage can still be wired even
-- when that snapshot does not include the new manifest entry yet.
local loadResourceFile = type(LoadResourceFile) == 'function' and LoadResourceFile or rawget(_G, 'LoadResourceFile')
local getCurrentResourceName = type(GetCurrentResourceName) == 'function' and GetCurrentResourceName or rawget(_G, 'GetCurrentResourceName')
local function loadRuntimeScript(path, label, resourceName)
    if type(loadResourceFile) ~= 'function' or type(resourceName) ~= 'string' or type(load) ~= 'function' then return false end
    local source = loadResourceFile(resourceName, path)
    if type(source) ~= 'string' then return false end
    local chunk, loadError = load(source, ('@%s/%s'):format(resourceName, path), 't', _ENV)
    if type(chunk) ~= 'function' then
        if type(print) == 'function' then print(('[gnsh-nightshift] %s loader failed: %s'):format(label, tostring(loadError):sub(1, 160))) end
        return false
    end
    local ok, runtimeError = pcall(chunk)
    if not ok then
        if type(print) == 'function' then print(('[gnsh-nightshift] %s loader failed: %s'):format(label, tostring(runtimeError):sub(1, 160))) end
        return false
    end
    return true
end

local runtimeResourceName = type(getCurrentResourceName) == 'function' and getCurrentResourceName() or nil
if NightShift.DevelopmentMoneyAdapter == nil then
    loadRuntimeScript('server/adapters/money/development.lua', 'development money adapter', runtimeResourceName)
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
if type(loadResourceFile) == 'function' and type(getCurrentResourceName) == 'function' then
    local resourceName = getCurrentResourceName()
    loadRuntimeScript('server/dev/s10_smoke.lua', 'S10 smoke command', resourceName)
    loadRuntimeScript('server/dev/s15_smoke.lua', 'S15 smoke command', resourceName)
    loadRuntimeScript('server/dev/s17_smoke.lua', 'S17 smoke command', resourceName)
    loadRuntimeScript('server/dev/s18_smoke.lua', 'S18 smoke command', resourceName)
    loadRuntimeScript('server/dev/s19_smoke.lua', 'S19 smoke command', resourceName)
    loadRuntimeScript('server/dev/s20_smoke.lua', 'S20 smoke command', resourceName)
    loadRuntimeScript('server/dev/s22_smoke.lua', 'S22 smoke command', resourceName)
    loadRuntimeScript('server/dev/s24_smoke.lua', 'S24 smoke command', resourceName)
    loadRuntimeScript('server/dev/s25_smoke.lua', 'S25 smoke command', resourceName)
    loadRuntimeScript('server/dev/s26_smoke.lua', 'S26 smoke command', resourceName)
end
