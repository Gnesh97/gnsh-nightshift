NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Dto = {}

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

local function finiteNumber(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

local function identifier(value)
    if type(value) == 'number' then
        return value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge and value
    end
    if type(value) == 'string' and value:match('^[%w%._:%-]+$') and #value <= 128 then return value end
    return nil
end

local function invalid(message, field)
    return Result.err(Codes.API_INVALID, message, field and { field = field } or nil)
end

local function pick(value, ...)
    for index = 1, select('#', ...) do
        local key = select(index, ...)
        if value[key] ~= nil then return value[key] end
    end
    return nil
end

local function safeText(value, field, maximum, required)
    if value == nil and not required then return nil end
    if not text(value, maximum) then return nil, invalid(field .. ' is invalid', field) end
    return value
end

local function safeTimestamp(value, field)
    if value == nil then return nil end
    if type(value) == 'number' then
        if not finiteNumber(value) then return nil, invalid(field .. ' is invalid', field) end
        return math.floor(value)
    end
    if not text(value, 80) then return nil, invalid(field .. ' is invalid', field) end
    return value
end

local function mapTags(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil, invalid('worker tags are invalid', 'worker.tags') end
    local output = {}
    for index, tag in ipairs(value) do
        if index > 12 then break end
        if not text(tag, 48) then return nil, invalid('worker tag is invalid', 'worker.tags') end
        output[index] = tag
    end
    return output
end

function Dto.copy(value)
    return copy(value)
end

function Dto.location(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil, invalid('location is invalid', 'location') end
    local locationId = identifier(pick(value, 'locationId', 'id', 'ref', 'locationRef'))
    if not locationId then return nil, invalid('location ID is invalid', 'location.locationId') end
    local output = { locationId = locationId }
    local name, nameError = safeText(pick(value, 'name', 'label', 'displayName'), 'location.name', 120, false)
    if nameError then return nil, nameError end
    if name then output.name = name end
    local district, districtError = safeText(pick(value, 'district', 'districtId'), 'location.district', 80, false)
    if districtError then return nil, districtError end
    if district then output.district = district end
    local zone, zoneError = safeText(pick(value, 'zone', 'zoneId'), 'location.zone', 80, false)
    if zoneError then return nil, zoneError end
    if zone then output.zone = zone end
    local locationType, typeError = safeText(pick(value, 'locationType', 'type', 'category'), 'location.type', 48, false)
    if typeError then return nil, typeError end
    if locationType then output.locationType = locationType end
    return output
end

function Dto.worker(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then return nil, invalid('worker is invalid', 'worker') end
    local workerId = identifier(pick(value, 'workerId', 'id', 'workerKey', 'key', 'publicId'))
    if not workerId then return nil, invalid('worker ID is invalid', 'worker.workerId') end
    local output = { workerId = workerId }
    local fields = {
        { 'displayName', { 'displayName', 'name', 'label' }, 120 },
        { 'profileType', { 'profileType', 'type' }, 48 },
        { 'priceClass', { 'priceClass', 'band' }, 48 },
        { 'district', { 'district', 'districtId' }, 80 },
        { 'availability', { 'availability', 'status' }, 48 }
    }
    for _, field in ipairs(fields) do
        local key, aliases, maximum = field[1], field[2], field[3]
        local valueToMap = pick(value, table.unpack(aliases))
        local mapped, mapError = safeText(valueToMap, 'worker.' .. key, maximum, false)
        if mapError then return nil, mapError end
        if mapped then output[key] = mapped end
    end
    for _, field in ipairs({ 'rating', 'trustScore', 'reliability' }) do
        local number = finiteNumber(value[field])
        if number ~= nil then output[field] = number end
    end
    local tags, tagsError = mapTags(value.tags)
    if tagsError then return nil, tagsError end
    if tags then output.tags = tags end
    return output
end

function Dto.profileSummary(value)
    if type(value) ~= 'table' then return nil, invalid('profile summary is invalid', 'profile') end
    local output = {}
    local profileId = identifier(pick(value, 'profileId', 'id', 'key'))
    if profileId then output.profileId = profileId end
    for _, field in ipairs({ 'displayName', 'profileType', 'district', 'status' }) do
        local mapped, mapError = safeText(value[field], 'profile.' .. field, 120, false)
        if mapError then return nil, mapError end
        if mapped then output[field] = mapped end
    end
    for _, field in ipairs({ 'rating', 'trustScore', 'reliability', 'completedBookings' }) do
        local number = finiteNumber(value[field])
        if number ~= nil and number >= 0 then output[field] = number end
    end
    return output
end

function Dto.booking(value)
    if type(value) ~= 'table' then return nil, invalid('booking is invalid', 'booking') end
    local bookingId = identifier(pick(value, 'bookingId', 'id', 'bookingKey'))
    if not bookingId then return nil, invalid('booking ID is invalid', 'booking.bookingId') end
    local status, statusError = safeText(pick(value, 'status', 'state', 'bookingStatus'), 'booking.status', 48, true)
    if statusError then return nil, statusError end
    local output = { bookingId = bookingId, status = status }
    for _, field in ipairs({
        { 'mode', { 'mode', 'bookingMode' }, 48 },
        { 'meetingMode', { 'meetingMode' }, 48 },
        { 'package', { 'package', 'packageId', 'servicePackage' }, 96 },
        { 'currency', { 'currency' }, 8 },
        { 'correlationId', { 'correlationId', 'correlation' }, 96 }
    }) do
        local mapped, mapError = safeText(pick(value, table.unpack(field[2])), 'booking.' .. field[1], field[3], false)
        if mapError then return nil, mapError end
        if mapped then output[field[1]] = mapped end
    end
    for _, field in ipairs({ 'amount', 'total', 'offer', 'price' }) do
        local number = finiteNumber(value[field])
        if number ~= nil and number >= 0 then
            output.amount = number
            break
        end
    end
    for _, field in ipairs({ 'createdAt', 'updatedAt', 'scheduledAt', 'startedAt', 'completedAt', 'cancelledAt' }) do
        local mapped, mapError = safeTimestamp(value[field], 'booking.' .. field)
        if mapError then return nil, mapError end
        if mapped then output[field] = mapped end
    end
    local worker, workerError = Dto.worker(value.worker)
    if workerError then return nil, workerError end
    if worker then output.worker = worker end
    local location, locationError = Dto.location(value.location)
    if locationError then return nil, locationError end
    if location then output.location = location end
    return output
end

function Dto.bookingPage(value)
    if type(value) ~= 'table' then return nil, invalid('booking page is invalid', 'page') end
    local source = value.items or value.bookings or value.data
    if type(source) ~= 'table' then return nil, invalid('booking page items are invalid', 'page.items') end
    local output = { items = {} }
    for index, item in ipairs(source) do
        if index > 100 then break end
        local booking, bookingError = Dto.booking(item)
        if bookingError then return nil, bookingError end
        output.items[index] = booking
    end
    local pagination = type(value.pagination) == 'table' and value.pagination or value
    for _, field in ipairs({ 'limit', 'offset', 'total' }) do
        local number = finiteNumber(pagination[field])
        if number ~= nil and number >= 0 then output[field] = math.floor(number) end
    end
    return output
end

NightShift.Api = NightShift.Api or {}
NightShift.Api.Dto = Dto
NightShift.PublicDto = Dto
