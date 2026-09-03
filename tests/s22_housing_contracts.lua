local function check(value, message) assert(value, message) end
local function ok(result, message)
    check(result and result.ok == true, message or 'expected housing success')
    return result.value
end
local function err(result, code)
    check(result and result.ok == false, 'expected housing error')
    check(result.error and result.error.code == code, 'unexpected housing error code')
end

do
    local registry = NightShift.Housing.ProviderRegistry.new()
    local missing = ok(registry:listAccessible(7, {}), 'missing housing must degrade')
    check(missing.skipped == true and missing.reason == 'provider-unavailable', 'missing housing result')
end

do
    local calls, ready = {}, false
    local provider = {
        available = true,
        getCapabilities = function() return { propertyOwnership = true } end,
        listAccessible = function(_, source, context) calls.list = { source, context }; return { properties = { { id = 'apt-1' } } } end,
        validateAccess = function(_, source, property, phase) calls.validate = { source, property, phase }; return { valid = true } end,
        resolveMeetingTarget = function(_, property, context) calls.target = { property, context }; return { kind = 'coords', x = 1, y = 2, z = 3 } end,
        isInteriorReady = function() return ready end,
        reserve = function(_, property, booking, ttl) calls.reserve = { property, booking, ttl }; return true end,
        occupy = function() return true end,
        release = function() return true end
    }
    local registry = NightShift.Housing.ProviderRegistry.new({ providers = { property = provider } })
    local properties = ok(registry:listAccessible(7, { district = 'vinewood' }), 'accessible properties')
    check(properties.properties[1].id == 'apt-1' and calls.list[1] == 7, 'property list contract')
    check(ok(registry:validateAccess(7, 'apt-1', 'booking', {}) ).valid == true and calls.validate[3] == 'booking', 'booking access')
    check(ok(registry:validateAccess(7, 'apt-1', 'arrival', {}) ).valid == true and calls.validate[3] == 'arrival', 'arrival access')
    check(ok(registry:resolveMeetingTarget('apt-1', {})).z == 3, 'meeting target')
    check(ok(registry:isInteriorReady('apt-1', {})).ready == false, 'interior not-ready state')
    ready = true
    check(ok(registry:isInteriorReady('apt-1', {})).ready == true, 'interior ready state')
    check(ok(registry:reserve('apt-1', 'booking-1', 30)).reserved == true and calls.reserve[2] == 'booking-1', 'reservation delegation')
    err(registry:validateAccess(7, 'apt-1', 'departure', {}), 'PROVIDER_INVALID')
end

do
    local fallback = NightShift.Housing.ProviderRegistry.new({
        providers = { property = {
            available = true,
            listAvailable = function() return { properties = { { id = 'fallback' } } } end,
            validate = function() return true end,
            resolveWorldTarget = function() return { kind = 'coords', x = 4, y = 5, z = 6 } end
        } }
    })
    check(ok(fallback:listAccessible(1, {})).properties[1].id == 'fallback', 'legacy listAvailable fallback')
    check(ok(fallback:validateAccess(1, 'fallback', 'arrival', {})).valid == true, 'legacy validate fallback')
    check(ok(fallback:resolveMeetingTarget('fallback', {})).x == 4, 'legacy target fallback')
    check(ok(fallback:isInteriorReady('fallback', {})).skipped == true, 'interior readiness is optional')
end

print('NS-221 tests passed: housing registry, access phases, targets, readiness, and graceful degradation')
