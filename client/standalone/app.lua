NightShift = NightShift or {}
NightShift.Client = NightShift.Client or {}
NightShift.Client.Standalone = NightShift.Client.Standalone or {}

local config = NightShift.StandaloneConfig or {}
local App = {}
App.__index = App

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function now()
    if type(GetGameTimer) == 'function' then return GetGameTimer() end
    return os.time() * 1000
end

function App.new(options)
    options = type(options) == 'table' and options or {}
    local selected = options.config or config
    return setmetatable({
        config = selected,
        state = { open = false, route = selected.route or '/', payload = {} },
        pending = {},
        sequence = 0,
        transport = options.transport,
    }, App)
end

function App:_publish()
    if type(SendNUIMessage) == 'function' then
        SendNUIMessage({
            action = self.config.messageName or 'nightshift:standalone:state',
            type = 'nightshift:visibility',
            visible = self.state.open == true,
            route = self.state.route,
            state = copy(self.state),
        })
    end
end

function App:_focus(enabled)
    if type(SetNuiFocus) == 'function' then SetNuiFocus(enabled, enabled) end
    if type(SetNuiFocusKeepInput) == 'function' then SetNuiFocusKeepInput(false) end
end

function App:open(payload, route)
    if self.config.enabled == false then return false, 'STANDALONE_DISABLED' end
    self.state = {
        open = true,
        route = type(route) == 'string' and route or (self.config.route or '/'),
        payload = copy(type(payload) == 'table' and payload or {}),
        openedAt = now(),
    }
    self:_focus(true)
    self:_publish()
    return true, copy(self.state)
end

function App:close()
    self.state = {
        open = false,
        route = self.config.closeRoute or self.config.route or '/',
        payload = {},
    }
    self:_focus(false)
    self:_publish()
    return true, copy(self.state)
end

function App:toggle(payload, route)
    if self.state.open then return self:close() end
    return self:open(payload, route)
end

function App:getState()
    return copy(self.state)
end

function App:call(method, payload, callback)
    if type(method) ~= 'string' or method == '' then
        return false, 'STANDALONE_METHOD_INVALID'
    end
    payload = type(payload) == 'table' and copy(payload) or {}
    if type(self.transport) == 'function' then
        return self.transport(method, payload, callback)
    end
    if self.config.useLibCallback == true and lib and lib.callback and type(lib.callback.await) == 'function' then
        local ok, result = pcall(lib.callback.await, self.config.callbackName, false, method, payload)
        if not ok then return false, 'STANDALONE_CALLBACK_FAILED' end
        if type(callback) == 'function' then callback(result) end
        return true, result
    end
    if type(TriggerServerEvent) ~= 'function' then
        return false, 'STANDALONE_TRANSPORT_UNAVAILABLE'
    end
    self.sequence = self.sequence + 1
    local playerServerId = 0
    if type(GetPlayerServerId) == 'function' and type(PlayerId) == 'function' then
        playerServerId = GetPlayerServerId(PlayerId())
    end
    local requestId = ('%s:%s'):format(tostring(playerServerId), self.sequence)
    self.pending[requestId] = type(callback) == 'function' and callback or false
    TriggerServerEvent(self.config.requestEvent or 'gnsh-nightshift:standalone:request', requestId, method, payload)
    return true, requestId
end

local instance = App.new()
NightShift.Client.Standalone.App = App
NightShift.Client.Standalone.instance = instance

if type(RegisterCommand) == 'function' and instance.config.command then
    RegisterCommand(instance.config.command, function(_, args)
        local route = args and args[1]
        instance:toggle({}, route)
    end, false)
end

if type(RegisterNUICallback) == 'function' then
    local names = instance.config.nuiCallbacks or {}
    RegisterNUICallback(names.close or 'standalone:close', function(_, cb)
        local ok, result = instance:close()
        if type(cb) == 'function' then cb({ ok = ok, state = result }) end
    end)
    RegisterNUICallback(names.action or 'standalone:action', function(data, cb)
        data = type(data) == 'table' and data or {}
        local ok, result = instance:call(data.method, data.payload)
        if type(cb) == 'function' then cb({ ok = ok, result = result }) end
    end)
end

if type(RegisterNetEvent) == 'function' and type(AddEventHandler) == 'function' then
    local responseEvent = instance.config.responseEvent or 'gnsh-nightshift:standalone:response'
    RegisterNetEvent(responseEvent)
    AddEventHandler(responseEvent, function(requestId, ok, result)
        local callback = instance.pending[requestId]
        instance.pending[requestId] = nil
        if type(callback) == 'function' then callback(ok ~= false, result) end
    end)
end

return instance
