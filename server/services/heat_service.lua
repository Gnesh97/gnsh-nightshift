NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Heat = NightShift.Heat

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
    return out
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function validKey(value) return type(value) == 'string' and value:match('%S') and #value <= 160 end
local function nowOf(self, value)
    if value ~= nil then return tonumber(value) end
    if self._clock and type(self._clock.now) == 'function' then return tonumber(self._clock:now()) end
    return os.time()
end

local function validRef(value) return type(value) == 'string' and value:match('%S') and #value <= 96 end

local function resolvedValue(value)
    if type(value) == 'table' and value.ok ~= nil then
        return value.ok == true and value.value or nil
    end
    return value
end

function Service.new(options)
    options = options or {}
    local raw = options.config or NightShift.HeatConfig or {}
    if type(raw) ~= 'table' then return nil, Result.err('HEAT_INVALID', 'heat config must be a table') end
    local min, max = tonumber(raw.min) or 0, tonumber(raw.max) or 100
    local interval = tonumber(raw.decayIntervalSeconds) or 300
    local maxKeys = tonumber(raw.maxEventKeys) or 2048
    if min < 0 or max <= min or max > 100 or interval < 1 or interval ~= math.floor(interval) or maxKeys < 1 or maxKeys ~= math.floor(maxKeys) then
        return nil, Result.err('HEAT_INVALID', 'heat config bounds are invalid')
    end
    local eventIncrements = raw.eventIncrements or {}
    if type(eventIncrements) ~= 'table' then
        return nil, Result.err(Codes.HEAT_INVALID, 'heat event increments must be a table')
    end
    for eventType, increments in pairs(eventIncrements) do
        if type(eventType) ~= 'string' or type(increments) ~= 'table' then
            return nil, Result.err(Codes.HEAT_INVALID, 'heat event increment entry is invalid')
        end
        for _, amount in pairs(increments) do
            if not finite(amount) or amount < 0 or amount > 100 then
                return nil, Result.err(Codes.HEAT_INVALID, 'heat event increment is outside safe bounds')
            end
        end
    end
    local domain, errorResult = Heat.new({ min = min, max = max })
    if not domain then return nil, errorResult end
    return setmetatable({
        _config = copy(raw), _domain = domain, _clock = options.clock,
        _districtResolver = options.districtResolver or options.heatDistrictResolver,
        _players = {}, _districts = {}, _events = {}, _eventOrder = {},
        _eventIncrements = copy(eventIncrements)
    }, Service)
end

function Service:isEnabled() return self._config.enabled ~= false end
function Service:configuration() return copy(self._config) end

function Service:_state(playerKey, district, timestamp)
    local player = playerKey and self._players[playerKey] or nil
    local districtState = self._districts[district]
    local at = timestamp or nowOf(self)
    local function decay(state, playerScope)
        if playerScope and self._config.playerEnabled == false then return nil end
        if not state then return { [playerScope and 'playerHeat' or 'districtPressure'] = 0, updatedAt = at } end
        local elapsed = math.max(0, at - (state.updatedAt or at))
        local rates = { intervalSeconds = self._config.decayIntervalSeconds, player = self._config.playerDecay or 0, district = self._config.districtDecay or 0 }
        local decayed = self._domain:decay(state, elapsed, rates)
        return decayed.ok and decayed.value or state
    end
    return playerKey and decay(player, true) or nil, decay(districtState, false)
end

