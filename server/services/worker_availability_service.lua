NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local states = NightShift.Enums.WorkerAvailabilityStates or { AVAILABLE = true, BUSY = true, OFFLINE = true }

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

local function sourceValue(value)
    value = tonumber(value)
    return value and value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge and value
end

local function invalid(message, details)
    return Result.err(Codes.WORKER_AVAILABILITY_INVALID, message, details)
end

local function denied(message, details)
    return Result.err(Codes.WORKER_AVAILABILITY_DENIED, message, details)
end

local function conflict(message, details)
    return Result.err(Codes.WORKER_AVAILABILITY_CONFLICT, message, details)
end

local function now(clock)
    if type(clock) == 'table' and type(clock.now) == 'function' then
        local ok, value = pcall(clock.now, clock)
        value = tonumber(value)
        if ok and value and value == value and value ~= math.huge and value ~= -math.huge then return value end
    end
    return os.time()
end

local function timestamp(clock, value)
    if NightShift.Clock and type(NightShift.Clock.utcTimestamp) == 'function' then return NightShift.Clock.utcTimestamp(value) end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', tonumber(value) or os.time())
end

local function normalizedState(value)
    value = type(value) == 'string' and value:upper() or nil
    return value and states[value] and value or nil
end

local function unwrap(value)
    if type(value) ~= 'table' then return value end
    if value.ok == false then return nil end
    if value.ok == true then return value.value end
    return value
end

function Service.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('worker availability service options must be a table') end
    local identity = options.identityService or options.identityResolver or options.identity
    local framework = options.frameworkAdapter or options.framework
    local clock = options.clock
    if clock == nil and NightShift.Clock and type(NightShift.Clock.new) == 'function' then clock = NightShift.Clock.new() end
    local requireDuty = options.requireDuty == true or options.useFrameworkDuty == true
    return setmetatable({
        _identity = identity,
        _framework = framework,
        _profile = options.workerProfileService or options.profileService,
        _persistProfile = options.persistProfile == true,
        _requireDuty = requireDuty,
        _dutyResolver = options.dutyResolver,
        _clock = clock,
        _records = {},
        _sources = {},
        _listeners = {}
    }, Service)
end

function Service:_resolveIdentity(source)
    source = sourceValue(source)
    if not source then return nil, invalid('worker availability source must be a positive integer', { source = source }) end
    if type(self._identity) == 'table' and type(self._identity.resolve) == 'function' then
        local ok, result = pcall(self._identity.resolve, self._identity, source)
        if not ok or type(result) ~= 'table' then
            return nil, denied('worker identity is unavailable', { source = source })
        end
        local identity = result.ok == nil and result or result.ok == true and result.value or nil
        if type(identity) ~= 'table' then
            return nil, denied('worker identity is unavailable', { source = source })
        end
        local key = identity.identityKey or identity.key
        if not text(key, 200) then
            local identifier = identity.playerIdentifier or identity.identifier
            if text(identifier, 128) then key = identifier .. ':' .. tostring(identity.characterId or '') end
        end
        if not text(key, 200) then return nil, invalid('worker identity key is invalid', { source = source }) end
        return { identityKey = key, playerIdentifier = identity.playerIdentifier or identity.identifier, characterId = identity.characterId, displayName = identity.displayName, source = source, job = copy(identity.job) }
    end
    local key = self._sources[source] or ('source:' .. tostring(source))
    return { identityKey = key, source = source }
end

function Service:_recordFor(source, create)
    local identity, errorResult = self:_resolveIdentity(source)
    if not identity then return nil, errorResult end
    local previousKey = self._sources[identity.source]
    if previousKey and previousKey ~= identity.identityKey then
        local previousRecord = self._records[previousKey]
        if previousRecord then
            local stale = copy(previousRecord)
            stale.state = 'OFFLINE'
            stale.available = false
            stale.bookingId = nil
            stale.changedAt = now(self._clock)
            stale.observedAt = stale.changedAt
            stale.sourceOfTruth = 'SOURCE_REUSE'
            stale.version = (tonumber(previousRecord.version) or 0) + 1
            self:_notify(stale)
        end
        self._records[previousKey] = nil
    end
    self._sources[identity.source] = identity.identityKey
    local record = self._records[identity.identityKey]
    if not record and create ~= false then
        record = {
            identityKey = identity.identityKey,
            source = identity.source,
            state = 'OFFLINE',
            available = false,
            bookingId = nil,
            district = nil,
            changedAt = now(self._clock),
            observedAt = now(self._clock),
            sourceOfTruth = 'SERVER_TOGGLE',
            version = 1
        }
        self._records[identity.identityKey] = record
    end
    if record then
        record.source = identity.source
        if identity.displayName ~= nil then record.displayName = identity.displayName end
        if identity.job ~= nil then record.job = copy(identity.job) end
    end
    return record, identity
