local function check(value, message) assert(value, message) end

NightShift = NightShift or {}
NightShift.StandaloneConfig = {
    enabled = true,
    route = '/marketplace',
    closeRoute = '/marketplace',
    messageName = 'test:state',
    callbackName = 'test:callback',
    nuiCallbacks = {},
}

local sent = {}
local focused = {}
SendNUIMessage = function(message) sent[#sent + 1] = message end
SetNuiFocus = function(a, b) focused[#focused + 1] = { a, b } end
local app = dofile('client/standalone/app.lua')

local opened, state = app:open({ district = 'vinewood' })
check(opened == true and state.open == true, 'standalone app opens')
check(state.route == '/marketplace' and state.payload.district == 'vinewood', 'open route/payload')
check(sent[#sent].action == 'test:state' and focused[#focused][1] == true, 'open publishes and focuses')

local closed = app:close()
check(closed == true and app:getState().open == false, 'standalone app closes')
check(focused[#focused][1] == false, 'close releases focus')

local called
local custom = app.new({ config = NightShift.StandaloneConfig, transport = function(method, payload)
    called = { method, payload }
    return true, { ok = true }
end })
local ok, result = custom:call('favorite.list', { district = 'vinewood' })
check(ok == true and result.ok == true, 'callback transport result')
check(called[1] == 'favorite.list' and called[2].district == 'vinewood', 'callback transport payload')

NightShift.StandaloneConfig.enabled = false
local disabled = app:open()
check(disabled == false, 'disabled standalone app is rejected')

print('NS-210 standalone app contracts passed')

