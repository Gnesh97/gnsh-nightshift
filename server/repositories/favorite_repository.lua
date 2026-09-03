NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base

local Repository = {}
Repository.__index = Repository

local columns = { 'id', 'client_profile_id', 'worker_profile_id', 'version', 'created_at', 'updated_at' }

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
    if not value or value ~= math.floor(value) or value == math.huge or value == -math.huge then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function tableName(value)
    return type(value) == 'string' and value:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function mapRow(row)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'favorite row is not a table') end
    local clientId = integer(row.client_profile_id or row.clientProfileId, 1, 2147483647)
    local workerId = integer(row.worker_profile_id or row.workerProfileId, 1, 2147483647)
    if not clientId or not workerId then return nil, Result.err(Codes.MAPPING_FAILED, 'favorite row is invalid') end
    return {
        id = row.id,
        clientProfileId = clientId,
        workerProfileId = workerId,
        version = integer(row.version, 1, 2147483647) or 1,
        createdAt = row.created_at or row.createdAt,
        updatedAt = row.updated_at or row.updatedAt
    }
end

function Repository.new(options)
    options = options or {}
    local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'favorite repository requires a database adapter') end
    local name = options.tableName or 'nightshift_favorites'
    if not tableName(name) then return nil, invalid('favorite repository table name is invalid') end
    local base, errorResult = Base.new({ db = db, tableName = name, columns = columns, mapper = mapRow })
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = db, _table = name }, Repository)
end

function Repository:findById(id)
    local normalized = integer(id, 1, 2147483647)
    if not normalized then return invalid('favorite ID is invalid') end
    return self._base:findById(normalized)
end

function Repository:findByPair(clientProfileId, workerProfileId)
    local clientId = integer(clientProfileId, 1, 2147483647)
    local workerId = integer(workerProfileId, 1, 2147483647)
    if not clientId or not workerId then return invalid('favorite profile IDs are invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:single(('SELECT %s FROM %s WHERE client_profile_id = ? AND worker_profile_id = ? LIMIT 1'):format(selectList, self._table), { clientId, workerId })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'favorite was not found') end
    local mapped, mapError = self._base:_map(result.value)
    if not mapped then return mapError end
    return Result.ok(mapped)
end

function Repository:create(value)
    if type(value) ~= 'table' then return invalid('favorite must be a table') end
    local clientId = integer(value.clientProfileId or value.client_profile_id, 1, 2147483647)
    local workerId = integer(value.workerProfileId or value.worker_profile_id, 1, 2147483647)
    if not clientId or not workerId then return invalid('favorite profile IDs are invalid') end
    return self._base:create({ client_profile_id = clientId, worker_profile_id = workerId })
end

function Repository:deleteExpectedVersion(id, expectedVersion)
    return self._base:deleteExpectedVersion(id, expectedVersion)
end

function Repository:findByClient(clientProfileId, options)
    local clientId = integer(clientProfileId, 1, 2147483647)
    if not clientId then return invalid('favorite client profile ID is invalid') end
    options = options or {}
    local limit = integer(options.limit or 50, 1, 1000)
    local offset = integer(options.offset or 0, 0)
    if not limit or not offset then return invalid('favorite pagination is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local result = self._db:query(('SELECT %s FROM %s WHERE client_profile_id = ? ORDER BY id DESC LIMIT ? OFFSET ?'):format(selectList, self._table), { clientId, limit, offset })
    if type(result) ~= 'table' or not result.ok then return result end
    local output = {}
    for index, row in ipairs(result.value or {}) do
        local mapped, mapError = self._base:_map(row)
        if not mapped then return mapError end
        output[index] = mapped
    end
    return Result.ok(output, { limit = limit, offset = offset })
end

Repository.findByKey = Repository.findByPair
NightShift.Repositories.Favorite = Repository
NightShift.Repositories.Favorites = Repository
