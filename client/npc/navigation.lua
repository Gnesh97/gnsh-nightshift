NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Navigation = {}
Navigation.__index = Navigation

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function handle(value)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return value end
    if token(value, 96) then return value end
    return nil
end

local function candidate(value)
    if type(value) ~= 'table' then return nil end
    local kind = tostring(value.kind or value.type or 'coords'):lower()
    if kind ~= 'coords' and kind ~= 'provider' then return nil end
    local output = { kind = kind }
    if kind == 'coords' then
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            local coordinate = tonumber(value[axis])
            local limit = axis == 'z' and 10000 or 100000
            if not finite(coordinate) or math.abs(coordinate) > limit then return nil end
            output[axis] = coordinate
        end
        if value.heading ~= nil then
            local heading = tonumber(value.heading)
            if not finite(heading) or math.abs(heading) > 360 then return nil end
            output.heading = heading
        end
    else
        if not token(value.provider, 96) then return nil end
        output.provider = value.provider
    end
    return output
end

local function invalid(message, details)
    return Result.err(Codes.NPC_NAVIGATION_INVALID, message, details)
end

local function clockNow(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        if ok and finite(tonumber(value)) then return tonumber(value) end
    end
    return os.time()
end

local function atValue(value, fallback)
    if type(value) == 'table' then value = value.at or value.timestamp end
    value = tonumber(value)
    return finite(value) and value or fallback
end

local function call(callback, ...)
    if type(callback) ~= 'function' then return true, nil end
    return pcall(callback, ...)
end

function Navigation.new(options)
    options = options or {}
    local arrivalRadius = tonumber(options.arrivalRadius or 4)
    local navigationTimeout = tonumber(options.navigationTimeout or 120)
    local stuckTimeout = tonumber(options.stuckTimeout or 15)
    local playerAwayDistance = tonumber(options.playerAwayDistance or 120)
    if not finite(arrivalRadius) or arrivalRadius <= 0 or arrivalRadius > 100 then return nil, invalid('navigation arrival radius is invalid') end
    if not finite(navigationTimeout) or navigationTimeout <= 0 or navigationTimeout > 86400 then return nil, invalid('navigation timeout is invalid') end
    if not finite(stuckTimeout) or stuckTimeout <= 0 or stuckTimeout > 3600 then return nil, invalid('navigation stuck timeout is invalid') end
    if not finite(playerAwayDistance) or playerAwayDistance <= 0 or playerAwayDistance > 100000 then return nil, invalid('navigation player distance is invalid') end
    if options.registry ~= nil and (type(options.registry) ~= 'table' or type(options.registry.get) ~= 'function') then
        return nil, invalid('navigation entity registry is invalid')
    end
    return setmetatable({
        _clock = options.clock,
        _registry = options.registry,
        _arrivalRadius = arrivalRadius,
        _navigationTimeout = navigationTimeout,
        _stuckTimeout = stuckTimeout,
        _playerAwayDistance = playerAwayDistance,
        _entityExists = options.entityExists,
        _distance = options.distance,
        _playerDistance = options.playerDistance,
        _moveTo = options.moveTo,
        _safeRecover = options.safeRecover,
        _onArrival = options.onArrival,
        _onRecovery = options.onRecovery,
        _state = 'IDLE',
        _context = nil,
        _startedAt = nil,
        _lastDistance = nil,
        _lastProgressAt = nil
    }, Navigation)
end

function Navigation:start(context)
    if type(context) ~= 'table' or context.serverOwned ~= true then
        return Result.err(Codes.NPC_NAVIGATION_INVALID, 'navigation requires server-owned context')
    end
    local allowed = { serverOwned = true, profileKey = true, generationToken = true, entity = true, target = true, travelKey = true, bookingId = true }
    for key in pairs(context) do if not allowed[key] then return invalid('navigation context field is not allowlisted', { field = tostring(key) }) end end
    if not token(context.profileKey, 160) or not token(context.generationToken, 240) or not handle(context.entity) then
        return invalid('navigation context references are invalid')
    end
    local target = candidate(context.target)
    if not target then return invalid('navigation target is not a safe candidate') end
    if type(self._distance) ~= 'function' or type(self._moveTo) ~= 'function' then
        return Result.err(Codes.NPC_NAVIGATION_INVALID, 'navigation callbacks are not configured')
    end
    if self._registry then
        local binding = self._registry:get(context.profileKey)
        if not binding.ok then return Result.err(Codes.ENTITY_DELETED, 'navigation entity binding is unavailable') end
        if binding.value.generationToken ~= context.generationToken or binding.value.entity ~= context.entity then
            return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'navigation entity generation does not match')
        end
    end
    if self._entityExists ~= nil then
        local existsOk, exists = call(self._entityExists, context.entity)
        if not existsOk or exists ~= true then return Result.err(Codes.ENTITY_DELETED, 'navigation entity no longer exists') end
    end
    local startedAt = clockNow(self._clock)
    self._state, self._context, self._startedAt = 'TRAVELLING', copy(context), startedAt
    self._context.target = target
    self._lastDistance, self._lastProgressAt = math.huge, startedAt
    return Result.ok({ state = self._state, startedAt = startedAt, context = copy(self._context) })
