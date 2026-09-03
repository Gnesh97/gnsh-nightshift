NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or math.floor(value) ~= value or
        (minimum and value < minimum) or (maximum and value > maximum) then return nil end
    return value
end

function Service.new(options)
    options = options or {}
    local repository = options.bookingRepository or options.repository
    local timeline = options.timelineService or options.timeline
    if type(repository) ~= 'table' or type(repository.findById) ~= 'function' then
        return nil, Result.err(Codes.DISPUTE_INVALID, 'dispute service requires a booking repository')
    end
    if type(timeline) ~= 'table' or type(timeline.history) ~= 'function' then
        return nil, Result.err(Codes.DISPUTE_INVALID, 'dispute service requires a timeline service')
    end
    return setmetatable({ _repository = repository, _timeline = timeline, _payment = options.paymentResolver or options.paymentService }, Service)
end

function Service:read(bookingId, options)
    options = options or {}
    if not integer(bookingId, 1) and type(bookingId) ~= 'string' then
        return Result.err(Codes.DISPUTE_INVALID, 'dispute booking ID is invalid')
    end
    local bookingResult = self._repository:findById(bookingId)
    if type(bookingResult) ~= 'table' or not bookingResult.ok or type(bookingResult.value) ~= 'table' then
        return Result.err(Codes.DISPUTE_NOT_FOUND, 'dispute booking was not found', { bookingId = bookingId })
    end
    local history = self._timeline:history(bookingId, { limit = integer(options.limit, 1, 1000) or 1000, offset = 0 })
    if type(history) ~= 'table' or not history.ok then
        return Result.err(Codes.DISPUTE_OPERATION_FAILED, 'dispute timeline could not be read', { bookingId = bookingId })
    end
    local events, incidents, arrivals = {}, {}, {}
    for _, event in ipairs(history.value or {}) do
        local safeEvent = copy(event)
        events[#events + 1] = safeEvent
        local metadata = type(event.metadata) == 'table' and event.metadata or {}
        if event.eventType == 'INCIDENT_REPORTED' and type(metadata.incident) == 'table' then
            incidents[#incidents + 1] = copy(metadata.incident)
        end
        if event.newState == 'ARRIVED' or metadata.arrivedAt ~= nil then
            arrivals[#arrivals + 1] = {
                occurredAt = event.occurredAt,
                arrivedAt = metadata.arrivedAt or event.occurredAt,
                eventKey = event.eventKey
            }
        end
    end
    local payment = bookingResult.value.paymentState or bookingResult.value.payment
    if type(self._payment) == 'function' then
        local ok, resolved = pcall(self._payment, bookingId, copy(bookingResult.value))
        if ok and type(resolved) == 'table' and resolved.ok then payment = copy(resolved.value) end
    elseif type(self._payment) == 'table' and type(self._payment.getState) == 'function' then
        local resolved = self._payment:getState(bookingId)
        if type(resolved) == 'table' and resolved.ok then payment = copy(resolved.value) end
    end
    return Result.ok({
        bookingId = bookingId,
        booking = {
            id = bookingResult.value.id,
            status = bookingResult.value.status,
            createdAt = bookingResult.value.createdAt,
            updatedAt = bookingResult.value.updatedAt
        },
        events = events,
        arrivals = arrivals,
        paymentState = payment,
        incidents = incidents
    }, { evidenceOnly = true })
end

Service.get = Service.read
Service.review = Service.read
NightShift.DisputeService = Service
NightShift.Services.Dispute = Service
