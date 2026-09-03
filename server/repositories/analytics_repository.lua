NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Repository = {}
Repository.__index = Repository

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
    if not value or value ~= value or value == math.huge or value == -math.huge
        or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil
        and #value <= (maxLength or 160)
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function databaseTimestamp(value, field)
    if value == nil then return nil end
    if type(value) == 'number' then
        if not integer(value, 0) then return nil, invalid(field .. ' timestamp is invalid') end
        local ok, formatted = pcall(os.date, '!%Y-%m-%d %H:%M:%S', value)
        if not ok or type(formatted) ~= 'string' then return nil, invalid(field .. ' timestamp is invalid') end
        return formatted .. '.000'
    end
    if type(value) ~= 'string' or not text(value, 80) then
        return nil, invalid(field .. ' timestamp is invalid')
    end
    local date, clock, fraction = value:match('^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d:%d%d:%d%d)%.?(%d*)Z?$')
    if not date then return nil, invalid(field .. ' timestamp is invalid') end
    fraction = (fraction or '') .. '000'
    return date .. ' ' .. clock .. '.' .. fraction:sub(1, 3)
end

local function range(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('analytics query options must be a table') end
    local from, fromError = databaseTimestamp(options.from or options.since, 'analytics from')
    if fromError then return nil, fromError end
    local untilValue, untilError = databaseTimestamp(options['until'] or options.to, 'analytics until')
    if untilError then return nil, untilError end
    if from and untilValue and from >= untilValue then return nil, invalid('analytics time range is invalid') end
    return { from = from, ['until'] = untilValue }
end

local function boundedRows(result, field)
    if type(result) ~= 'table' or not result.ok then return result end
    if type(result.value) ~= 'table' then
        return Result.err(Codes.REPOSITORY_STATE_UNKNOWN, field .. ' analytics rows are invalid')
    end
    local output = {}
    for index, row in ipairs(result.value) do
        if type(row) ~= 'table' then return Result.err(Codes.MAPPING_FAILED, field .. ' analytics row is invalid') end
        output[index] = {
        mode = text(row.mode, 32) and row.mode:upper() or nil,
        status = text(row.status, 32) and row.status:upper() or nil,
        district = text(row.district or row.district_id, 64)
            and (row.district or row.district_id):lower() or nil,
        eventType = text(row.eventType or row.event_type, 64) and (row.eventType or row.event_type):upper() or nil,
            count = integer(row.count or row.total or row.events, 0) or 0,
            amountMinor = integer(row.amountMinor or row.amount_minor, 0),
            averageAmountMinor = tonumber(row.averageAmountMinor or row.average_amount_minor or row.average_price)
        }
    end
    return Result.ok(output)
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then
        return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'analytics repository requires a database adapter')
    end
    local tableName = options.tableName or 'nightshift_booking_events'
    if type(tableName) ~= 'string' or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then
        return nil, invalid('analytics repository table name is invalid')
    end
    return setmetatable({ _db = database, _table = tableName }, Repository)
end

function Repository:_query(sql, parameters, field)
    if type(self._db.query) ~= 'function' then
        return Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'analytics database query capability is unavailable')
    end
    local result = self._db:query(sql, parameters or {})
    return boundedRows(result, field)
end

function Repository:bookingSummary(options)
    local settings, errorResult = range(options)
    if not settings then return errorResult end
    local where, parameters = {}, {}
    if settings.from then where[#where + 1] = 'created_at >= ?'; parameters[#parameters + 1] = settings.from end
    if settings['until'] then where[#where + 1] = 'created_at < ?'; parameters[#parameters + 1] = settings['until'] end
    local suffix = #where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or ''
    return self:_query(('SELECT mode, status, COUNT(*) AS count, AVG(COALESCE(agreed_price_minor, price_minor)) AS average_price FROM nightshift_bookings%s GROUP BY mode, status'):format(suffix), parameters, 'booking')
end

function Repository:settlementSummary(options)
    local settings, errorResult = range(options)
    if not settings then return errorResult end
    local where, parameters = {}, {}
    if settings.from then where[#where + 1] = 'created_at >= ?'; parameters[#parameters + 1] = settings.from end
    if settings['until'] then where[#where + 1] = 'created_at < ?'; parameters[#parameters + 1] = settings['until'] end
    local suffix = #where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or ''
    return self:_query(('SELECT status, COUNT(*) AS count, SUM(amount_minor) AS amount_minor FROM nightshift_payments%s GROUP BY status'):format(suffix), parameters, 'settlement')
end

function Repository:travelFailureSummary(options)
    local settings, errorResult = range(options)
    if not settings then return errorResult end
    local where, parameters = { "(event_type LIKE '%TRAVEL%' OR event_type LIKE '%ARRIVAL%')" }, {}
    if settings.from then where[#where + 1] = 'occurred_at >= ?'; parameters[#parameters + 1] = settings.from end
    if settings['until'] then where[#where + 1] = 'occurred_at < ?'; parameters[#parameters + 1] = settings['until'] end
    local sql = ('SELECT event_type, COUNT(*) AS count FROM %s WHERE %s GROUP BY event_type'):format(self._table, table.concat(where, ' AND '))
    return self:_query(sql, parameters, 'travel')
end

function Repository:demandSummary(options)
    local settings, errorResult = range(options)
    if not settings then return errorResult end
    local where, parameters = {
        "(event_type LIKE '%DEMAND%' OR event_type LIKE '%OPPORTUNITY%')"
    }, {}
    if settings.from then where[#where + 1] = 'occurred_at >= ?'; parameters[#parameters + 1] = settings.from end
    if settings['until'] then where[#where + 1] = 'occurred_at < ?'; parameters[#parameters + 1] = settings['until'] end
    -- District is emitted by the server-owned demand/event payload. JSON_EXTRACT
    -- keeps the query bounded and avoids loading the full event history into Lua.
    local sql = ([[SELECT
        LOWER(JSON_UNQUOTE(JSON_EXTRACT(COALESCE(metadata_json, payload), '$.district'))) AS district,
        COUNT(*) AS count
        FROM %s
        WHERE %s
        GROUP BY district
        ORDER BY count DESC
        LIMIT 100]]):format(self._table, table.concat(where, ' AND '))
    return self:_query(sql, parameters, 'demand')
end

Repository.bookings = Repository.bookingSummary
Repository.settlements = Repository.settlementSummary
Repository.travelFailures = Repository.travelFailureSummary
Repository.demandByDistrict = Repository.demandSummary
NightShift.Repositories.Analytics = Repository
