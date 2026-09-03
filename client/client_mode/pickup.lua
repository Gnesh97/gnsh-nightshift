NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Controller = {}
Controller.__index = Controller

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return value
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(value) then return tonumber(value) end
    end
    local getGameTimer = rawget(_G, 'GetGameTimer')
    if type(getGameTimer) == 'function' then
        local ok, value = pcall(getGameTimer)
        if ok and finite(value) then return tonumber(value) / 1000 end
    end
    return os.time()
end

local function invalid(message, details)
    return Result.err(Codes.PICKUP_WAITING_INVALID, message, details)
end

local function safeTarget(value)
    if type(value) ~= 'table' then return nil end
    local target = value.worldTarget or value.target or value
    if type(target) ~= 'table' then return nil end
    local output = { kind = tostring(target.kind or target.type or 'coords'):lower() }
    if output.kind ~= 'coords' then return nil end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local coordinate = tonumber(target[axis])
        local limit = axis == 'z' and 10000 or 100000
        if not finite(coordinate) or math.abs(coordinate) > limit then return nil end
        output[axis] = coordinate
    end
    if target.heading ~= nil then
        local heading = tonumber(target.heading)
        if not finite(heading) or math.abs(heading) > 360 then return nil end
        output.heading = heading
    end
    return output
end

local function distanceAllowed(result, maximum)
    if type(result) == 'table' and result.ok ~= nil then
        if result.ok ~= true then return false end
        result = result.value
    end
    local value = tonumber(result)
    return finite(value) and value >= 0 and value <= maximum
end

function Controller.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('pickup controller options must be a table') end
    local timeout = tonumber(options.waitingTimeoutSeconds or options.noShowTimeoutSeconds or options.waitingTimeout or 180)
    local radius = tonumber(options.playerProximityMeters or options.proximityRadius or 5)
    if not finite(timeout) or timeout <= 0 or timeout > 86400 then return nil, invalid('pickup waiting timeout is invalid') end
    if not finite(radius) or radius <= 0 or radius > 1000 then return nil, invalid('pickup proximity radius is invalid') end
    if options.navigation ~= nil and (type(options.navigation) ~= 'table' or type(options.navigation.start) ~= 'function') then
        return nil, invalid('pickup navigation controller is invalid')
    end
    return setmetatable({
        _clock = options.clock, _navigation = options.navigation,
        _playerDistance = options.playerDistance or options.proximityCheck,
        _entityExists = options.entityExists,
        _waitingTimeout = timeout, _proximityRadius = radius,
        _onClaim = options.onClaim, _onNoShow = options.onNoShow,
        _onRecovery = options.onRecovery, _state = 'IDLE', _context = nil,
        _startedAt = nil, _waitingAt = nil, _claimedAt = nil
    }, Controller)
end

function Controller:_validateContext(context)
    if type(context) ~= 'table' or context.serverOwned ~= true then return invalid('pickup requires server-owned context') end
    local fields = {
        serverOwned = true, bookingId = true, workerKey = true, profileKey = true,
        generationToken = true, entity = true, networkId = true, ownerRef = true,
        ownerSource = true, pickup = true, location = true, target = true,
        navigationContext = true, arrived = true
    }
    for key in pairs(context) do if not fields[key] then return invalid('pickup context field is not allowlisted', { field = tostring(key) }) end end
    if not token(tostring(context.bookingId or ''), 160) or not token(context.workerKey, 160) or
        not token(context.profileKey, 160) or not token(context.generationToken, 240) then
        return invalid('pickup context references are invalid')
    end
    if context.entity == nil then return invalid('pickup context has no NPC entity') end
    if not text(context.ownerRef, 200) then return Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup context has no booking owner') end
    local target = safeTarget(context.pickup or context.location or context.target)
    if not target then return Result.err(Codes.PICKUP_LOCATION_INVALID, 'pickup context has no safe target') end
    local output = copy(context)
    output.bookingId, output.pickupTarget = tostring(context.bookingId), target
    return output
end

function Controller:start(context)
    local normalized, contextError = self:_validateContext(context)
    if not normalized then return contextError end
    if self._state ~= 'IDLE' and self._state ~= 'STOPPED' then
        if self._context and self._context.bookingId == normalized.bookingId then
            return Result.ok(self:get().value, { idempotent = true })
        end
        return Result.err(Codes.PICKUP_VEHICLE_CONFLICT, 'pickup controller already owns another booking')
    end
    self._context = normalized
    self._startedAt, self._waitingAt = now(self._clock), nil
    self._claimedAt, self._state = nil, 'NAVIGATING'
    if normalized.arrived == true then
        return self:arrive({ bookingId = normalized.bookingId })
    end
    if self._navigation and normalized.navigationContext then
        local navigationContext = copy(normalized.navigationContext)
        navigationContext.serverOwned = true
        navigationContext.bookingId = normalized.bookingId
        local started = self._navigation:start(navigationContext)
        if type(started) ~= 'table' or started.ok ~= true then return started end
    else
        self._state = 'WAITING'
        self._waitingAt = self._startedAt
    end
    return Result.ok(self:get().value, { started = true, serverAuthoritative = true })
