local root = (... and ... ~= '') and (...) or '.'
local function load(path) dofile(root .. '/' .. path) end
load('shared/enums.lua'); load('shared/errors.lua'); load('shared/constants.lua'); load('server/bootstrap.lua')

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

print('NS-010 tests passed: ordered boot, stage failure short-circuit, stop cleanup')
