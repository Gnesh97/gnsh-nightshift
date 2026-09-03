NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local CURRENT_STATUSES = { 'TRAVELLING', 'ARRIVED', 'ACTIVE' }
local UPCOMING_STATUSES = { 'DRAFT', 'QUOTED', 'OFFERED', 'ACCEPTED', 'RESERVED' }
local HISTORY_STATUSES = { 'COMPLETED', 'SETTLED', 'DECLINED', 'CANCELLED', 'EXPIRED', 'INTERRUPTED' }
local SAFE_STATUSES = {
    DRAFT = true, QUOTED = true, OFFERED = true, ACCEPTED = true, RESERVED = true,
    TRAVELLING = true, ARRIVED = true, ACTIVE = true, COMPLETED = true, SETTLED = true,
    DECLINED = true, CANCELLED = true, EXPIRED = true, INTERRUPTED = true
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

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function resultCode(result)
    if type(result) ~= 'table' then return nil end
    return result.error and result.error.code or result.code
end

local function unwrap(result, message)
    if type(result) ~= 'table' then return nil, Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, message or 'service returned an invalid result') end
    if result.ok == false then return nil, result end
    if result.ok == true then return result.value or result.data end
    return result
end

local function rowsFrom(result, group)
    local value, err = unwrap(result, 'booking ' .. group .. ' query returned an invalid result')
    if not value then return nil, err end
    local rows = value.items or value
    if type(rows) ~= 'table' then return nil, Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, 'booking ' .. group .. ' query returned invalid rows') end
    local total = tonumber(value.total) or #rows
    if total < 0 or math.floor(total) ~= total then return nil, Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, 'booking ' .. group .. ' query returned an invalid total') end
    return rows, total
end

local function safeWorkerName(workerService, workerRef)
    local fallback = 'NightShift worker'
    if not workerService or not text(workerRef, 160) or type(workerService.get) ~= 'function' then return fallback end
    local ok, result = pcall(workerService.get, workerService, workerRef)
    if not ok then return fallback end
    local worker = unwrap(result)
    if type(worker) ~= 'table' then return fallback end
    local name = worker.alias or worker.displayName or worker.name
    return text(name, 80) and name or fallback
end

local function priceSnapshot(booking)
    local snapshot = booking.agreedPrice or booking.agreed_price or booking.quote
    if type(snapshot) == 'table' then
        local amount = integer(snapshot.amountMinor or snapshot.amount, 0, 100000000000)
        local currency = type(snapshot.currency) == 'string' and snapshot.currency:upper() or nil
        if amount and currency and currency:match('^[A-Z][A-Z][A-Z]$') then return amount, currency end
    end
    local package = type(booking.servicePackage) == 'table' and booking.servicePackage or nil
    if package then
        local amount = integer(package.priceMinor or package.price, 0, 100000000000)
        local currency = type(package.currency) == 'string' and package.currency:upper() or nil
        if amount and currency and currency:match('^[A-Z][A-Z][A-Z]$') then return amount, currency end
    end
    return nil, nil
end

local function deriveEta(service, booking, source)
    if type(service._etaResolver) == 'function' then
        local ok, value = pcall(service._etaResolver, booking, source)
        value = ok and integer(value, 0, 10080) or nil
        if value then return value end
    end
    local scheduledAt = tonumber(booking.scheduledAt)
    if not scheduledAt then return nil end
    local now = os.time()
    if type(service._clock) == 'table' and type(service._clock.now) == 'function' then
        local ok, value = pcall(service._clock.now, service._clock)
        if ok and tonumber(value) then now = tonumber(value) end
    end
    if scheduledAt <= now then return nil end
    return math.min(10080, math.ceil((scheduledAt - now) / 60))
end

local function mapBooking(service, booking, source)
    if type(booking) ~= 'table' or booking.id == nil then return nil, Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, 'booking read model contains an invalid booking') end
    local status = type(booking.status) == 'string' and booking.status:upper() or nil
    if not status or not SAFE_STATUSES[status] then return nil, Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, 'booking read model contains an invalid status') end
    local workerRef = booking.workerRef or booking.worker_ref or booking.workerProfileId or booking.npcWorkerId
    if workerRef ~= nil then workerRef = tostring(workerRef) end
    local amount, currency = priceSnapshot(booking)
    local package = type(booking.servicePackage) == 'table' and booking.servicePackage or nil
    local dto = {
        bookingId = tostring(booking.id),
        workerName = safeWorkerName(service._workerService, workerRef),
        status = status,
        servicePackageId = package and package.id or nil,
        meetingMode = booking.meetingMode or booking.meeting_mode,
        locationType = booking.locationType or booking.location_type,
        amountMinor = amount,
        currency = currency,
        scheduledAt = booking.scheduledAt,
        startedAt = booking.startAt or booking.startedAt or booking.started_at,
        completedAt = booking.completedAt or booking.completed_at,
        etaMinutes = deriveEta(service, booking, source),
    }
    if dto.servicePackageId ~= nil then dto.servicePackageId = tostring(dto.servicePackageId) end
    if dto.meetingMode ~= nil and not text(dto.meetingMode, 64) then dto.meetingMode = nil end
    if dto.locationType ~= nil and not text(dto.locationType, 64) then dto.locationType = nil end
    return dto
