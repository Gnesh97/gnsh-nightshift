local function check(value, message) assert(value, message) end
local function ok(result, message)
    check(result and result.ok == true, message or 'expected success')
    return result.value
end

local adapters = NightShift.PhoneAdapters
for _, name in ipairs({ 'generic', 'lb', 'qs', 'qb', 'yseries' }) do
    check(adapters[name] and type(adapters[name].new) == 'function', name .. ' adapter should register')
    local missing = adapters[name].new({ resource = 'missing-phone', resourceState = function() return 'missing' end })
    check(missing:isAvailable() == false, name .. ' should disable when resource is missing')
    local result = missing:pushNotification(1, { title = 'NightShift' })
    check(result.ok == false and result.error.code == 'CAPABILITY_UNAVAILABLE', name .. ' missing resource must fail closed')
end

local delivered, opened, registered
local generic = adapters.generic.new({
    available = true,
    registerApp = function(definition) registered = definition; return true end,
    pushNotification = function(source, payload) delivered = { source = source, payload = payload }; return true end,
    openApp = function(source, route, context) opened = { source = source, route = route, context = context }; return true end
})
check(generic:isAvailable() == true, 'generic adapter should be available with callbacks')
check(ok(generic:registerApp({ name = 'nightshift' })).registered == true, 'register app contract')
check(ok(generic:pushNotification(7, { title = 'NightShift' })).delivered == true, 'notification contract')
check(ok(generic:openApp(7, 'marketplace', { focus = 'favorites' })).opened == true, 'open app contract')
check(registered and delivered.source == 7 and opened.route == 'marketplace', 'provider callbacks should receive documented arguments')

local lbCalled
local lb = adapters.lb.new({ available = true, sendNotification = function(source, payload) lbCalled = { source, payload }; return true end })
check(ok(lb:pushNotification(3, { body = 'test' })).delivered == true and lbCalled[1] == 3, 'lb alias should map to notification')

print('NS-212 phone adapter contracts passed')