end

function Service:_dutyAllowed(source, identity, options)
    if options and options.ignoreDuty == true then return true end
    if not self._requireDuty then return true end
    local value
    if type(self._dutyResolver) == 'function' then
        local ok, result = pcall(self._dutyResolver, source, copy(identity))
        if ok then value = unwrap(result) end
    elseif type(identity) == 'table' and type(identity.job) == 'table' then
        value = identity.job.onDuty
        if value == nil then value = identity.job.onduty end
    end
    if value == nil and type(self._framework) == 'table' and type(self._framework.getPlayer) == 'function' then
        local ok, result = pcall(self._framework.getPlayer, self._framework, source)
        local player = unwrap(result)
        local job = type(player) == 'table' and player.job or nil
        if type(job) == 'table' then value = job.onDuty; if value == nil then value = job.onduty end end
    end
    if value ~= true then return false end
    return true
end

function Service:_persist(source, state)
    if not self._persistProfile or type(self._profile) ~= 'table' or type(self._profile.update) ~= 'function' then return true end
    local result = self._profile:update(source, { availability = state:lower(), lastActiveAt = timestamp(self._clock, now(self._clock)) })
    if type(result) == 'table' and result.ok == false then return false, result end
    return true
end

function Service:_notify(record)
    local snapshot = copy(record)
    for _, listener in ipairs(self._listeners) do pcall(listener, copy(snapshot)) end
end

function Service:_setRecord(record, identity, state, options)
    options = type(options) == 'table' and options or {}
    local requestedDistrict = options.district
    if requestedDistrict ~= nil then
        requestedDistrict = tostring(requestedDistrict):lower()
        if not token(requestedDistrict, 64) then return invalid('worker availability district is invalid') end
    end
    local previous = record.state
    if previous == state and (requestedDistrict == nil or requestedDistrict == record.district) then
        return Result.ok(record, { previousState = previous, idempotent = true })
    end
    local persisted, persistError = self:_persist(identity.source, state)
    if not persisted then return persistError end
    local nextRecord = copy(record)
    nextRecord.identityKey = identity.identityKey
    nextRecord.source = identity.source
    nextRecord.state = state
    nextRecord.available = state == 'AVAILABLE'
    nextRecord.changedAt = now(self._clock)
    nextRecord.observedAt = nextRecord.changedAt
    nextRecord.sourceOfTruth = 'SERVER_TOGGLE'
    nextRecord.version = (tonumber(record.version) or 0) + 1
    if state ~= 'BUSY' then nextRecord.bookingId = nil end
    if requestedDistrict ~= nil then nextRecord.district = requestedDistrict end
    self._records[identity.identityKey] = nextRecord
    self:_notify(nextRecord)
    return Result.ok(nextRecord, { previousState = previous, idempotent = previous == state })
end

function Service:get(source)
    local record, errorResult = self:_recordFor(source, true)
    if not record then return errorResult end
    return Result.ok(copy(record))
end

function Service:getByIdentity(identityKey)
    if not text(identityKey, 200) then return invalid('worker identity key is invalid') end
    local record = self._records[identityKey]
    if not record then return Result.err(Codes.WORKER_AVAILABILITY_NOT_FOUND, 'worker availability was not found', { identityKey = identityKey }) end
    return Result.ok(copy(record))
end