function Service:record(event)
    if not self:isEnabled() then return Result.err('HEAT_UNAVAILABLE', 'heat is disabled') end
    if type(event) ~= 'table' or not validKey(event.eventKey) or not validRef(event.district) then
        return Result.err('HEAT_INVALID', 'eventKey and district are required')
    end
    if self._events[event.eventKey] then
        return Result.ok({ idempotent = true, eventKey = event.eventKey, district = event.district })
    end
    local timestamp = nowOf(self, event.occurredAt)
    if not finite(timestamp) or timestamp < 0 then return Result.err(Codes.HEAT_INVALID, 'event timestamp is invalid') end
    local playerKey = event.playerKey
    if playerKey ~= nil and not validRef(playerKey) then return Result.err('HEAT_INVALID', 'player key is invalid') end
    local increments = self._eventIncrements[event.eventType] or {}
    local playerAmount = event.playerAmount ~= nil and tonumber(event.playerAmount) or tonumber(increments.player or self._config.playerIncrement or 0)
    if not playerKey then playerAmount = nil end
    local districtAmount = event.districtAmount ~= nil and tonumber(event.districtAmount) or tonumber(increments.district or self._config.districtIncrement or 0)
    if (playerAmount ~= nil and (not finite(playerAmount) or playerAmount < 0)) or not finite(districtAmount) or districtAmount < 0 then return Result.err('HEAT_INVALID', 'heat increments are invalid') end
    local player, district = self:_state(playerKey, event.district, timestamp)
    local applied = self._domain:apply({ playerHeat = player and player.playerHeat or nil, districtPressure = district.districtPressure, updatedAt = timestamp }, { player = self._config.playerEnabled ~= false and playerAmount or nil, district = districtAmount, updatedAt = timestamp })
    if not applied.ok then return applied end
    local value = applied.value
    value.playerKey, value.district, value.eventKey, value.updatedAt = playerKey, event.district, event.eventKey, timestamp
    if playerKey and self._config.playerEnabled ~= false then
        self._players[playerKey] = { playerHeat = value.playerHeat, district = event.district, updatedAt = timestamp }
    elseif playerKey then
        self._players[playerKey] = nil
    end
    self._districts[event.district] = { districtPressure = value.districtPressure, updatedAt = timestamp }
    self._events[event.eventKey] = true; self._eventOrder[#self._eventOrder + 1] = event.eventKey
    while #self._eventOrder > (self._config.maxEventKeys or 2048) do self._events[table.remove(self._eventOrder, 1)] = nil end
    return Result.ok(value, { serverAuthoritative = true })
end

function Service:get(request)
    request = request or {}
    if not self:isEnabled() then return Result.err('HEAT_UNAVAILABLE', 'heat is disabled') end
    if not validRef(request.district) then return Result.err('HEAT_INVALID', 'district is required') end
    if request.playerKey ~= nil and not validRef(request.playerKey) then
        return Result.err(Codes.HEAT_INVALID, 'player key is invalid')
    end
    local timestamp = nowOf(self, request.now)
    local player = request.playerKey and self:_state(request.playerKey, request.district, timestamp) or nil
    local _, district = self:_state(nil, request.district, timestamp)
    return Result.ok({ playerKey = request.playerKey, district = request.district, playerHeat = player and player.playerHeat or nil, districtPressure = district.districtPressure, at = timestamp })
end

function Service:decay(now)
    if not self:isEnabled() then return Result.err('HEAT_UNAVAILABLE', 'heat is disabled') end
    local timestamp = nowOf(self, now)
    local changed = 0
    local interval = math.max(1, tonumber(self._config.decayIntervalSeconds) or 300)
    local playerRate, districtRate = tonumber(self._config.playerDecay) or 0, tonumber(self._config.districtDecay) or 0
    for key, state in pairs(self._players) do
        local elapsed = math.max(0, timestamp - (state.updatedAt or timestamp))
        local intervals = math.floor(elapsed / interval)
        if intervals > 0 then
            self._players[key] = { playerHeat = self._domain:clamp((state.playerHeat or 0) - intervals * playerRate), district = state.district, updatedAt = state.updatedAt + intervals * interval }
            changed = changed + 1
        end
    end
    for district, state in pairs(self._districts) do
        local elapsed = math.max(0, timestamp - (state.updatedAt or timestamp))
        local intervals = math.floor(elapsed / interval)
        if intervals > 0 then
            self._districts[district] = { districtPressure = self._domain:clamp(state.districtPressure - intervals * districtRate), updatedAt = state.updatedAt + intervals * interval }
            changed = changed + 1
        end
    end
    return Result.ok({ changed = changed, at = timestamp })
end

function Service:attach(eventBus, names)
    if type(eventBus) ~= 'table' or type(eventBus.subscribe) ~= 'function' then return Result.err('HEAT_INVALID', 'event bus is required') end
    local subscriptions = {}
    for _, name in ipairs(names or { 'booking.state_changed', 'booking.incident_reported' }) do
        local handle = eventBus:subscribe(name, function(envelope)
            local payload = type(envelope) == 'table' and envelope.payload or envelope
            if type(payload) ~= 'table' then return Result.ok({ skipped = true }, { skipped = true }) end
            local booking = type(payload.booking) == 'table' and payload.booking or {}
            local incident = type(payload.incident) == 'table' and payload.incident or {}
            local metadata = type(payload.metadata) == 'table' and payload.metadata or {}
            local incidentMetadata = type(incident.metadata) == 'table' and incident.metadata or {}
            local district = payload.district or payload.districtId or metadata.district
                or booking.district or booking.districtId
                or incident.district or incident.districtId
                or incidentMetadata.district
            if district == nil and type(self._districtResolver) == 'function' then
                local ok, resolved = pcall(self._districtResolver, copy(payload), copy(booking), copy(incident))
                if ok then
                    resolved = resolvedValue(resolved)
                    district = type(resolved) == 'table' and (resolved.district or resolved.id or resolved.key) or resolved
                end
            end
            local eventKey = payload.eventKey or incident.eventKey
            if eventKey == nil and type(envelope) == 'table' then
                eventKey = envelope.eventName and ('%s:%s'):format(envelope.eventName, tostring(envelope.occurredAt or 'unknown'))
            end
            if type(eventKey) ~= 'string' or type(district) ~= 'string' or district:match('%S') == nil then
                return Result.ok({ skipped = true, reason = 'event has no heat district' }, { skipped = true })
            end
            local playerKey = payload.playerKey or booking.workerProfileId or booking.workerId or incident.playerKey
            return self:record({
                eventKey = eventKey,
                eventType = payload.eventType or metadata.eventType or incident.type or name,
                district = district,
                playerKey = playerKey,
                occurredAt = payload.occurredAt or metadata.occurredAt
                    or (type(envelope) == 'table' and envelope.occurredAt)
            })
        end)
        if handle then subscriptions[#subscriptions + 1] = handle end
    end
    return Result.ok({ subscriptions = subscriptions })
end

NightShift.HeatService = Service
NightShift.Services.Heat = Service
