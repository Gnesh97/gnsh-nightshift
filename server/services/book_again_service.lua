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

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160) and value:find('%z') == nil
end

local function identifier(value)
    if type(value) == 'number' then
        return value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge
    end
    return type(value) == 'string' and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil and #value <= 160
end

local function invalid(message, details)
    return Result.err(Codes.BOOK_AGAIN_INVALID, message, details)
end

function Service.new(options)
    options = options or {}
    local commands = options.clientBookingCommandService or options.clientBookingCommands or options.bookingCommands
    local worker = options.npcWorkerService or options.workerService
    if type(commands) ~= 'table' or type(commands.quote) ~= 'function' or type(commands.confirm) ~= 'function' then
        return nil, Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again requires the client booking command pipeline')
    end
    if type(worker) ~= 'table' or type(worker.get) ~= 'function' then
        return nil, Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again requires NPC worker availability')
    end
    return setmetatable({
        _commands = commands,
        _worker = worker,
        _relationship = options.relationshipService or options.relationship,
        _booking = options.bookingService or options.booking,
        _clock = options.clock
    }, Service)
end

local function normalizePayload(payload)
    if type(payload) ~= 'table' then return nil, invalid('book again payload must be a table') end
    local allowed = {
        workerId = true, workerKey = true, packageId = true, servicePackageId = true,
        meetingMode = true, locationId = true, locationRef = true, previousBookingId = true
    }
    for key in pairs(payload) do
        if not allowed[key] then return nil, invalid('book again field is not allowlisted', { field = tostring(key) }) end
    end
    local workerId = payload.workerId or payload.workerKey
    local packageId = payload.packageId or payload.servicePackageId
    local locationId = payload.locationId or payload.locationRef
    if not text(workerId, 160) then return nil, invalid('book again worker ID is required') end
    if not text(packageId, 96) then return nil, invalid('book again package ID is required') end
    if not text(locationId, 160) then return nil, invalid('book again location ID is required') end
    if type(payload.meetingMode) ~= 'string' or not payload.meetingMode:match('%S') then
        return nil, invalid('book again meeting mode is required')
    end
    local previousBookingId = payload.previousBookingId
    if previousBookingId ~= nil and not identifier(previousBookingId) then
        return nil, invalid('book again previous booking ID is invalid')
    end
    return {
        workerId = workerId,
        packageId = packageId,
        meetingMode = payload.meetingMode,
        locationId = locationId,
        previousBookingId = previousBookingId
    }
end

function Service:quote(source, payload)
    local normalized, errorResult = normalizePayload(payload)
    if not normalized then return errorResult end
    if normalized.previousBookingId ~= nil then
        if type(self._booking) ~= 'table' or type(self._booking.get) ~= 'function' then
            return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'previous booking verification is unavailable')
        end
        local previous = self._booking:get(normalized.previousBookingId)
        if type(previous) ~= 'table' or not previous.ok then return previous end
        local previousBooking = previous.value or {}
        local previousWorker = previousBooking.workerRef or previousBooking.workerKey
        if previousWorker ~= nil and tostring(previousWorker) ~= tostring(normalized.workerId) then
            return Result.err(Codes.BOOK_AGAIN_INVALID, 'previous booking belongs to another worker')
        end
        normalized.previousBookingId = nil
    end
    local workerResult = self._worker:get(normalized.workerId)
    if type(workerResult) ~= 'table' or not workerResult.ok then return workerResult end
    local worker = workerResult.value or {}
    local state = type(worker.state) == 'string' and worker.state:upper() or ''
    if state ~= '' and state ~= 'AVAILABLE' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'worker is no longer available', { state = state })
    end
    local result = self._commands:quote(source, normalized)
    if type(result) ~= 'table' then
        return Result.err(Codes.BOOK_AGAIN_NOT_AVAILABLE, 'book again quote pipeline returned an invalid result')
    end
    if not result.ok then return result end
    return Result.ok({
        quote = copy(result.value),
        workerId = normalized.workerId,
        packageId = normalized.packageId,
        meetingMode = normalized.meetingMode,
        locationId = normalized.locationId
    }, { bookAgain = true, newQuote = true, oldPriceIgnored = true })
end

function Service:confirm(source, payload)
    if type(payload) ~= 'table' or not text(payload.quoteId, 128) then
        return invalid('book again quote ID is required')
    end
    return self._commands:confirm(source, { quoteId = payload.quoteId })
end

Service.bookAgain = Service.quote
Service.bookAgainQuote = Service.quote
Service.confirmAgain = Service.confirm
NightShift.BookAgainService = Service
NightShift.Services.BookAgain = Service

return Service
