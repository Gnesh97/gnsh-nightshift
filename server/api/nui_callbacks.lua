NightShift = NightShift or {}

local registerNetEvent = type(RegisterNetEvent) == 'function' and RegisterNetEvent or rawget(_G, 'RegisterNetEvent')
local addEventHandler = type(AddEventHandler) == 'function' and AddEventHandler or rawget(_G, 'AddEventHandler')
local triggerClientEvent = type(TriggerClientEvent) == 'function' and TriggerClientEvent or rawget(_G, 'TriggerClientEvent')

local allowedMethods = {
    ['marketplace:list'] = true,
    ['security:action-token'] = true,
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

local nextAction = {
    ['booking:quote'] = 'booking:confirm',
    ['booking:confirm'] = 'client-mode:travel',
    ['client-mode:confirm'] = 'client-mode:travel',
    ['client-mode:travel'] = 'client-mode:spawn',
    ['client-mode:spawn'] = 'client-mode:spawn-confirm',
    ['client-mode:spawn-confirm'] = 'client-mode:arrival',
    ['client-mode:arrival'] = 'client-mode:session-start',
    ['client-mode:client-arrival'] = 'client-mode:session-start',
    ['client-mode:npc-arrival'] = 'client-mode:session-start',
    ['client-mode:pickup-arrival'] = 'client-mode:session-start',
    ['client-mode:vehicle-bind'] = 'client-mode:vehicle-entry',
    ['client-mode:vehicle-entry'] = 'client-mode:destination-travel',
    ['client-mode:destination-travel'] = 'client-mode:destination-arrival',
    ['client-mode:destination-arrival'] = 'client-mode:session-start',
    ['client-mode:session-start'] = 'client-mode:session-complete',
    ['book-again:quote'] = 'book-again:confirm'
}

local criticalActions = {
    ['booking:confirm'] = true, ['client-mode:confirm'] = true,
    ['client-mode:travel'] = true, ['client-mode:spawn'] = true,
    ['client-mode:spawn-confirm'] = true, ['client-mode:arrival'] = true,
    ['client-mode:client-arrival'] = true, ['client-mode:npc-arrival'] = true,
    ['client-mode:pickup-arrival'] = true, ['client-mode:vehicle-bind'] = true,
    ['client-mode:vehicle-entry'] = true, ['client-mode:destination-travel'] = true,
    ['client-mode:destination-arrival'] = true, ['client-mode:session-start'] = true,
    ['client-mode:session-complete'] = true, ['client-mode:recover'] = true,
    ['book-again:confirm'] = true
}

-- A generation is only meaningful for entity-backed actions.  The NUI may
-- request a replacement token after a transient server failure, but it must
-- never be able to invent the generation binding.  These actions therefore
-- require a server-side NPC registry lookup before a generation-bound token
-- is issued.
local generationBoundActions = {
    ['client-mode:spawn-confirm'] = true,
    ['client-mode:arrival'] = true,
    ['client-mode:client-arrival'] = true,
    ['client-mode:npc-arrival'] = true,
    ['client-mode:pickup-arrival'] = true
}

local terminalBookingStatuses = {
    SETTLED = true, DECLINED = true, CANCELLED = true,
    EXPIRED = true, INTERRUPTED = true
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function stripActionToken(payload)
    local output = {}
    for key, value in pairs(payload or {}) do
        if key ~= 'actionToken' and key ~= 'action_token' then output[key] = copy(value) end
    end
    return output
end

local function safeToken(value)
    return type(value) == 'string' and #value > 0 and #value <= 240
        and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

-- Database booking IDs are commonly numeric while quote/action identifiers
-- are namespaced strings. Keep both forms bounded and allowlisted at the NUI
-- boundary so valid numeric bookings can receive lifecycle tokens.
local function safeBindingId(value)
    if type(value) == 'number' then
        if value ~= value or value == math.huge or value == -math.huge
            or value < 1 or value ~= math.floor(value) then return nil end
        value = tostring(value)
    elseif value ~= nil then
        value = tostring(value)
    end
    if type(value) ~= 'string' or #value == 0 or #value > 240 then return nil end
    if safeToken(value) or value:match('^%d+$') ~= nil then return value end
    return nil
end

local function resultValue(result)
    if type(result) ~= 'table' then return nil end
    return type(result.value) == 'table' and result.value or type(result.data) == 'table' and result.data or nil
end

local function bookingBinding(method, payload, value)
    if method == 'booking:quote' or method == 'book-again:quote' then
        return value and (value.quoteId or value.quote_id)
    end
    if value then
        local booking = type(value.booking) == 'table' and value.booking or nil
        local spawn = type(value.spawn) == 'table' and value.spawn or nil
        return value.bookingId or value.booking_id or booking and (booking.bookingId or booking.id)
            or spawn and (spawn.bookingId or spawn.booking_id)
    end
    return payload and (payload.bookingId or payload.booking_id)
end

local function attachActionToken(services, playerSource, method, payload, result)
    local action = nextAction[method]
    if not action or type(result) ~= 'table' or result.ok ~= true then return result end
    local tokens = type(services) == 'table' and services.actionTokens or nil
    if type(tokens) ~= 'table' or type(tokens.requires) ~= 'function' or not tokens:requires() then return result end
    if type(tokens.issue) ~= 'function' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'action token issuance is unavailable' } }
    end
    local value = resultValue(result)
    local bookingId = bookingBinding(method, payload, value)
    local bindingId = safeBindingId(bookingId)
    if not bindingId then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_INVALID', message = 'trusted response has no token binding' } }
    end
    local generation = value and (value.generationToken or value.generation_token)
    if type(value) == 'table' and type(value.spawn) == 'table' then
        generation = generation or value.spawn.generationToken
    end
    if generationBoundActions[action] and not safeToken(generation) then
        return { ok = false, success = false,
            error = { code = 'ACTION_TOKEN_INVALID',
                message = 'trusted response has no valid NPC generation binding' } }
    end
    local issued = tokens:issue(playerSource, bindingId, action, generation and { generation = generation } or nil)
    if type(issued) ~= 'table' or issued.ok ~= true or type(issued.value) ~= 'table' then
        return issued or { ok = false, success = false, error = { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'action token issuance failed' } }
    end
    if type(value) ~= 'table' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_INVALID', message = 'trusted response value is invalid' } }
    end
    local output = copy(result)
    local tokenValue = issued.value.token
    local function decorate(source)
        local decorated = copy(source)
        decorated.actionToken = tokenValue
        decorated.actionTokenExpiresAt = issued.value.expiresAt
        return decorated
    end
    output.value = decorate(value)
    if output.data ~= nil then output.data = decorate(value) end
    return output
