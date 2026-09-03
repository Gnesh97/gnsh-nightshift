local function check(value, message) assert(value, message) end

local function stagedConfig(environment)
    local stages = {}
    stages.config = function()
        return { ok = true, config = {
            environment = environment,
            features = { persistence = false }
        } }
    end
    for _, name in ipairs({ 'db', 'adapters', 'repositories', 'services', 'jobs' }) do
        stages[name] = function()
            return { ok = true, deferred = true, reason = name .. ' unavailable' }
        end
    end
    return stages
end

do
    local instance = NightShift.ServerBootstrap.new({ stages = stagedConfig('development') })
    local ok = instance:boot()
    check(ok and instance.readiness == NightShift.Enums.Readiness.DEGRADED,
        'development boot with deferred dependencies must be DEGRADED')
end

do
    local instance = NightShift.ServerBootstrap.new({ stages = stagedConfig('production') })
    local ok, err = instance:boot()
    check(not ok and instance.readiness == NightShift.Enums.Readiness.FAILED,
        'production boot with deferred dependencies must fail closed')
    check(err and err.code == 'BOOTSTRAP_DEPENDENCY_UNAVAILABLE',
        'production deferred dependency failure must be typed')
end

do
    local previous = rawget(_G, 'GetConvar')
    GetConvar = function(name, fallback)
        local values = {
            nightshift_environment = 'production',
            nightshift_provider = 'standalone',
            nightshift_framework = 'standalone',
            nightshift_money_provider = 'standalone',
            nightshift_persistence = 'true'
        }
        return values[name] or fallback
    end
    local configured = NightShift.ServerBootstrap.applyRuntimeConfig({
        environment = 'development',
        provider = { mode = 'explicit', name = 'standalone' },
        features = { persistence = false }
    })
    check(configured.environment == 'production', 'runtime environment convar must be applied')
    check(configured.framework == 'standalone' and configured.moneyProvider == 'standalone',
        'runtime provider convars must be exposed in normalized config')
    check(configured.features.persistence == true, 'runtime persistence convar must enable persistence')
    check(configured.recovery and configured.recovery.apply == true,
        'production runtime config must default startup recovery to apply mode')
    GetConvar = previous
end

do
    local alias = NightShift.Validators.copy(NightShift.DefaultConfig)
    alias.environment = 'prod'
    local normalized, err = NightShift.Validators.validateConfig(alias)
    check(normalized and not err and normalized.environment == 'production',
        'prod environment alias must normalize to canonical production')
end

print('REM-001 readiness contracts passed: degraded development, fail-closed production, runtime config')
