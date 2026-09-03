local function check(value, message) assert(value, message) end
local function ok(result, message) check(type(result) == 'table' and result.ok == true, message or 'expected successful result'); return result.value end
do
    local registry = NightShift.Phone.ProviderRegistry.new()
    local missing = ok(registry:pushNotification(1, { title = 'NightShift' }), 'missing phone must degrade gracefully')
    check(missing.skipped == true and missing.reason == 'provider-unavailable', 'missing provider result')
end
do
    local calls = {}
    local registry = NightShift.Phone.ProviderRegistry.new({ defaultProvider = 'fixture' })
    ok(registry:register('fixture', { available = true, getCapabilities = function() return { pushNotification = true, openApp = false } end, pushNotification = function(self, source, payload) calls.push = { source, payload }; return true end }, { resource = 'fixture-phone' }), 'provider registration')
    local listed = ok(registry:list(), 'provider listing')
    check(#listed == 1 and listed[1].name == 'fixture' and listed[1].capabilities.pushNotification == true, 'capability detection')
    local pushed = ok(registry:pushNotification(7, { title = 'Ready' }), 'push operation')
    check(pushed.provider == 'fixture' and calls.push[1] == 7, 'push route')
    local unsupported = ok(registry:openApp(7, 'marketplace', {}), 'unsupported operation')
    check(unsupported.skipped == true and unsupported.reason == 'capability-unavailable', 'unsupported operation fallback')
    check(ok(registry:unregister('fixture')).removed == true, 'provider removal result')
end
do
    local registry = NightShift.Phone.ProviderRegistry.new()
    ok(registry:register('broken', { available = true, openApp = function() error('provider failure') end }), 'broken provider registration')
    local result = ok(registry:openApp(1, 'route', {}), 'provider errors must be contained')
    check(result.skipped == true and result.reason == 'provider-error', 'provider failure fallback')
end
print('NS-211 phone provider registry contracts passed')
