NightShift = NightShift or {}

local readiness = NightShift.Enums.Readiness
local defaultStages = {
    config = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local source = NightShift.DefaultConfig
        if type(context) == 'table' and rawget(context, 'config') ~= nil then
            source = rawget(context, 'config')
        elseif type(options) == 'table' and rawget(options, 'config') ~= nil then
            source = rawget(options, 'config')
        end
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
        if adapter == nil then
            local persistence = config.features and config.features.persistence == true
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
        if type(context) == 'table' then
            worker = rawget(context, 'workerProfileRepository') or worker
            client = rawget(context, 'clientProfileRepository') or client
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
        if type(worker) ~= 'table' or type(client) ~= 'table' then return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_INVALID, 'profile repositories are unavailable', { stage = 'repositories' }) end
        return { ok = true, repositories = { workerProfile = worker, clientProfile = client } }
    end,
    services = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local adapterResult = bootstrap and bootstrap.results and bootstrap.results.adapters or {}
        local repositoryResult = bootstrap and bootstrap.results and bootstrap.results.repositories or {}
        local providers = adapterResult.providers or adapterResult.value and adapterResult.value.providers or {}
        local repositories = repositoryResult.repositories or repositoryResult.value and repositoryResult.value.repositories or {}
        local framework = options.frameworkAdapter or providers.framework
        if type(context) == 'table' then framework = rawget(context, 'frameworkAdapter') or framework end
        local databaseDeferred = repositoryResult.deferred == true
        if framework == nil or databaseDeferred then
            return { ok = true, deferred = true, reason = framework == nil and 'framework adapter not configured' or 'profile repositories deferred' }
        end
        local identity = options.identityService
        if identity == nil and NightShift.IdentityService then
            local created, err = NightShift.IdentityService.new({ framework = framework })
            if not created then return err end
            identity = created
        end
        local worker = options.workerProfileService
        if worker == nil and NightShift.WorkerProfileService and repositories.workerProfile and identity then
            local created, err = NightShift.WorkerProfileService.new({ identityService = identity, repository = repositories.workerProfile })
            if not created then return err end
            worker = created
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
        if not identity or not worker or not client or not permissions then return { ok = true, deferred = true, reason = 'identity/profile services unavailable' } end
        return { ok = true, services = {
            identity = identity,
            workerProfile = worker,
            clientProfile = client,
            permissions = permissions
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
NightShift.Server = NightShift.Server or {}
NightShift.Server.readiness = readiness.STARTING
NightShift.Server.bootstrap = function(options, context)
    local instance = Bootstrap.new(options)
    NightShift.Server.instance = instance
    local ok, result = instance:boot(context)
    NightShift.Server.readiness = instance.readiness
    NightShift.Server.error = instance.error
    return ok, result
end

-- A FiveM resource script executes on load; start the server lifecycle here so
-- `ensure nightshift` cannot leave the resource in STARTING without an
-- explicit external call. Tests and embedders can still create isolated
-- Bootstrap instances through the exported constructor.
if not NightShift.Server.instance then
    NightShift.Server.bootstrap()
end
