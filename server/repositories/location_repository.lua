NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.Location

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'location_key', 'location_type', 'category', 'provider',
    'coordinates_json', 'world_target_json', 'access_requirements_json',
    'meeting_modes_json', 'max_travel_distance', 'blocked_tags_json',
    'available', 'reservable', 'version', 'created_at', 'updated_at'
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

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function codec(options, direction, value)
    if value == nil then return nil end
    local fn = options and options[direction]
    if type(fn) == 'function' then
        local ok, result = pcall(fn, value)
        if not ok then return nil end
        return result
    end
    if direction == 'encode' then
        local json = rawget(_G, 'json')
        if type(json) == 'table' and type(json.encode) == 'function' then
            local ok, result = pcall(json.encode, value)
            if ok then return result end
        end
    else
        if type(value) == 'table' then return copy(value) end
        local json = rawget(_G, 'json')
        if type(json) == 'table' and type(json.decode) == 'function' then
            local ok, result = pcall(json.decode, value)
            if ok then return result end
        end
    end
    return value
end

local function mapRow(row, options)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'location row is invalid') end
    local source = copy(row)
    for field, aliases in pairs({
        worldTarget = { 'world_target_json', 'world_target', 'coordinates_json', 'coordinates' },
        accessRequirements = { 'access_requirements_json', 'access_requirements' },
        meetingModes = { 'meeting_modes_json', 'meeting_modes' },
        blockedTags = { 'blocked_tags_json', 'blocked_tags' }
    }) do
        for _, key in ipairs(aliases) do
            if source[field] == nil and source[key] ~= nil then
                source[field] = codec(options, 'decode', source[key])
                break
            end
        end
    end
    local location, errorResult = Domain.fromRow(source)
    if not location then return nil, Result.err(Codes.MAPPING_FAILED, 'location row mapping failed', { cause = errorResult and errorResult.error and errorResult.error.code }) end
    return location
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'location repository requires a database adapter') end
    local tableName = options.tableName or 'nightshift_locations'
    if not text(tableName, 64) or tableName:match('^[A-Za-z_][A-Za-z0-9_]*$') == nil then return nil, invalid('location repository table name is invalid') end
    local settings = { db = database, tableName = tableName, columns = columns }
    local optionsCopy = copy(options)
    settings.mapper = function(row) return mapRow(row, optionsCopy) end
    local base, errorResult = Base.new(settings)
    if not base then return nil, errorResult end
    return setmetatable({ _base = base, _db = database, _table = tableName, _options = optionsCopy }, Repository)
end

function Repository:findById(id)
    return self._base:findById(id)
end

function Repository:findByRef(locationRef)
    if not text(locationRef, 160) then return invalid('location reference is invalid') end
    local selectList, errorResult = self._base:_selectList()
    if not selectList then return errorResult end
    local result = self._db:single(('SELECT %s FROM %s WHERE location_key = ? LIMIT 1'):format(selectList, self._table), { locationRef })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'location was not found', { locationRef = locationRef }) end
    local mapped, mapResult = self._base:_map(result.value)
    if not mapped then return mapResult end
    return Result.ok(mapped, { locationRef = locationRef })
end

Repository.findByKey = Repository.findByRef
Repository.findByLocationRef = Repository.findByRef

function Repository:findAvailable(options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('location availability options are invalid') end
    local selectList, errorResult = self._base:_selectList()
    if not selectList then return errorResult end
    local parameters = {}
    local where = { 'available = 1' }
    if options.locationType ~= nil then
        if not text(options.locationType, 32) then return invalid('location type is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'location_type = ?', tostring(options.locationType):upper()
    end
    parameters[#parameters + 1] = options.limit or 100
    local result = self._db:query(('SELECT %s FROM %s WHERE %s ORDER BY id ASC LIMIT ?'):format(selectList, self._table, table.concat(where, ' AND ')), parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local values = {}
    for index, row in ipairs(result.value or {}) do
        local mapped, mapResult = self._base:_map(row)
        if not mapped then return mapResult end
        values[index] = mapped
    end
    return Result.ok(values)
end

function Repository:create(location)
    local row, errorResult = Domain.toRow(location)
    if not row then return errorResult end
    local encoded = {
        location_key = row.location_key,
        location_type = row.location_type,
        category = row.category,
        provider = row.provider,
        world_target_json = codec(self._options, 'encode', row.world_target),
        access_requirements_json = codec(self._options, 'encode', row.access_requirements),
        meeting_modes_json = codec(self._options, 'encode', row.meeting_modes),
        max_travel_distance = row.max_travel_distance,
        blocked_tags_json = codec(self._options, 'encode', row.blocked_tags),
        available = row.available,
        reservable = row.reservable
    }
    return self._base:create(encoded)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('location changes must be a table') end
    local mapped = {}
    local aliases = {
        locationRef = 'location_key', location_ref = 'location_key',
        locationType = 'location_type', location_type = 'location_type',
        worldTarget = 'world_target_json', world_target = 'world_target_json',
        accessRequirements = 'access_requirements_json', access_requirements = 'access_requirements_json',
        meetingModes = 'meeting_modes_json', meeting_modes = 'meeting_modes_json',
        maxTravelDistance = 'max_travel_distance', max_travel_distance = 'max_travel_distance',
        blockedTags = 'blocked_tags_json', blocked_tags = 'blocked_tags_json',
        available = 'available', reservable = 'reservable', provider = 'provider', category = 'category'
    }
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field then return invalid('location field is not mutable', { field = tostring(key) }) end
        if field:find('_json', 1, true) then value = codec(self._options, 'encode', value) end
        mapped[field] = value
    end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
NightShift.Repositories.Location = Repository
