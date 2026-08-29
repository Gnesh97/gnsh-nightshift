NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Reservation = {}
Reservation.__index = Reservation

local statuses = { RESERVED=true, OCCUPIED=true, RELEASED=true, EXPIRED=true }

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

local function ref(value)
    return text(value, 160) and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.RESERVATION_INVALID, message, details)
end

function Reservation.new(values)
    if type(values) ~= 'table' then return nil, invalid('location reservation values must be a table') end
    local source = copy(values)
    local allowed = {
        id=true, recordId=true, record_id=true, reservationKey=true, reservation_key=true,
        activeKey=true, active_key=true, locationRef=true, location_ref=true,
        bookingId=true, booking_id=true, status=true, holdUntil=true, hold_until=true,
        version=true, createdAt=true, created_at=true, updatedAt=true, updated_at=true
    }
    for key in pairs(source) do
        if not allowed[key] then return nil, invalid('location reservation field is not allowlisted', { field = tostring(key) }) end
    end
    local reservationKey = source.reservationKey or source.reservation_key or source.activeKey or source.active_key
    local locationRef = source.locationRef or source.location_ref
    local bookingId = source.bookingId or source.booking_id
    local status = tostring(source.status or 'RESERVED'):upper()
    local rawHoldUntil = source.holdUntil or source.hold_until
    local holdUntil = tonumber(rawHoldUntil)
    if not ref(reservationKey) then return nil, invalid('location reservation key is invalid') end
    if not ref(locationRef) then return nil, invalid('location reservation location reference is invalid') end
    if not text(bookingId, 160) and tonumber(bookingId) == nil then return nil, invalid('location reservation booking ID is invalid') end
    if not statuses[status] then return nil, invalid('location reservation status is invalid') end
    if rawHoldUntil ~= nil and holdUntil == nil then
        if not text(rawHoldUntil, 64) then return nil, invalid('location reservation hold expiry is invalid') end
        holdUntil = rawHoldUntil
    elseif holdUntil ~= nil and (not finite(holdUntil) or holdUntil < 0) then
        return nil, invalid('location reservation hold expiry is invalid')
    end
    local version = source.version == nil and 1 or tonumber(source.version)
    if not version or version < 1 or version ~= math.floor(version) then return nil, invalid('location reservation version is invalid') end
    local recordId = source.recordId or source.record_id or source.id
    if recordId ~= nil then
        recordId = tonumber(recordId)
        if not recordId or recordId < 1 or recordId ~= math.floor(recordId) then return nil, invalid('location reservation record ID is invalid') end
    end
    return setmetatable({
        id = recordId,
        recordId = recordId,
        reservationKey = reservationKey,
        activeKey = source.activeKey or source.active_key or reservationKey,
        locationRef = locationRef,
        bookingId = tostring(bookingId),
        status = status,
        holdUntil = holdUntil,
        version = version,
        createdAt = source.createdAt or source.created_at,
        updatedAt = source.updatedAt or source.updated_at
    }, Reservation)
end

function Reservation.validate(value)
    local reservation, errorResult = Reservation.new(value)
    if not reservation then return errorResult end
    return Result.ok(reservation)
end

function Reservation:copy()
    return setmetatable(copy(self), Reservation)
end

function Reservation:isActive()
    return self.status == 'RESERVED' or self.status == 'OCCUPIED'
end

function Reservation.toRow(value)
    local reservation = getmetatable(value) == Reservation and value or Reservation.new(value)
    if not reservation then return nil, invalid('location reservation row source is invalid') end
    return {
        reservation_key = reservation.reservationKey,
        active_key = reservation:isActive() and reservation.activeKey or nil,
        location_ref = reservation.locationRef,
        booking_id = reservation.bookingId,
        status = reservation.status,
        hold_until = reservation.holdUntil
    }
end

function Reservation.fromRow(row)
    if type(row) ~= 'table' then return nil, invalid('location reservation database row is invalid') end
    return Reservation.new({
        id = row.id,
        reservationKey = row.reservationKey or row.reservation_key,
        activeKey = row.activeKey or row.active_key,
        locationRef = row.locationRef or row.location_ref,
        bookingId = row.bookingId or row.booking_id,
        status = row.status,
        holdUntil = row.holdUntil or row.hold_until,
        version = row.version,
        createdAt = row.createdAt or row.created_at,
        updatedAt = row.updatedAt or row.updated_at
    })
end

Reservation.statuses = statuses
NightShift.Domain.LocationReservation = Reservation
