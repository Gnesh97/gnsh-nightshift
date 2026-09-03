NightShift = NightShift or {}

local registerNetEvent = type(RegisterNetEvent) == 'function' and RegisterNetEvent or rawget(_G, 'RegisterNetEvent')
local addEventHandler = type(AddEventHandler) == 'function' and AddEventHandler or rawget(_G, 'AddEventHandler')
local triggerClientEvent = type(TriggerClientEvent) == 'function' and TriggerClientEvent or rawget(_G, 'TriggerClientEvent')

local allowedMethods = {
    ['marketplace:list'] = true,
    ['booking:quote'] = true,
    ['booking:confirm'] = true,
    ['client-bookings:list'] = true,
    ['client-mode:confirm'] = true,
    ['client-mode:travel'] = true,
    ['client-mode:spawn'] = true,
    ['client-mode:spawn-confirm'] = true,
    ['client-mode:arrival'] = true,
    ['client-mode:client-arrival'] = true,
    ['client-mode:npc-arrival'] = true,
    ['client-mode:pickup-arrival'] = true,
    ['client-mode:vehicle-bind'] = true,
    ['client-mode:vehicle-entry'] = true,
    ['client-mode:destination-travel'] = true,
    ['client-mode:destination-arrival'] = true,
    ['client-mode:session-start'] = true,
    ['client-mode:session-complete'] = true,
    ['client-mode:travel-progress'] = true,
    ['client-mode:recover'] = true,
    ['review:submit'] = true,
    ['review:get'] = true,
    ['favorite:add'] = true,
    ['favorite:remove'] = true,
    ['favorite:list'] = true,
    ['relationship:get'] = true,
    ['book-again:quote'] = true,
    ['book-again:confirm'] = true,
    ['admin:diagnostics'] = true
}

local function requestId(value)
    return type(value) == 'string' and #value > 0 and #value <= 96 and value:match('^[%w%-%_:]+$') ~= nil
end

local function errorResult(id, code, message)
    return { ok = false, requestId = id, error = { code = code, message = message, requestId = id } }
end

local function stageServices()
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    local stage = type(instance) == 'table' and type(instance.results) == 'table' and instance.results.services or nil
    return type(stage) == 'table' and (stage.services or stage.value and stage.value.services or stage) or nil
end

local function withRequestId(id, result)
    if type(result) ~= 'table' then return errorResult(id, 'NUI_RESPONSE_INVALID', 'Service returned an invalid response') end
    local output = {}
    for key, value in pairs(result) do
        if key ~= 'requestId' and key ~= 'error' then output[key] = value end
    end
    output.requestId = id
    if result.ok == false and type(result.error) == 'table' then
        output.error = {}
        for key, value in pairs(result.error) do
            if key ~= 'requestId' then output.error[key] = value end
        end
        output.error.requestId = id
    end
    return output
end

local function publicResult(services, method, result)
    local clientMode = type(services) == 'table' and services.clientMode or nil
    if type(clientMode) == 'table' and type(clientMode.toNuiResult) == 'function' and
        (method == 'booking:confirm' or method:match('^client%-mode:')) then
        return clientMode:toNuiResult(result, method)
    end
    return result
end

local function rateLimitRequest(services, playerSource, requestIdValue, method)
    local limiter = type(services) == 'table' and services.rateLimiter or nil
    if type(limiter) ~= 'table' or type(limiter.allow) ~= 'function' then return true end
    local limited = limiter:allow(playerSource, method)
    if type(limited) == 'table' and limited.ok == true then return true end
    if type(triggerClientEvent) == 'function' then
        triggerClientEvent('gnsh-nightshift:nui:response', playerSource, requestIdValue,
            withRequestId(requestIdValue, limited))
    end
    return false
end