end

local function safeLocationOptions(services, playerSource)
    local locationService = type(services) == 'table' and services.location or nil
    if type(locationService) ~= 'table' or type(locationService.list) ~= 'function' then return {} end
    local listed = locationService:list({ available = true })
    local source = type(listed) == 'table' and (listed.value or listed.data) or nil
    if type(source) ~= 'table' then return {} end
    local output = {}
    for _, location in ipairs(source) do
        if type(location) == 'table' then
            local ref = location.locationRef or location.id
            if type(ref) == 'string' and #ref > 0 and #ref <= 160 then
                local modes = {}
                for _, mode in ipairs(location.meetingModes or location.allowedMeetingModes or {}) do
                    if type(mode) == 'string' and #mode <= 32 and mode:match('^[A-Za-z][A-Za-z0-9_%-]*$')
                        and #modes < 8 then modes[#modes + 1] = mode:upper() end
                end
                local label = location.displayName or location.name or ref
                if type(label) ~= 'string' or #label == 0 or #label > 120 or label:match('%S') == nil then label = ref end
                local locationType = location.locationType or location.type
                if type(locationType) ~= 'string' or #locationType == 0 or #locationType > 64
                    or locationType:match('^[A-Za-z][A-Za-z0-9_%-]*$') == nil then locationType = nil end
                output[#output + 1] = {
                    locationId = ref,
                    label = label,
                    locationType = locationType,
                    meetingModes = modes
                }
            end
        end
    end
    table.sort(output, function(left, right) return left.locationId < right.locationId end)
    return output
