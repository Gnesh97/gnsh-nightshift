NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'booking_id', 'client_profile_id', 'worker_profile_id', 'rating',
    'review_text', 'version', 'created_at', 'updated_at'
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

local function identifier(value)
    if type(value) == 'number' then
        return value >= 1 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge
    end
    return type(value) == 'string' and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil and #value <= 160
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function text(value, maximum)
    return value == nil or (type(value) == 'string' and #value <= (maximum or 2000) and value:find('%z') == nil)
end

local function tableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function mapRow(row)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'review row is not a table') end
    local bookingId = row.booking_id or row.bookingId
    local clientId = integer(row.client_profile_id or row.clientProfileId, 1, 2147483647)
    local workerId = integer(row.worker_profile_id or row.workerProfileId, 1, 2147483647)
    local rating = integer(row.rating, 1, 5)
    if not identifier(bookingId) or not clientId or not workerId or not rating or not text(row.review_text or row.reviewText, 2000) then
        return nil, Result.err(Codes.MAPPING_FAILED, 'review row is invalid')
    end
    return {
        id = row.id,
        bookingId = bookingId,
        clientProfileId = clientId,
        workerProfileId = workerId,
        rating = rating,
        reviewText = row.review_text or row.reviewText,
        version = integer(row.version, 1, 2147483647) or 1,
        createdAt = row.created_at or row.createdAt,
        updatedAt = row.updated_at or row.updatedAt
    }
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'review repository requires a database adapter') end
    local name = options.tableName or 'nightshift_reviews'
    if not tableName(name) then return nil, invalid('review repository table name is invalid') end
    local base, errorResult = Base.new({ db = db, tableName = name, columns = columns, mapper = mapRow })
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = db, _table = name }, Repository)
end

function Repository:_findBy(field, value)
    if not identifier(value) then return invalid('review lookup identifier is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:single(('SELECT %s FROM %s WHERE %s = ? LIMIT 1'):format(selectList, self._table, field), { value })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'review was not found', { [field] = value }) end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:findById(id)
    return self:_findBy('id', id)
end

function Repository:findByBooking(bookingId)
    return self:_findBy('booking_id', bookingId)
end

function Repository:create(value)
    if type(value) ~= 'table' then return invalid('review must be a table') end
    local bookingId = value.bookingId or value.booking_id
    local clientId = integer(value.clientProfileId or value.client_profile_id, 1, 2147483647)
    local workerId = integer(value.workerProfileId or value.worker_profile_id, 1, 2147483647)
    local rating = integer(value.rating, 1, 5)
    if not identifier(bookingId) or not clientId or not workerId or not rating then return invalid('review identifiers or rating are invalid') end
    local reviewText = value.reviewText or value.review_text
    if not text(reviewText, 2000) then return invalid('review text is invalid') end
    return self._base:create({
        booking_id = bookingId,
        client_profile_id = clientId,
        worker_profile_id = workerId,
        rating = rating,
        review_text = reviewText
    })
end

function Repository:findByClient(clientProfileId, options)
    return self:_findMany('client_profile_id', clientProfileId, options)
end

function Repository:findByWorker(workerProfileId, options)
    return self:_findMany('worker_profile_id', workerProfileId, options)
end

function Repository:_findMany(field, value, options)
    local profileId = integer(value, 1, 2147483647)
    if not profileId then return invalid('review profile ID is invalid') end
    options = options or {}
    local limit = integer(options.limit or 50, 1, 1000)
    local offset = integer(options.offset or 0, 0)
    if not limit or not offset then return invalid('review pagination is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:query(('SELECT %s FROM %s WHERE %s = ? ORDER BY id DESC LIMIT ? OFFSET ?'):format(selectList, self._table, field), { profileId, limit, offset })
    if type(result) ~= 'table' or not result.ok then return result end
    local output = {}
    for index, row in ipairs(result.value or {}) do
        local mapped, mapError = self._base:_map(row)
        if not mapped then return mapError end
        output[index] = mapped
    end
    return Result.ok(output, { limit = limit, offset = offset })
end

Repository.findByKey = Repository.findByBooking
NightShift.Repositories.Review = Repository
NightShift.Repositories.Reviews = Repository
