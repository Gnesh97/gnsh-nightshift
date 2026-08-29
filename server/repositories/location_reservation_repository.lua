NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.LocationReservation

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'reservation_key', 'active_key', 'location_ref', 'booking_id',
    'status', 'hold_until', 'version', 'created_at', 'updated_at'
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

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'location reservation repository requires a database adapter') end
    local tableName = options.tableName or 'nightshift_location_reservations'
    if not text(tableName, 64) or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then return nil, invalid('location reservation table name is invalid') end
    local base, errorResult = Base.new({
        db = database,
        tableName = tableName,
        columns = columns,
        mapper = function(row)
            local value, mapError = Domain.fromRow(row)
            if not value then return Result.err(Codes.MAPPING_FAILED, 'location reservation row mapping failed', { cause = mapError and mapError.error and mapError.error.code }) end
            return value
        end
    })
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = database, _table = tableName }, Repository)
end

function Repository:findById(id)
    return self._base:findById(id)
end

function Repository:findByKey(key)
    if not text(key, 200) then return invalid('location reservation key is invalid') end
    local selectList, errorResult = self._base:_selectList()
    if not selectList then return errorResult end
    local result = self._db:single(('SELECT %s FROM %s WHERE reservation_key = ? LIMIT 1'):format(selectList, self._table), { key })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'location reservation was not found', { reservationKey = key }) end
    local value, mapResult = self._base:_map(result.value)
    if not value then return mapResult end
    return Result.ok(value)
end

function Repository:findActiveByLocation(locationRef)
    if not text(locationRef, 160) then return invalid('location reference is invalid') end
    local selectList, errorResult = self._base:_selectList()
    if not selectList then return errorResult end
    local result = self._db:single(("SELECT %s FROM %s WHERE location_ref = ? AND active_key IS NOT NULL AND status IN ('RESERVED','OCCUPIED') AND (hold_until IS NULL OR hold_until > CURRENT_TIMESTAMP(3)) LIMIT 1"):format(selectList, self._table), { locationRef })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'active location reservation was not found', { locationRef = locationRef }) end
    local value, mapResult = self._base:_map(result.value)
    if not value then return mapResult end
    return Result.ok(value)
end

function Repository:expireExpired()
    local result = self._db:update(("UPDATE %s SET status = 'EXPIRED', active_key = NULL, version = version + 1, updated_at = CURRENT_TIMESTAMP(3) WHERE active_key IS NOT NULL AND status = 'RESERVED' AND hold_until IS NOT NULL AND hold_until <= CURRENT_TIMESTAMP(3)"):format(self._table), {})
    if type(result) ~= 'table' or not result.ok then return result end
    return Result.ok({ expired = tonumber(result.value and result.value.affectedRows) or 0 })
end

Repository.findByLocationRef = Repository.findActiveByLocation

function Repository:findByBooking(bookingId)
    if not text(bookingId, 160) and tonumber(bookingId) == nil then return invalid('booking ID is invalid') end
    local selectList, errorResult = self._base:_selectList()
    if not selectList then return errorResult end
    local result = self._db:query(('SELECT %s FROM %s WHERE booking_id = ? ORDER BY id ASC'):format(selectList, self._table), { tostring(bookingId) })
    if type(result) ~= 'table' or not result.ok then return result end
    local values = {}
    for index, row in ipairs(result.value or {}) do
        local value, mapResult = self._base:_map(row)
        if not value then return mapResult end
        values[index] = value
    end
    return Result.ok(values)
end

function Repository:create(reservation)
    local row, errorResult = Domain.toRow(reservation)
    if not row then return errorResult end
    return self._base:create(row)
end

function Repository:reserveAtomic(reservation)
    local row, errorResult = Domain.toRow(reservation)
    if not row then return errorResult end
    local result = self:create(reservation)
    if type(result) == 'table' and result.ok then return result end
    if type(result) == 'table' and result.error then
        return Result.err(Codes.RESERVATION_CONFLICT, 'location reservation could not be acquired atomically', {
            locationRef = reservation.locationRef,
            bookingId = reservation.bookingId,
            cause = result.error.code
        })
    end
    return Result.err(Codes.RESERVATION_CONFLICT, 'location reservation could not be acquired atomically')
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('location reservation changes must be a table') end
    local mapped, aliases = {}, {
        status = 'status', holdUntil = 'hold_until', hold_until = 'hold_until',
        activeKey = 'active_key', active_key = 'active_key'
    }
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field then return invalid('location reservation field is not mutable', { field = tostring(key) }) end
        mapped[field] = value
    end
    local terminal = mapped.status and mapped.status ~= 'RESERVED' and mapped.status ~= 'OCCUPIED'
    if terminal then
        local version = tonumber(expectedVersion)
        if not version or version < 1 or version ~= math.floor(version) then return invalid('expected version is invalid') end
        local assignments, parameters = { 'status = ?', 'active_key = NULL' }, { mapped.status }
        if mapped.hold_until ~= nil then
            assignments[#assignments + 1], parameters[#parameters + 1] = 'hold_until = ?', mapped.hold_until
        end
        assignments[#assignments + 1] = 'version = version + 1'
        assignments[#assignments + 1] = 'updated_at = CURRENT_TIMESTAMP(3)'
        parameters[#parameters + 1], parameters[#parameters + 1] = id, version
        local result = self._db:update(('UPDATE %s SET %s WHERE id = ? AND version = ?'):format(self._table, table.concat(assignments, ', ')), parameters)
        if type(result) ~= 'table' or not result.ok then return result end
        local affected = tonumber(result.value and result.value.affectedRows) or 0
        if affected > 0 then return Result.ok({ id = id, version = version + 1, affectedRows = affected }) end
        local exists, existsResult = self._base:_exists(id)
        if exists == nil then return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, 'location reservation existence could not be verified', { cause = existsResult and existsResult.error and existsResult.error.code }) end
        if not exists then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'location reservation was not found', { id = id }) end
        return Result.err(Codes.VERSION_CONFLICT, 'location reservation version does not match', { id = id, expectedVersion = version })
    end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
NightShift.Repositories.LocationReservation = Repository