end

function Controller:arrive(payload)
    if self._state ~= 'NAVIGATING' and self._state ~= 'WAITING' then return invalid('pickup NPC is not travelling') end
    if type(payload) == 'table' and payload.bookingId ~= nil and tostring(payload.bookingId) ~= tostring(self._context.bookingId) then
        return Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup arrival belongs to another booking')
    end
    self._state, self._waitingAt = 'WAITING', now(self._clock)
    return Result.ok(self:get().value, { arrived = true, serverAuthoritative = true })
end

function Controller:_owner(request)
    if type(request) ~= 'table' then return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup claim request is required') end
    if request.bookingId ~= nil and tostring(request.bookingId) ~= tostring(self._context.bookingId) then
        return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'pickup claim booking does not match the NPC')
    end
    if self._context.ownerSource ~= nil and request.source ~= nil and tostring(request.source) ~= tostring(self._context.ownerSource) then
        return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'another player cannot claim this NPC')
    end
    if tostring(request.ownerRef or '') ~= tostring(self._context.ownerRef) then
        return nil, Result.err(Codes.PICKUP_OWNER_MISMATCH, 'another player cannot claim this NPC')
    end
    return true
end

function Controller:claim(request)
    if self._state ~= 'WAITING' then
        return Result.err(Codes.PICKUP_WAITING_INVALID, 'NPC is not waiting for pickup', { state = self._state })
    end
    local owner, ownerError = self:_owner(request)
    if not owner then return ownerError end
    if type(self._playerDistance) == 'function' then
        local value, ok = pcall(self._playerDistance, copy(self._context), copy(request))
        if not ok or not distanceAllowed(value, self._proximityRadius) then
            return Result.err(Codes.PICKUP_WAITING_INVALID, 'player is not close enough to claim the NPC')
        end
    end
    if type(self._entityExists) == 'function' then
        local exists, ok = pcall(self._entityExists, self._context.entity)
        if not ok or exists ~= true then
            self._state = 'RECOVERING'
            if type(self._onRecovery) == 'function' then pcall(self._onRecovery, 'ENTITY_DELETED', copy(self._context)) end
            return Result.err(Codes.PICKUP_RECOVERY_REQUIRED, 'pickup NPC entity no longer exists')
        end
    end
    if type(self._onClaim) == 'function' then
        local result, ok = pcall(self._onClaim, copy(self._context), copy(request))
        if not ok or result == false then return Result.err(Codes.PICKUP_WAITING_INVALID, 'pickup claim callback rejected the player') end
    end
    self._state, self._claimedAt = 'CLAIMED', now(self._clock)
    return Result.ok(self:get().value, { claimed = true, serverAuthoritative = true })
end

function Controller:tick(atOrOptions)
    if self._state == 'NAVIGATING' and self._navigation then
        local navigated = self._navigation:tick(atOrOptions)
        if navigated.ok and navigated.value and navigated.value.state == 'ARRIVED' then
            return self:arrive()
        end
        return navigated
    end
    if self._state ~= 'WAITING' then return invalid('pickup waiting state is not active') end
    local at = type(atOrOptions) == 'table' and tonumber(atOrOptions.at or atOrOptions.timestamp) or tonumber(atOrOptions)
    at = finite(at) and at or now(self._clock)
    if self._waitingAt and at - self._waitingAt >= self._waitingTimeout then
        self._state = 'NO_SHOW'
        if type(self._onNoShow) == 'function' then pcall(self._onNoShow, copy(self._context)) end
        return Result.err(Codes.PICKUP_WAITING_TIMEOUT, 'pickup waiting timeout elapsed', { bookingId = self._context.bookingId, state = self._state })
    end
    if type(self._entityExists) == 'function' then
        local exists, ok = pcall(self._entityExists, self._context.entity)
        if not ok or exists ~= true then
            self._state = 'RECOVERING'
            if type(self._onRecovery) == 'function' then pcall(self._onRecovery, 'ENTITY_DELETED', copy(self._context)) end
            return Result.err(Codes.PICKUP_RECOVERY_REQUIRED, 'pickup NPC entity no longer exists')
        end
    end
    return Result.ok(self:get().value)
end

function Controller:stop()
    if self._navigation and type(self._navigation.stop) == 'function' then pcall(self._navigation.stop, self._navigation) end
    self._state, self._context = 'STOPPED', nil
    return true
end

function Controller:get()
    local context = copy(self._context)
    return Result.ok({
        state = self._state, bookingId = context and context.bookingId or nil,
        ownerRef = context and context.ownerRef or nil, pickupTarget = context and copy(context.pickupTarget) or nil,
        startedAt = self._startedAt, waitingAt = self._waitingAt, claimedAt = self._claimedAt
    })
end

Controller.wait = Controller.arrive
Controller.claimNpc = Controller.claim
Controller.update = Controller.tick

NightShift.ClientPickupController = Controller
NightShift.ClientModePickup = Controller