end

local function recoveryResult(self, code, reason, at)
    self._state = 'RECOVERING'
    if type(self._onRecovery) == 'function' then pcall(self._onRecovery, reason, copy(self._context)) end
    local recovered = false
    if type(self._safeRecover) == 'function' then
        local ok, value = pcall(self._safeRecover, reason, copy(self._context))
        recovered = ok and value == true
    end
    if recovered then
        self._state = 'TRAVELLING'
        self._lastProgressAt = at
    end
    return Result.err(code, 'NPC navigation requires recovery', { reason = reason, recovered = recovered })
end

function Navigation:tick(atOrOptions)
    if self._state ~= 'TRAVELLING' then return invalid('navigation is not active') end
    local at = atValue(atOrOptions, clockNow(self._clock))
    if self._entityExists ~= nil then
        local existsOk, exists = call(self._entityExists, self._context.entity)
        if not existsOk or exists ~= true then
            if self._registry then pcall(self._registry.markDeleted, self._registry, self._context.profileKey, self._context.generationToken) end
            return recoveryResult(self, Codes.NPC_NAVIGATION_ENTITY_DELETED, 'ENTITY_DELETED', at)
        end
    end
    if type(self._playerDistance) == 'function' then
        local ok, value = call(self._playerDistance, copy(self._context))
        value = ok and tonumber(value) or nil
        if not finite(value) then return invalid('player distance callback returned an invalid value') end
        if value > self._playerAwayDistance then return recoveryResult(self, Codes.NPC_NAVIGATION_PLAYER_AWAY, 'PLAYER_AWAY', at) end
    end
    local distanceOk, distance = call(self._distance, self._context.entity, copy(self._context.target), copy(self._context))
    distance = distanceOk and tonumber(distance) or nil
    if not finite(distance) or distance < 0 then return invalid('navigation distance callback returned an invalid value') end
    if distance <= self._arrivalRadius then
        self._state = 'ARRIVED'
        if type(self._onArrival) == 'function' then
            local callbackOk = pcall(self._onArrival, copy(self._context))
            if not callbackOk then return invalid('navigation arrival callback failed') end
        end
        return Result.ok({ state = self._state, distance = distance, context = copy(self._context) })
    end
    local moveOk, moved = call(self._moveTo, self._context.entity, copy(self._context.target), copy(self._context))
    if not moveOk or moved == false then return invalid('navigation move callback failed') end
    if distance + 0.01 < self._lastDistance then
        self._lastDistance, self._lastProgressAt = distance, at
    elseif at - self._lastProgressAt >= self._stuckTimeout then
        return recoveryResult(self, Codes.NPC_NAVIGATION_STUCK, 'STUCK', at)
    end
    if at - self._startedAt >= self._navigationTimeout then
        return recoveryResult(self, Codes.NPC_NAVIGATION_TIMEOUT, 'TIMEOUT', at)
    end
    return Result.ok({ state = self._state, distance = distance, context = copy(self._context) })
end

function Navigation:stop()
    self._state, self._context = 'STOPPED', nil
    return true
end

function Navigation:get()
    return Result.ok({ state = self._state, context = copy(self._context) })
end

NightShift.ClientNpcNavigation = Navigation