end

local function resolveActor(services, playerSource)
    local identity = type(services) == 'table' and services.identity or nil
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil end
    local resolved = identity:resolve(playerSource)
    if type(resolved) ~= 'table' or resolved.ok ~= true or type(resolved.value) ~= 'table' then return nil end
    local value = resolved.value
    local reference = value.identityKey or value.key or value.ref
    if type(reference) ~= 'string' or #reference == 0 or #reference > 200 then return nil end
    return { type = 'PLAYER', ref = reference, source = playerSource }
end

local function resolveGenerationBinding(services, bookingId, action, payload)
    -- The refresh endpoint historically called this field `generation`,
    -- while lifecycle payloads call it `generationToken`. Accept the aliases
    -- only as a naming normalization; the registry equality check below still
    -- remains the source of truth.
    local generation = payload.generation
    if generation == nil then generation = payload.generationToken or payload.generation_token end
    if generation == nil then
        if generationBoundActions[action] then
            return nil, { code = 'ACTION_TOKEN_INVALID',
                message = 'generation-bound action requires an NPC generation context' }
        end
        return nil
    end
    if not generationBoundActions[action] then
        return nil, { code = 'ACTION_TOKEN_INVALID', message = 'generation binding is not valid for this action' }
    end
    if not safeToken(generation) then
        return nil, { code = 'ACTION_TOKEN_INVALID', message = 'generation binding is invalid' }
    end
    local profileKey = payload.profileKey
    local travelKey = payload.travelKey
    if not safeToken(profileKey) or not safeToken(travelKey) then
        return nil, { code = 'ACTION_TOKEN_INVALID', message = 'generation binding requires a trusted NPC travel context' }
    end
    local registry = type(services) == 'table' and services.npcEntityRegistry or nil
    if type(registry) ~= 'table' or type(registry.get) ~= 'function' then
        return nil, { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'NPC generation registry is unavailable' }
    end
    local current = registry:get(profileKey)
    local binding = type(current) == 'table' and current.ok == true and current.value or nil
    local bindingBookingId = type(binding) == 'table' and safeBindingId(binding.bookingId) or nil
    local requestedBookingId = safeBindingId(bookingId)
    if type(binding) ~= 'table' or not bindingBookingId or not requestedBookingId
        or bindingBookingId ~= requestedBookingId
        or binding.travelKey ~= travelKey
        or binding.generationToken ~= generation then
        return nil, { code = 'ACTION_TOKEN_INVALID', message = 'generation binding does not match the server NPC context' }
    end
    return generation
end

local function issueRequestedToken(services, playerSource, payload)
    local tokens = type(services) == 'table' and services.actionTokens or nil
    if type(tokens) ~= 'table' or type(tokens.issue) ~= 'function' or type(tokens.requires) ~= 'function' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'action token service is unavailable' } }
    end
    if not tokens:requires() then return { ok = true, success = true, value = { bypassed = true }, data = { bypassed = true } } end
    local action = payload.action
    if not criticalActions[action] and action ~= 'booking:confirm' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_INVALID', message = 'requested action is not token protected' } }
    end
    local bookingId = payload.bookingId or payload.booking_id
    if type(bookingId) ~= 'string' and type(bookingId) ~= 'number' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_INVALID', message = 'booking ID is required for token issuance' } }
    end
    local actor = resolveActor(services, playerSource)
    local bookingService = type(services) == 'table' and services.booking or nil
    if not actor or type(bookingService) ~= 'table' or type(bookingService.get) ~= 'function' then
        return { ok = false, success = false, error = { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'booking authorization service is unavailable' } }
    end
    local bookingResult = bookingService:get(bookingId)
    local booking = type(bookingResult) == 'table' and bookingResult.ok == true and bookingResult.value or nil
    if type(booking) ~= 'table' or tostring(booking.clientRef or booking.client_ref or '') ~= actor.ref then
        return { ok = false, success = false, error = { code = 'API_FORBIDDEN', message = 'booking does not belong to this player' } }
    end
    local bookingStatus = type(booking.status) == 'string' and booking.status:upper() or nil
    if bookingStatus and terminalBookingStatuses[bookingStatus] then
        return { ok = false, success = false,
            error = { code = 'API_FORBIDDEN', message = 'booking is already terminal' } }
    end
    local generation, generationError = resolveGenerationBinding(services, bookingId, action, payload)
    if generationError then
        return { ok = false, success = false, error = generationError }
    end
    local issued = tokens:issue(playerSource, bookingId, action, generation and { generation = generation } or nil)
    if type(issued) ~= 'table' or issued.ok ~= true then return issued end
    return issued
