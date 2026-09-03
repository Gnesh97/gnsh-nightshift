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

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function invalid(message, details)
    return Result.err(Codes.SCHEDULING_INVALID, message, details)
end

-- Convert the domain's numeric/UTC timestamp forms without relying on the
-- host's local timezone. DATETIME values from MariaDB are treated as UTC.
local function daysFromCivil(year, month, day)
    local adjusted = year - (month <= 2 and 1 or 0)
    local era = math.floor((adjusted >= 0 and adjusted or adjusted - 399) / 400)
    local yearOfEra = adjusted - era * 400
    local monthPrime = month + (month > 2 and -3 or 9)
    local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
    return era * 146097 + dayOfEra - 719468
end

local function timestampEpoch(value)
    if finite(value) then
        value = tonumber(value)
        if value < 0 then return nil end
        if value >= 100000000000 then value = value / 1000 end
        return value
    end
    if type(value) ~= 'string' or not text(value, 64) then return nil end
    local year, month, day, hour, minute, second, suffix = value:match(
        '^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$'
    )
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if not year or not month or not day or not hour or not minute or not second then return nil end
    if month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then return nil end
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local daysInMonth = ({ 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month]
    if day < 1 or day > daysInMonth then return nil end
    if suffix ~= '' and suffix ~= 'Z' and suffix:match('^%.%d+Z?$') == nil then return nil end
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

local function windowFor(booking, defaultDuration)
    if type(booking) ~= 'table' then return nil, invalid('schedule booking is required') end
    local start = timestampEpoch(booking.scheduledAt or booking.startAt)
    if not start then return nil, invalid('scheduled booking timestamp is invalid', { field = 'scheduledAt' }) end
    local finish = timestampEpoch(booking.endAt)
    if not finish then
        local package = type(booking.servicePackage) == 'table' and booking.servicePackage or {}
        local duration = integer(booking.durationSeconds, 1, 86400)
        if not duration then duration = integer(package.durationMinutes, 1, 10080) and package.durationMinutes * 60 end
        duration = duration or defaultDuration
        finish = start + duration
    end
    if finish <= start then return nil, invalid('schedule booking window is invalid') end
    return { startAt = start, endAt = finish }
end

local function resourceMatch(candidate, existing)
    local worker = text(candidate.workerRef, 160) and text(existing.workerRef, 160) and candidate.workerRef == existing.workerRef
    local location = text(candidate.locationRef, 160) and text(existing.locationRef, 160) and candidate.locationRef == existing.locationRef
    return worker, location
end

local function overlap(first, second, buffer)
    return first.startAt < second.endAt + buffer and second.startAt < first.endAt + buffer
end

function Service.new(options)
    options = options or {}
    local config = options.config or NightShift.SchedulingConfig or {}
    if type(config) ~= 'table' then return nil, invalid('scheduling configuration must be a table') end
    local enabled = config.enabled
    if enabled == nil then enabled = true end
    if type(enabled) ~= 'boolean' then return nil, invalid('scheduling enabled flag must be boolean') end
    local buffer = options.bufferSeconds
    if buffer == nil then buffer = config.conflictBufferSeconds end
    buffer = buffer == nil and 60 or integer(buffer, 0, 3600)
    if buffer == nil then return nil, invalid('schedule conflict buffer is invalid') end
    local duration = options.defaultDurationSeconds
    if duration == nil then duration = config.defaultDurationSeconds end
    duration = duration == nil and 1800 or integer(duration, 1, 86400)
    if duration == nil then return nil, invalid('schedule default duration is invalid') end
    local repository = options.repository or options.bookingRepository
    local listBookings = options.listBookings or options.list
    if listBookings == nil and type(repository) == 'table' and type(repository.findScheduleCandidates) == 'function' then
        listBookings = function(candidate, queryOptions)
            return repository:findScheduleCandidates(candidate, queryOptions)
        end
    end
    return setmetatable({
        _enabled = enabled,
        _buffer = buffer,
        _defaultDuration = duration,
        _listBookings = listBookings
    }, Service)
end

function Service:isEnabled()
    return self._enabled == true
end

function Service:window(booking)
    return windowFor(booking, self._defaultDuration)
end

function Service:check(candidate, existing, options)
    if not self:isEnabled() then return Result.ok({ skipped = true, conflict = false }, { disabled = true }) end
    local candidateWindow, windowError = self:window(candidate)
    if not candidateWindow then return windowError end
    options = options or {}
    if existing == nil and type(self._listBookings) == 'function' then
        local ok, result = pcall(self._listBookings, candidate, copy(options))
        if not ok or type(result) ~= 'table' then return Result.err(Codes.SCHEDULING_NOT_READY, 'schedule conflict lookup failed') end
        if result.ok == false then return result end
        existing = result.ok == true and result.value or result
    end
    if existing == nil then existing = {} end
    if type(existing) ~= 'table' then return invalid('schedule conflict candidates must be an array') end
    local buffer = options.bufferSeconds
    if buffer == nil then buffer = self._buffer end
    buffer = integer(buffer, 0, 3600)
    if buffer == nil then return invalid('schedule conflict buffer is invalid') end
    local checked = 0
    for _, item in ipairs(existing) do
        if type(item) == 'table' and tostring(item.id or '') ~= tostring(candidate and candidate.id or '') then
            local workerMatch, locationMatch = resourceMatch(candidate, item)
            if workerMatch or locationMatch then
                local existingWindow = self:window(item)
                if existingWindow and overlap(candidateWindow, existingWindow, buffer) then
                    local conflictType = workerMatch and 'WORKER' or 'LOCATION'
                    return Result.err(Codes.SCHEDULING_CONFLICT, 'schedule conflicts with an existing booking', {
                        conflictBookingId = item.id,
                        conflictType = conflictType,
                        bufferSeconds = buffer,
                        candidateWindow = copy(candidateWindow),
                        conflictWindow = copy(existingWindow)
                    })
                end
            end
            checked = checked + 1
        end
    end
    return Result.ok({ conflict = false, checked = checked, window = candidateWindow }, { bufferSeconds = buffer })
end

Service.conflicts = Service.check
Service.toEpoch = timestampEpoch
Service.windowFor = windowFor
NightShift.ScheduleConflictService = Service
NightShift.Services.ScheduleConflict = Service
