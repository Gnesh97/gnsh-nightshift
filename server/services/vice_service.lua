NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Service = {}
Service.__index = Service

local ARCHETYPE_SCORE = { LOW = 15, NORMAL = 40, MEDIUM = 50, HIGH = 70, AGGRESSIVE = 85 }
local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
    return out
end
local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end
local function text(value, max)
    return type(value) == 'string' and value:match('%S') and #value <= (max or 160)
end
local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end
local function fail(message, details)
    return Result.err(Codes.VICE_INVALID, message, details)
end
local function unwrap(result)
    if type(result) ~= 'table' then return nil end
    if result.ok == false then return nil end
    return result.ok == true and result.value or result
end

local function config(raw)
    raw = type(raw) == 'table' and raw or {}
    local enabled = raw.enabled == nil and false or raw.enabled
    if type(enabled) ~= 'boolean' then return nil, fail('vice enabled flag must be boolean') end
    local function bounded(name, fallback, min, max)
        local value = raw[name] == nil and fallback or tonumber(raw[name])
        if not finite(value) or value < min or value > max then return nil end
        return value
    end
    local threshold = bounded('riskThreshold', 60, 0, 100)
    local dispatchThreshold = bounded('dispatchThreshold', 80, 0, 100)
    local pressureWeight = bounded('districtPressureWeight', 0.5, 0, 1)
    local archetypeWeight = bounded('archetypeWeight', 0.3, 0, 1)
    local bookingWeight = bounded('bookingWeight', 0.2, 0, 1)
    if not threshold or not dispatchThreshold or not pressureWeight or not archetypeWeight or not bookingWeight then
        return nil, fail('vice risk bounds are invalid')
    end
    local dispatch = raw.dispatch == nil and {} or raw.dispatch
    if type(dispatch) ~= 'table' then return nil, fail('vice dispatch config must be a table') end
    local dispatchEnabled = dispatch.enabled == true
    local requireThreshold = dispatch.requireThreshold == nil and true or dispatch.requireThreshold
    if type(requireThreshold) ~= 'boolean' then return nil, fail('vice dispatch threshold flag must be boolean') end
    return {
        enabled = enabled, riskThreshold = threshold, dispatchThreshold = dispatchThreshold,
        districtPressureWeight = pressureWeight, archetypeWeight = archetypeWeight,
        bookingWeight = bookingWeight, dispatch = { enabled = dispatchEnabled, requireThreshold = requireThreshold }
    }
end

local function normalizeArchetype(value)
    if value == nil then return 'NORMAL' end
    if type(value) ~= 'string' then return nil end
    local key = value:upper():gsub('[%s%-]', '_')
    if key == 'STANDARD' then key = 'NORMAL' end
    return ARCHETYPE_SCORE[key] and key or nil
end

local function bookingScore(booking)
    booking = type(booking) == 'table' and booking or {}
    local mode = tostring(booking.meetingMode or booking.mode or booking.locationType or ''):upper()
    if mode == 'STREET' or mode == 'PUBLIC' then return 70, 'STREET_CONTEXT' end
    if mode == 'PRIVATE' or mode == 'APPOINTMENT' then return 20, nil end
    return 40, nil
end

function Service.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, fail('vice service options must be a table') end
    local normalized, errorResult = config(options.config or NightShift.ViceConfig)
    if not normalized then return nil, errorResult end
    return setmetatable({
        _config = normalized,
        _heat = options.heatService or options.heat,
        _dispatch = options.dispatch,
        _pressure = options.districtPressureResolver or options.pressureResolver,
        _archetype = options.archetypeResolver,
        _clock = options.clock
    }, Service)
end

function Service:isEnabled() return self._config.enabled == true end
function Service:configuration() return copy(self._config) end