end

local function sendResponse(playerSource, id, services, method, payload, result)
    local projected = publicResult(services, method, result)
    local tokenized = attachActionToken(services, playerSource, method, payload, projected)
    if type(triggerClientEvent) == 'function' then
        triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id,
            withRequestId(id, tokenized))
    end
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

local function authorizeCritical(services, playerSource, requestIdValue, method, payload)
    local tokens = type(services) == 'table' and services.actionTokens or nil
    if not criticalActions[method] then return true end
    if type(tokens) ~= 'table' or type(tokens.authorize) ~= 'function'
        or type(tokens.requires) ~= 'function' then
        local unavailable = { ok = false, success = false,
            error = { code = 'ACTION_TOKEN_UNAVAILABLE', message = 'critical action authorization is unavailable' } }
        if type(triggerClientEvent) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, requestIdValue, withRequestId(requestIdValue, unavailable))
        end
        return false
    end
    if not tokens:requires() then return true end
    local bookingId = payload.bookingId or payload.booking_id or payload.quoteId or payload.quote_id
    local token = payload.actionToken or payload.action_token
    local generation = payload.generationToken or payload.generation_token
    local result = tokens:authorize(playerSource, bookingId, method, token,
        generation and { generation = generation } or nil)
    if type(result) == 'table' and result.ok == true then return true end
    if type(triggerClientEvent) == 'function' then
        triggerClientEvent('gnsh-nightshift:nui:response', playerSource, requestIdValue, withRequestId(requestIdValue, result))
    end
    return false
end