end

local function mapMany(service, rows, source)
    local output = {}
    for index, booking in ipairs(rows) do
        local mapped, err = mapBooking(service, booking, source)
        if not mapped then return nil, err end
        output[index] = mapped
    end
    return output
end

local function normalizePage(options, maximum)
    options = options == nil and {} or options
    if type(options) ~= 'table' then return nil, nil, Result.err(Codes.CLIENT_BOOKING_INVALID, 'booking list options must be a table') end
    local limit = options.limit == nil and math.min(20, maximum) or integer(options.limit, 1, maximum)
    local offset = options.offset == nil and 0 or integer(options.offset, 0)
    if not limit then return nil, nil, Result.err(Codes.CLIENT_BOOKING_INVALID, 'booking list limit is invalid') end
    if not offset then return nil, nil, Result.err(Codes.CLIENT_BOOKING_INVALID, 'booking list offset is invalid') end
    return limit, offset
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.bookingRepository
    local identity = options.identityService or options.identity
    if type(repository) ~= 'table' or (type(repository.findForClient) ~= 'function' and type(repository.findByClient) ~= 'function') then
        return nil, Result.err(Codes.REPOSITORY_INVALID, 'client booking query requires a booking repository')
    end
    if type(identity) ~= 'table' or type(identity.resolve) ~= 'function' then return nil, Result.err(Codes.IDENTITY_INVALID, 'client booking query requires identityService') end
    local maxPageSize = integer(options.maxPageSize or options.maxLimit or 50, 1, 100)
    if not maxPageSize then return nil, Result.err(Codes.CLIENT_BOOKING_INVALID, 'client booking page size is invalid') end
    return setmetatable({
        _repository = repository,
        _identity = identity,
        _clientProfile = options.clientProfileService or options.clientProfile,
        _workerService = options.workerService or options.npcWorker,
        _etaResolver = options.etaResolver,
        _clock = options.clock,
        _maxPageSize = maxPageSize
    }, Service)
end

function Service:list(source, options)
    local limit, offset, pageError = normalizePage(options, self._maxPageSize)
    if pageError then return pageError end
    local identityResult = self._identity:resolve(source)
    local identity, identityError = unwrap(identityResult, 'identity service returned an invalid result')
    if not identity then return identityError end
    local clientRef = identity.identityKey or identity.key
    if not text(clientRef, 160) then return Result.err(Codes.CLIENT_BOOKING_QUERY_FAILED, 'resolved identity has no safe client reference') end
    local clientProfileId
    if type(self._clientProfile) == 'table' and type(self._clientProfile.get) == 'function' then
        local profileResult = self._clientProfile:get(source)
        local profile, profileError = unwrap(profileResult, 'client profile service returned an invalid result')
        if not profile then
            if resultCode(profileError) ~= Codes.REPOSITORY_NOT_FOUND then return profileError end
        elseif type(profile) == 'table' then
            clientProfileId = integer(profile.id or profile.profileId, 1, 2147483647)
        end
    end
    local scope = { clientRef = clientRef, clientProfileId = clientProfileId }
    local query = self._repository.findForClient or self._repository.findByClient
    local currentRows, currentError = rowsFrom(query(self._repository, scope, { statuses = CURRENT_STATUSES, limit = 1, offset = 0, order = 'ASC', orderBy = 'scheduled' }), 'current')
    if not currentRows then return currentError end
    local upcomingRows, upcomingError = rowsFrom(query(self._repository, scope, { statuses = UPCOMING_STATUSES, limit = self._maxPageSize, offset = 0, order = 'ASC', orderBy = 'scheduled' }), 'upcoming')
    if not upcomingRows then return upcomingError end
    local historyRows, historyTotalOrError = rowsFrom(query(self._repository, scope, { statuses = HISTORY_STATUSES, limit = limit, offset = offset, order = 'DESC', orderBy = 'history' }), 'history')
    if not historyRows then return historyTotalOrError end
    local current, currentError
    if currentRows[1] then
        current, currentError = mapBooking(self, currentRows[1], source)
        if not current then return currentError end
    end
    local upcoming, upcomingError = mapMany(self, upcomingRows, source)
    if not upcoming then return upcomingError end
    local history, historyError = mapMany(self, historyRows, source)
    if not history then return historyError end
    return Result.ok({ current = current, upcoming = upcoming, history = history, total = historyTotalOrError, limit = limit, offset = offset })
end

NightShift.ClientBookingQueryService = Service
NightShift.ClientBookingService = Service
