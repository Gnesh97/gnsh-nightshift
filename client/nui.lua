NightShift = NightShift or {}

local registerNuiCallback = type(RegisterNUICallback) == 'function' and RegisterNUICallback or rawget(_G, 'RegisterNUICallback')
local registerNetEvent = type(RegisterNetEvent) == 'function' and RegisterNetEvent or rawget(_G, 'RegisterNetEvent')
local addEventHandler = type(AddEventHandler) == 'function' and AddEventHandler or rawget(_G, 'AddEventHandler')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
local triggerServerEvent = type(TriggerServerEvent) == 'function' and TriggerServerEvent or rawget(_G, 'TriggerServerEvent')
local sendNuiMessage = type(SendNUIMessage) == 'function' and SendNUIMessage or rawget(_G, 'SendNUIMessage')
local setNuiFocus = type(SetNuiFocus) == 'function' and SetNuiFocus or rawget(_G, 'SetNuiFocus')
local setTimeout = type(SetTimeout) == 'function' and SetTimeout or rawget(_G, 'SetTimeout')

local pending = {}
local Nui = {}
local requestTimeoutMs = 10000
local maxPendingRequests = 16
local pendingCount = 0

local function validRequestId(value)
    return type(value) == 'string' and #value > 0 and #value <= 96 and value:match('^[%w%-%_:]+$') ~= nil
end

local function resultError(requestId, code, message)
    return { ok = false, requestId = requestId, error = { code = code, message = message, requestId = requestId } }
end

local function removePending(requestId, expectedCallback)
    if pending[requestId] ~= expectedCallback then return false end
    pending[requestId] = nil
    pendingCount = math.max(0, pendingCount - 1)
    return true
end

function Nui.open()
    if type(setNuiFocus) == 'function' then setNuiFocus(true, true) end
    if type(sendNuiMessage) == 'function' then sendNuiMessage({ type = 'nightshift:visibility', visible = true }) end
end

function Nui.close()
    if type(setNuiFocus) == 'function' then setNuiFocus(false, false) end
    if type(sendNuiMessage) == 'function' then sendNuiMessage({ type = 'nightshift:visibility', visible = false }) end
end

if type(registerNuiCallback) == 'function' then
    registerNuiCallback('nightshift:request', function(data, callback)
        data = type(data) == 'table' and data or {}
        local requestId = data.requestId
        if not validRequestId(requestId) then
            callback(resultError('', 'NUI_REQUEST_INVALID', 'Request identifier is invalid'))
            return
        end
        if data.method == 'ui:close' then
            Nui.close()
            callback({ ok = true, requestId = requestId, value = { closed = true } })
            return
        end
        if type(data.method) ~= 'string' or type(data.payload) ~= 'table' then
            callback(resultError(requestId, 'NUI_REQUEST_INVALID', 'Request payload is invalid'))
            return
        end
        if type(triggerServerEvent) ~= 'function' then
            callback(resultError(requestId, 'NUI_UNAVAILABLE', 'Server bridge is unavailable'))
            return
        end
        if pending[requestId] ~= nil then
            callback(resultError(requestId, 'NUI_REQUEST_DUPLICATE', 'A request with this identifier is already pending'))
            return
        end
        if pendingCount >= maxPendingRequests then
            callback(resultError(requestId, 'NUI_BUSY', 'Too many requests are already pending'))
            return
        end
        pending[requestId] = callback
        pendingCount = pendingCount + 1
        if type(setTimeout) == 'function' then
            local expectedCallback = callback
            setTimeout(requestTimeoutMs, function()
                if not removePending(requestId, expectedCallback) then return end
                expectedCallback(resultError(requestId, 'NUI_TIMEOUT', 'Server did not respond in time'))
            end)
        end
        triggerServerEvent('gnsh-nightshift:nui:request', requestId, data.method, data.payload)
    end)
end

if type(registerNetEvent) == 'function' and type(addEventHandler) == 'function' then
    registerNetEvent('gnsh-nightshift:nui:response')
    addEventHandler('gnsh-nightshift:nui:response', function(requestId, response)
        local callback = validRequestId(requestId) and pending[requestId] or nil
        if type(callback) ~= 'function' then return end
        removePending(requestId, callback)
        callback(type(response) == 'table' and response or resultError(requestId, 'NUI_RESPONSE_INVALID', 'Server returned an invalid response'))
    end)

    registerNetEvent('gnsh-nightshift:client:open-marketplace')
    addEventHandler('gnsh-nightshift:client:open-marketplace', Nui.open)
end

if type(registerCommand) == 'function' then
    registerCommand('nightshift_marketplace', function()
        Nui.open()
    end, false)
end

NightShift.ClientNui = Nui