if type(registerNetEvent) == 'function' and type(addEventHandler) == 'function' then
    registerNetEvent('gnsh-nightshift:nui:request')
    addEventHandler('gnsh-nightshift:nui:request', function(id, method, payload)
        -- FXServer may expose the event source as either a number or a
        -- numeric string depending on the host/runtime boundary. Normalize
        -- it once, while still rejecting console, fractional, and non-finite
        -- values so every response remains bound to a real player source.
        local playerSource = tonumber(source)
        if type(triggerClientEvent) ~= 'function' or type(playerSource) ~= 'number'
            or playerSource ~= playerSource or playerSource == math.huge or playerSource == -math.huge
            or playerSource < 1 or playerSource ~= math.floor(playerSource) then return end
        if not requestId(id) or type(method) ~= 'string' or not allowedMethods[method] or type(payload) ~= 'table' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id or '', errorResult(id or '', 'NUI_REQUEST_INVALID', 'Request is invalid'))
            return
        end
        local services = stageServices()
        if not rateLimitRequest(services, playerSource, id, method) then return end
        if not authorizeCritical(services, playerSource, id, method, payload) then return end
        if method == 'security:action-token' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id,
                withRequestId(id, issueRequestedToken(services, playerSource, payload)))
            return
        end
        local servicePayload = stripActionToken(payload)
        if method == 'marketplace:list' and type(services) == 'table' and type(services.marketplace) == 'table' then
            local request = {}
            for key, value in pairs(servicePayload) do request[key] = value end
            request.source = playerSource
            local result = services.marketplace:list(request)
            if type(result) == 'table' and result.ok == true and type(result.value) == 'table' then
                local value = copy(result.value)
                value.locations = safeLocationOptions(services, playerSource)
                result = copy(result); result.value = value
            end
            sendResponse(playerSource, id, services, method, payload, result)
            return
        end
        if method == 'booking:quote' and type(services) == 'table' and type(services.clientBookingCommands) == 'table' and type(services.clientBookingCommands.quote) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientBookingCommands:quote(playerSource, servicePayload))
            return
        end
        if method == 'booking:confirm' and type(services) == 'table' and type(services.clientBookingCommands) == 'table' and type(services.clientBookingCommands.confirm) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientBookingCommands:confirm(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:confirm' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirm) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirm(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:travel' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.travel) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:travel(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:spawn' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.spawn) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:spawn(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:spawn-confirm' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmSpawn) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmSpawn(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmArrival) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmArrival(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:client-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmClientArrival) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmClientArrival(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:npc-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmNpcArrival) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmNpcArrival(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:pickup-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmArrival) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmArrival(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:vehicle-bind' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.bindVehicle) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:bindVehicle(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:vehicle-entry' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.enterVehicle) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:enterVehicle(playerSource, servicePayload.bookingId))
            return
        end
        if method == 'client-mode:destination-travel' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.startDestinationTravel) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:startDestinationTravel(playerSource, servicePayload.bookingId))
            return
        end
        if method == 'client-mode:destination-arrival' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.confirmDestinationArrival) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:confirmDestinationArrival(playerSource, servicePayload))
            return
        end
        if method == 'client-mode:session-start' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.startSession) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:startSession(playerSource, servicePayload.bookingId, servicePayload))
            return
        end
        if method == 'client-mode:session-complete' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.completeSession) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:completeSession(playerSource, servicePayload.token, servicePayload))
            return
        end
        if method == 'client-mode:travel-progress' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.updateTravelProgress) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, publicResult(services, method, services.clientMode:updateTravelProgress(playerSource, payload.bookingId))))
            return
        end
        if method == 'client-mode:recover' and type(services) == 'table' and type(services.clientMode) == 'table' and type(services.clientMode.recoverTravel) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.clientMode:recoverTravel(playerSource, servicePayload.bookingId, servicePayload.recoveryState))
            return
        end
        if method == 'client-bookings:list' and type(services) == 'table' and type(services.clientBooking) == 'table' and type(services.clientBooking.list) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.clientBooking:list(playerSource, payload)))
            return
        end
        if method == 'review:submit' and type(services) == 'table' and type(services.review) == 'table' and type(services.review.submit) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.review:submit(playerSource, servicePayload))
            return
        end
        if method == 'review:get' and type(services) == 'table' and type(services.review) == 'table' and type(services.review.get) == 'function' then
            triggerClientEvent('gnsh-nightshift:nui:response', playerSource, id, withRequestId(id, services.review:get(playerSource, payload.bookingId)))
            return
        end
        if method == 'favorite:add' and type(services) == 'table' and type(services.favorite) == 'table' and type(services.favorite.add) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.favorite:add(playerSource, servicePayload.workerId or servicePayload.workerKey))
            return
        end
        if method == 'favorite:remove' and type(services) == 'table' and type(services.favorite) == 'table' and type(services.favorite.remove) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.favorite:remove(playerSource, servicePayload.workerId or servicePayload.workerKey))
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
            sendResponse(playerSource, id, services, method, payload,
                services.bookAgain:quote(playerSource, servicePayload))
            return
        end
        if method == 'book-again:confirm' and type(services) == 'table' and type(services.bookAgain) == 'table' and type(services.bookAgain.confirm) == 'function' then
            sendResponse(playerSource, id, services, method, payload,
                services.bookAgain:confirm(playerSource, servicePayload))
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