if type(registerNetEvent) == 'function' and type(addEventHandler) == 'function' then
    registerNetEvent('gnsh-nightshift:nui:request')
    addEventHandler('gnsh-nightshift:nui:request', function(id, method, payload)
        local playerSource = source
        if type(triggerClientEvent) ~= 'function' or type(playerSource) ~= 'number' then return end
        if not requestId(id) or type(method) ~= 'string' or not allowedMethods[method] or type(payload) ~= 'table' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id or '', errorResult(id or '', 'NUI_REQUEST_INVALID', 'Request is invalid'))
            return
        end
        local services = stageServices()
        if not rateLimitRequest(services, playerSource, id, method) then return end
        if method == 'marketplace:list' and type(services) == 'table' and type(services.marketplace) == 'table' then
            local request = {}
            for key, value in pairs(payload) do request[key] = value end
            request.source = playerSource
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.marketplace:list(request)))
            return
        end
        if method == 'booking:quote' and type(services) == 'table' and type(services.clientBookingCommands) == 'table' and type(services.clientBookingCommands.quote) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.clientBookingCommands:quote(playerSource, payload)))
            return
        end
        if method == 'booking:confirm' and type(services) == 'table' and type(services.clientBookingCommands) == 'table' and type(services.clientBookingCommands.confirm) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientBookingCommands:confirm(playerSource, payload))))
            return
        end
        if method == 'client-mode:confirm' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirm) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirm(playerSource, payload))))
            return
        end
        if method == 'client-mode:travel' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.travel) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:travel(playerSource, payload))))
            return
        end
        if method == 'client-mode:spawn' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.spawn) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:spawn(playerSource, payload))))
            return
        end
        if method == 'client-mode:spawn-confirm' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmSpawn) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmSpawn(playerSource, payload))))
            return
        end
        if method == 'client-mode:arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmArrival) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmArrival(playerSource, payload))))
            return
        end
        if method == 'client-mode:client-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmClientArrival) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmClientArrival(playerSource, payload))))
            return
        end
        if method == 'client-mode:npc-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmNpcArrival) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmNpcArrival(playerSource, payload))))
            return
        end
        if method == 'client-mode:pickup-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmArrival) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmArrival(playerSource, payload))))
            return
        end
        if method == 'client-mode:vehicle-bind' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.bindVehicle) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:bindVehicle(playerSource, payload))))
            return
        end
        if method == 'client-mode:vehicle-entry' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.enterVehicle) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:enterVehicle(playerSource, payload.bookingId))))
            return
        end
        if method == 'client-mode:destination-travel' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.startDestinationTravel) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:startDestinationTravel(playerSource, payload.bookingId))))
            return
        end
        if method == 'client-mode:destination-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmDestinationArrival) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:confirmDestinationArrival(playerSource, payload))))
            return
        end
        if method == 'client-mode:session-start' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.startSession) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:startSession(playerSource, payload.bookingId, payload))))
            return
        end
        if method == 'client-mode:session-complete' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.completeSession) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:completeSession(playerSource, payload.token, payload))))
            return
        end
        if method == 'client-mode:travel-progress' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.updateTravelProgress) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:updateTravelProgress(playerSource, payload.bookingId))))
            return
        end
        if method == 'client-mode:recover' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.recoverTravel) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:recoverTravel(playerSource, payload.bookingId, payload.recoveryState))))
            return
        end
        if method == 'client-bookings:list' and type(services) == 'table' and type(services.clientBooking) == 'table' and type(services.clientBooking.list) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.clientBooking:list(playerSource, payload)))
            return
        end
        if method == 'review:submit' and type(services) == 'table' and type(services.review) == 'table' and type(services.review.submit) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.review:submit(playerSource, payload)))
            return
        end
        if method == 'review:get' and type(services) == 'table' and type(services.review) == 'table' and type(services.review.get) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.review:get(payload.bookingId)))
            return
        end
        if method == 'favorite:add' and type(services) == 'table' and type(services.favorite) == 'table' and type(services.favorite.add) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.favorite:add(playerSource, payload.workerId or payload.workerKey)))
            return
        end
        if method == 'favorite:remove' and type(services) == 'table' and type(services.favorite) == 'table' and type(services.favorite.remove) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.favorite:remove(playerSource, payload.workerId or payload.workerKey)))
            return
        end
        if method == 'favorite:list' and type(services) == 'table' and type(services.favorite) == 'table' and type(services.favorite.list) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.favorite:list(playerSource, payload)))
            return
        end
        if method == 'relationship:get' and type(services) == 'table' and type(services.relationship) == 'table' and type(services.relationship.get) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.relationship:get(playerSource, payload.workerId or payload.workerKey)))
            return
        end
        if method == 'book-again:quote' and type(services) == 'table' and type(services.bookAgain) == 'table' and type(services.bookAgain.quote) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.bookAgain:quote(playerSource, payload)))
            return
        end
        if method == 'book-again:confirm' and type(services) == 'table' and type(services.bookAgain) == 'table' and type(services.bookAgain.confirm) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.bookAgain:confirm(playerSource, payload)))
            return
        end
        if method == 'admin:diagnostics' and type(services) == 'table' and type(services.diagnostics) == 'table'
            and type(services.diagnostics.snapshot) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id,
                withRequestId(id, services.diagnostics:snapshot(playerSource, payload)))
            return
        end
        triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, errorResult(id, 'NUI_CALLBACK_UNAVAILABLE', 'This booking action is not available yet'))
    end)
end