function Service:_pressureFor(request, district)
    if request.districtPressure ~= nil then return tonumber(request.districtPressure) end
    if type(self._pressure) == 'function' then
        local ok, value = pcall(self._pressure, copy(request), district)
        if ok then
            value = unwrap(value)
            if type(value) == 'table' then value = value.districtPressure or value.pressure end
            if value ~= nil then return tonumber(value) end
        end
    end
    if type(self._heat) == 'table' and type(self._heat.get) == 'function' then
        local ok, value = pcall(self._heat.get, self._heat, { district = district })
        if ok then
            value = unwrap(value)
            if type(value) == 'table' then return tonumber(value.districtPressure or value.pressure or 0) end
        end
    end
    return 0
end

function Service:evaluate(request)
    if not self:isEnabled() then return Result.err(Codes.VICE_UNAVAILABLE, 'vice risk resolver is disabled') end
    if type(request) ~= 'table' then return fail('vice request must be a table') end
    local district = request.district or request.districtId or request.district_id
    if not text(tostring(district or ''), 64) then return fail('vice district is required') end
    district = tostring(district):lower()
    local pressure = self:_pressureFor(request, district)
    if not finite(pressure) or pressure < 0 or pressure > 100 then return fail('district pressure must be between zero and one hundred') end
    local npc = request.npc or request.worker or request.customer or {}
    local archetype = normalizeArchetype(npc.riskArchetype or npc.risk or request.riskArchetype)
    if type(self._archetype) == 'function' then
        local ok, resolved = pcall(self._archetype, copy(request))
        if ok and resolved ~= nil then archetype = normalizeArchetype(resolved) end
    end
    if not archetype then return fail('npc risk archetype is invalid') end
    local bScore, bReason = bookingScore(request.booking or request.context or request)
    local score = clamp(pressure * self._config.districtPressureWeight
        + ARCHETYPE_SCORE[archetype] * self._config.archetypeWeight
        + bScore * self._config.bookingWeight, 0, 100)
    local reasons = {}
    if pressure >= 60 then reasons[#reasons + 1] = 'DISTRICT_PRESSURE_HIGH' end
    if ARCHETYPE_SCORE[archetype] >= 70 then reasons[#reasons + 1] = 'NPC_RISK_HIGH' end
    if bReason then reasons[#reasons + 1] = bReason end
    local triggered = score >= self._config.riskThreshold
    local output = {
        district = district, score = score, riskScore = score,
        band = score >= 80 and 'HIGH' or score >= self._config.riskThreshold and 'ELEVATED' or 'LOW',
        triggered = triggered, archetype = archetype,
        inputs = { districtPressure = pressure, archetypeScore = ARCHETYPE_SCORE[archetype], bookingScore = bScore },
        reason = { codes = reasons, summary = #reasons > 0 and table.concat(reasons, ',') or 'NO_CONFIGURED_TRIGGER' },
        dispatch = { skipped = true, reason = triggered and 'THRESHOLD_NOT_MET' or 'RISK_THRESHOLD_NOT_MET' }
    }
    local booking = request.booking or request.context or {}
    local bookingId = booking.id or booking.bookingId
    if self._config.dispatch.enabled and triggered
        and (not self._config.dispatch.requireThreshold or score >= self._config.dispatchThreshold)
        and type(self._dispatch) == 'table' and type(self._dispatch.emitViceAlert) == 'function' then
        local payload = { bookingId = bookingId and tostring(bookingId) or nil, district = district,
            score = score, archetype = archetype, reason = copy(output.reason), serverAuthoritative = true }
        local ok, dispatchResult = pcall(self._dispatch.emitViceAlert, self._dispatch, payload)
        local emitted = ok and (dispatchResult == true
            or (type(dispatchResult) == 'table' and dispatchResult.ok == true))
        output.dispatch = { emitted = emitted, result = ok and copy(dispatchResult) or nil }
        if not ok then output.dispatch.error = 'dispatch provider failed' end
    end
    return Result.ok(output, { explainable = true, serverAuthoritative = true })
end

Service.resolve = Service.evaluate
Service.assess = Service.evaluate
Service.evaluateBooking = Service.evaluate

NightShift.ViceService = Service
NightShift.Services.Vice = Service