function Service:setAvailable(source, options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return invalid('worker availability options must be a table') end
    local record, identity = self:_recordFor(source, true)
    if not record then return identity end
    if record.state == 'BUSY' then return conflict('busy worker cannot become available', { source = identity.source, bookingId = record.bookingId }) end
    if not self:_dutyAllowed(identity.source, identity, options) then return denied('worker must have a current duty/availability observation', { source = identity.source }) end
    return self:_setRecord(record, identity, 'AVAILABLE', options)
end

function Service:setOffline(source, reason)
    local record, identity = self:_recordFor(source, true)
    if not record then return identity end
    local result = self:_setRecord(record, identity, 'OFFLINE', { ignoreDuty = true })
    if type(result) == 'table' and result.ok then result.metadata = result.metadata or {}; result.metadata.reason = reason end
    return result
end

function Service:set(source, state, options)
    state = normalizedState(state)
    if not state then return invalid('worker availability state must be AVAILABLE, BUSY, or OFFLINE') end
    if options ~= nil and type(options) ~= 'table' then return invalid('worker availability options must be a table') end
    if state == 'AVAILABLE' then return self:setAvailable(source, options) end
    if state == 'OFFLINE' then return self:setOffline(source, options and options.reason or 'server') end
    options = options or {}
    if type(options) ~= 'table' or not text(options.bookingId or options.booking_id, 160) then return denied('BUSY state requires a server booking lock') end
    return self:lockForBooking(source, options.bookingId or options.booking_id)
end

function Service:lockForBooking(source, bookingId)
    if not text(bookingId, 160) then return invalid('worker booking lock requires a booking ID') end
    local record, identity = self:_recordFor(source, true)
    if not record then return identity end
    if record.state == 'BUSY' then
        if record.bookingId == bookingId then return Result.ok(record, { idempotent = true }) end
        return conflict('worker is already locked by another booking', { bookingId = record.bookingId })
    end
    if record.state ~= 'AVAILABLE' then return denied('worker must be explicitly available before booking', { state = record.state }) end
    if not self:_dutyAllowed(identity.source, identity) then
        return denied('worker must have a current duty/availability observation', { source = identity.source })
    end
    local persisted, persistError = self:_persist(identity.source, 'BUSY')
    if not persisted then return persistError end
    local nextRecord = copy(record)
    nextRecord.state, nextRecord.available, nextRecord.bookingId = 'BUSY', false, bookingId
    nextRecord.changedAt, nextRecord.observedAt = now(self._clock), now(self._clock)
    nextRecord.version = (tonumber(record.version) or 0) + 1
    self._records[identity.identityKey] = nextRecord
    self:_notify(nextRecord)
    return Result.ok(nextRecord, { previousState = record.state })
end

function Service:releaseBooking(source, bookingId, options)
    if not text(bookingId, 160) then return invalid('worker booking release requires a booking ID') end
    if options ~= nil and type(options) ~= 'table' then return invalid('worker booking release options must be a table') end
    local record, identity = self:_recordFor(source, true)
    if not record then return identity end
    if record.state ~= 'BUSY' then return Result.ok(record, { idempotent = true }) end
    if record.bookingId ~= bookingId then return conflict('worker booking lock owner mismatch', { bookingId = record.bookingId }) end
    options = options or {}
    if options.returnAvailable == false then return self:_setRecord(record, identity, 'OFFLINE', options) end
    if not self:_dutyAllowed(identity.source, identity, options) then return self:_setRecord(record, identity, 'OFFLINE', options) end
    return self:_setRecord(record, identity, 'AVAILABLE', options)
end

function Service:reset(source, reason)
    return self:setOffline(source, reason or 'logout')
end

function Service:isAvailable(source)
    local result = self:get(source)
    return result.ok == true and result.value.state == 'AVAILABLE', result
end

function Service:list(options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('worker availability list options must be a table') end
    local output = {}
    for _, record in pairs(self._records) do
        local matches = options.district == nil or record.district == tostring(options.district):lower()
        if matches and (options.availableOnly ~= true or record.state == 'AVAILABLE') then output[#output + 1] = copy(record) end
    end
    table.sort(output, function(left, right) return left.identityKey < right.identityKey end)
    return Result.ok(output, { count = #output })
end

function Service:countAvailable(options)
    options = options or {}
    if type(options) ~= 'table' then return 0 end
    local result = self:list({ district = options.district, availableOnly = true })
    if not result.ok then return 0 end
    return #result.value
end

function Service:onChange(listener)
    if type(listener) ~= 'function' then return invalid('worker availability listener must be a function') end
    self._listeners[#self._listeners + 1] = listener
    return true
end

Service.setAvailability = Service.set
Service.markAvailable = Service.setAvailable
Service.book = Service.lockForBooking
Service.release = Service.releaseBooking
Service.logout = Service.reset

NightShift.WorkerAvailabilityService = Service
NightShift.Services.WorkerAvailability = Service
