NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.Relationship

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'client_profile_id', 'worker_profile_id', 'relationship_type',
    'interaction_count', 'trust_score', 'last_booking_id', 'version',
    'created_at', 'updated_at'
}

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function token(value, maximum)
    return type(value) == 'string' and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil and #value <= (maximum or 160)
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function tableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'relationship repository requires a database adapter') end
    local name = options.tableName or 'nightshift_client_worker_relationships'
    if not tableName(name) then return nil, invalid('relationship repository table name is invalid') end
    local base, errorResult = Base.new({
        db = db, tableName = name, columns = columns,
        mapper = function(row)
            local value, mapError = Domain.fromRow(row)
            if not value then return Result.err(Codes.MAPPING_FAILED, 'relationship row is invalid', { cause = mapError and mapError.error and mapError.error.code }) end
            return value
        end
    })
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = db, _table = name }, Repository)
end

function Repository:findById(id)
    return self._base:findById(id)
end

function Repository:findByPair(clientProfileId, workerProfileId, relationshipType)
    local clientId = integer(clientProfileId, 1, 2147483647)
    local workerId = integer(workerProfileId, 1, 2147483647)
    local kind = type(relationshipType) == 'string' and relationshipType:upper() or 'REGULAR'
    if not clientId or not workerId or not token(kind, 32) then return invalid('relationship lookup values are invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:single(('SELECT %s FROM %s WHERE client_profile_id = ? AND worker_profile_id = ? AND relationship_type = ? LIMIT 1'):format(selectList, self._table), { clientId, workerId, kind })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'relationship was not found') end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:create(value)
    local row, errorResult = Domain.toRow(value)
    if not row then return errorResult end
    return self._base:create(row)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('relationship changes must be a table') end
    local aliases = {
        interactionCount = 'interaction_count', interaction_count = 'interaction_count',
        trustScore = 'trust_score', trust_score = 'trust_score',
        lastBookingId = 'last_booking_id', last_booking_id = 'last_booking_id'
    }
    local mapped, seen = {}, {}
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field or seen[field] then return invalid('relationship field is not mutable', { field = tostring(key) }) end
        seen[field] = true
        if field == 'interaction_count' then
            if not integer(value, 0, 2147483647) then return invalid('relationship interaction count is invalid') end
        elseif field == 'trust_score' then
            if not integer(value, 0, 100) then return invalid('relationship trust score is invalid') end
        elseif value ~= nil and not integer(value, 1, 2147483647) and not token(tostring(value), 160) then
            return invalid('relationship booking ID is invalid')
        end
        mapped[field] = value
    end
    if next(mapped) == nil then return invalid('relationship changes must not be empty') end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
Repository.findByKey = Repository.findByPair
NightShift.Repositories.Relationship = Repository
NightShift.Repositories.Relationships = Repository
