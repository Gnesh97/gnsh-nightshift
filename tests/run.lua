local root = (... and ... ~= '') and (...) or '.'
local function load(path) dofile(root .. '/' .. path) end
load('shared/enums.lua'); load('shared/errors.lua'); load('shared/constants.lua'); load('shared/schemas.lua'); load('shared/validators.lua'); load('config/providers.lua'); load('config/features.lua'); load('config/config.lua'); load('server/core/result.lua'); load('server/core/clock.lua'); load('server/core/logger.lua'); load('server/bootstrap.lua'); load('client/bootstrap.lua')
load('tests/core_contracts.lua')
load('server/core/event_bus.lua')
load('tests/event_bus_contracts.lua')

local function check(value, message) assert(value, message) end

do
    local order = {}
    local stages = {}
    for _, name in ipairs(NightShift.Constants.STAGES) do
        stages[name] = function() order[#order + 1] = name; return { ok = true } end
    end
    local instance = NightShift.ServerBootstrap.new({ stages = stages })
    check(instance:boot(), 'ordered boot should succeed')
    check(table.concat(order, ',') == 'config,db,adapters,repositories,services,jobs', 'stage order mismatch')
    check(instance.readiness == 'READY', 'boot should be ready')
end

do
    local called = {}
    local stages = { config = function() return { ok = false, code = 'INVALID_CONFIG', message = 'invalid config' } end }
    for _, name in ipairs(NightShift.Constants.STAGES) do
        stages[name] = stages[name] or function() called[#called + 1] = name; return { ok = true } end
    end
    local instance = NightShift.ServerBootstrap.new({ stages = stages })
    local ok, err = instance:boot()
    check(not ok and instance.readiness == 'FAILED', 'invalid stage must fail')
    check(err.code == 'INVALID_CONFIG' and #called == 0, 'later stages must not run')
end

do
    local instance = NightShift.ServerBootstrap.new()
    local cleaned, survived = false, false
    instance:onCleanup(function() cleaned = true; error('expected cleanup failure') end)
    instance:onCleanup(function() survived = true end)
    instance:stop('gnsh-nightshift')
    instance:stop('gnsh-nightshift')
    check(cleaned and survived and instance.readiness == 'STOPPED', 'cleanup should be once and stop')
    check(instance.error and instance.error.code == 'CLEANUP_FAILED', 'cleanup failure should be structured')
end

do
    local handler
    AddEventHandler = function(_, callback) handler = callback end
    GetCurrentResourceName = function() return 'gnsh-nightshift' end
    local instance = NightShift.ServerBootstrap.new()
    local cleaned = false
    instance:onCleanup(function() cleaned = true end)
    handler('other-resource')
    check(instance.readiness == 'STARTING' and not cleaned, 'foreign stop must be ignored')
    handler('gnsh-nightshift')
    check(instance.readiness == 'STOPPED' and cleaned, 'own stop hook must clean up')
    AddEventHandler = nil
    GetCurrentResourceName = nil
end

check(NightShift.Client.readiness == 'READY', 'client lifecycle should initialize ready')

local function validConfig(overrides)
    local value = NightShift.Validators.copy(NightShift.DefaultConfig)
    if overrides then for key, item in pairs(overrides) do value[key] = item end end
    return value
end

do
    local normalized, err = NightShift.Validators.validateConfig(validConfig({ provider = { mode = 'explicit', name = 'missing' } }))
    check(not normalized and err.code == 'UNKNOWN_PROVIDER' and err.field == 'provider.name', 'unknown provider must fail with field')
end
do
    local value = validConfig(); value.servicePackages[2] = NightShift.Validators.copy(value.servicePackages[1])
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'DUPLICATE_ID', 'duplicate service ID must fail')
end
do
    local value = validConfig(); value.servicePackages[1].price = 0
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_PRICE', 'invalid price must fail')
end
do
    local value = validConfig(); value.servicePackages[1].locationIds = { 'not-allowlisted' }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_LOCATION_REFERENCE', 'invalid location reference must fail')
end
do
    local value = validConfig(); value.features.physicalNpc = true
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(normalized and not err and normalized ~= value and normalized.features.physicalNpc, 'valid config should normalize a copy')
end
do
    local value = validConfig({ provider = { mode = 'auto' } })
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'auto detection must not silently fall back')
end
do
    local value = validConfig({ provider = { mode = 'auto' } })
    local normalized, err = NightShift.Validators.validateConfig(value, { resolveProvider = function() return false end })
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'malformed resolver result must be typed unavailable')
    normalized, err = NightShift.Validators.validateConfig(value, { resolveProvider = function() return { name = 'standalone', supported = true, available = true, capabilities = {} } end })
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'empty capabilities must be unavailable')
end
do
    local value = validConfig(); value.servicePackages = { [2] = value.servicePackages[1] }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'sparse service arrays must fail')
    value = validConfig(); value.servicePackages[1].locationIds = { 'configured_default', 'configured_default' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_LOCATION_REFERENCE', 'duplicate location references must fail')
    value = validConfig(); value.servicePackages = { value.servicePackages[1], [3] = NightShift.Validators.copy(value.servicePackages[1]) }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'holes with trailing entries must fail')
    value = validConfig(); value.servicePackages[1].locationIds = false; value.servicePackages[1].locations = { 'configured_default' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'invalid primary location alias must not fall back')
end
do
    local value = validConfig(); value.features = false
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'malformed features must fail')
    value = validConfig(); value.locations[1].category = 'arbitrary'
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'invalid location category must fail')
end
do
    local value = validConfig(); value.demand = { window = math.huge }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'unsafe demand placeholder must fail')
    value = validConfig(); value.npcProfiles[1].description = 'graphic content'
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'free-form NPC profile content must fail')
    value = validConfig(); value.npcProfiles[1].traits = { model = 'graphic' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'nested NPC profile fields must fail')
end

do
    local ok = NightShift.Server.bootstrap()
    check(ok and NightShift.Server.readiness == 'READY', 'default development config should boot')
end

print('NS-010/NS-011 tests passed: lifecycle, config validation, normalization, and fail-closed provider selection')
