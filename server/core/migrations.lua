NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Logger = NightShift.Logger

local Migrations = NightShift.Migrations or {}
local Runner = {}
Runner.__index = Runner

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function finiteInteger(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge and math.floor(value) == value
end

local function checksum(value)
    value = tostring(value or '')
    local hash = 2166136261
    for index = 1, #value do hash = ((hash ~ string.byte(value, index)) * 16777619) & 0xffffffff end
    return ('%08x'):format(hash)
end

local function invalid(message, details)
    return Result.err(Codes.MIGRATION_INVALID, message, details)
end

local function defaultLoadFile(path)
    local loadResourceFile = rawget(_G, 'LoadResourceFile')
    local getResourceName = rawget(_G, 'GetCurrentResourceName')
    if type(loadResourceFile) ~= 'function' or type(getResourceName) ~= 'function' then return nil end
    local nameOk, resourceName = pcall(getResourceName)
    if not nameOk or not text(resourceName) then return nil end
    local ok, content = pcall(loadResourceFile, resourceName, path)
    return ok and content or nil
end

local function defaultDefinitions()
    local output = {}
    for _, file in ipairs(Migrations.DefinitionFiles or {}) do
        local version, name = file:match('^(%d+)_([%w%-_]+%.sql)$')
        if version then output[#output + 1] = { version = tonumber(version), name = name, file = 'sql/' .. file } end
    end
    return output
end

local function sortedDefinitions(source, loadFile)
    if type(source) ~= 'table' then return nil, invalid('migration definitions must be a table') end
    local output = {}
    local count = 0
    for index, definition in pairs(source) do
        if type(index) ~= 'number' or index < 1 or math.floor(index) ~= index or type(definition) ~= 'table' then
            return nil, invalid('migration definitions must be contiguous')
        end
        count = count + 1
        local item = copy(definition)
        item.version = tonumber(item.version)
        if not finiteInteger(item.version) or item.version < 1 or not text(item.name) then
            return nil, invalid('migration version and name are required', { index = index })
        end
        if not text(item.sql) and text(item.file) then item.sql = loadFile(item.file) end
        if not text(item.sql) then return nil, Result.err(Codes.MIGRATION_SOURCE_UNAVAILABLE, 'migration SQL source is unavailable', { name = item.name }) end
        item.checksum = text(item.checksum) and item.checksum or checksum(item.sql)
        output[#output + 1] = item
    end
    if count == 0 then return output end
    table.sort(output, function(left, right) return left.version < right.version end)
    local expected = 1
    for _, item in ipairs(output) do
        if item.version ~= expected then return nil, invalid('migration versions must be ordered and contiguous', { expected = expected, actual = item.version }) end
        expected = expected + 1
    end
    return output
end

local function missingSchema(result)
    return result and result.error and result.error.code == Codes.DB_SCHEMA_MISSING
end

function Runner.new(options)
    options = options or {}
    local definitions = options.migrations or Migrations.Definitions
    if type(definitions) ~= 'table' or next(definitions) == nil then definitions = defaultDefinitions() end
    return setmetatable({
        _db = options.db,
        _definitions = definitions,
        _loadFile = type(options.loadFile) == 'function' and options.loadFile or defaultLoadFile,
        _logger = options.logger or (Logger and Logger.new()),
        _resourceName = options.resourceName
    }, Runner)
end

function Runner:_definitionsReady()
    return sortedDefinitions(self._definitions, self._loadFile)
end

function Runner:_readApplied()
    local result = self._db:query('SELECT version, name, checksum FROM nightshift_schema_migrations ORDER BY version ASC', {})
    if type(result) == 'table' and result.ok then return result.value or {} end
    if missingSchema(result) then return nil, 'missing' end
    return nil, Result.err(Codes.MIGRATION_DB_UNAVAILABLE, 'migration state could not be read', {
        cause = result.error and result.error.code or Codes.DB_QUERY_FAILED
    })
end

function Runner:_apply(definition)
    local result = self._db:transaction({
        { query = definition.sql, parameters = {} },
        {
            query = 'INSERT INTO nightshift_schema_migrations (version, name, checksum) VALUES (?, ?, ?)',
            parameters = { definition.version, definition.name, definition.checksum }
        }
    })
    if type(result) ~= 'table' or not result.ok then
        return Result.err(Codes.MIGRATION_APPLY_FAILED, 'migration transaction failed', {
            version = definition.version,
            name = definition.name,
            cause = result.error and result.error.code or Codes.DB_TRANSACTION_FAILED
        })
    end
    if self._logger then
        pcall(self._logger.info, self._logger, 'migration', 'Migration applied', {
            version = definition.version,
            name = definition.name,
            checksum = definition.checksum
        })
    end
    return Result.ok({ version = definition.version, name = definition.name })
end

local function indexApplied(rows, definitions)
    if type(rows) ~= 'table' then return nil, invalid('migration state must be an array') end
    local known = {}
    for _, definition in ipairs(definitions) do known[definition.version] = definition end
    local byVersion = {}
    local maxVersion = 0
    local count = 0
    for index, row in pairs(rows) do
        if type(index) ~= 'number' or index < 1 or math.floor(index) ~= index or type(row) ~= 'table' or
            not finiteInteger(tonumber(row.version)) or tonumber(row.version) < 1 or not text(row.name) or not text(row.checksum) then
            return nil, invalid('migration state row is invalid', { index = index })
        end
        count = count + 1
        local version = tonumber(row.version)
        if byVersion[version] then return nil, invalid('migration state contains a duplicate version', { version = version }) end
        local definition = known[version]
        if not definition then return nil, Result.err(Codes.MIGRATION_UNKNOWN, 'database contains an unknown migration', { version = version }) end
        if row.name ~= definition.name then return nil, Result.err(Codes.MIGRATION_NAME_MISMATCH, 'migration name does not match definition', { version = version }) end
        if row.checksum ~= definition.checksum then return nil, Result.err(Codes.MIGRATION_CHECKSUM_MISMATCH, 'migration checksum does not match definition', { version = version }) end
        byVersion[version] = row
        if version > maxVersion then maxVersion = version end
    end
    for version = 1, maxVersion do
        if not byVersion[version] then return nil, Result.err(Codes.MIGRATION_OUT_OF_ORDER, 'migration history contains a version gap', { version = version }) end
    end
    return byVersion, maxVersion
end

function Runner:run()
    if type(self._db) ~= 'table' or type(self._db.healthCheck) ~= 'function' then
        return Result.err(Codes.MIGRATION_DB_UNAVAILABLE, 'migration runner requires a database adapter')
    end
    local health = self._db:healthCheck()
    if type(health) ~= 'table' or not health.ok then
        return Result.err(Codes.MIGRATION_DB_UNAVAILABLE, 'database health check failed', {
            cause = type(health) == 'table' and health.error and health.error.code or Codes.DB_HEALTHCHECK_FAILED
        })
    end
    local definitions, definitionError = self:_definitionsReady()
    if not definitions then return definitionError end
    if #definitions == 0 then return invalid('at least one migration is required') end
    local appliedNames = {}
    local rows, readError = self:_readApplied()
    if readError == 'missing' then
        local first = self:_apply(definitions[1])
        if not first.ok then return first end
        appliedNames[#appliedNames + 1] = definitions[1].name
        rows, readError = self:_readApplied()
    end
    if not rows then
        if readError == 'missing' then return Result.err(Codes.MIGRATION_DB_UNAVAILABLE, 'migration state table could not be created') end
        return readError
    end
    local applied, maxVersionOrError = indexApplied(rows, definitions)
    if not applied then return maxVersionOrError end
    for _, definition in ipairs(definitions) do
        if not applied[definition.version] then
            local result = self:_apply(definition)
            if not result.ok then return result end
            applied[definition.version] = { version = definition.version, name = definition.name, checksum = definition.checksum }
            appliedNames[#appliedNames + 1] = definition.name
        end
    end
    local currentVersion = #definitions > 0 and definitions[#definitions].version or 0
    return Result.ok({ currentVersion = currentVersion, applied = appliedNames, count = #appliedNames })
end

Migrations.DefinitionFiles = Migrations.DefinitionFiles or {
    '001_schema_version.sql',
    '002_profiles.sql',
    '003_bookings.sql',
    '004_booking_events.sql',
    '005_npc_profiles.sql',
    '006_locations.sql',
    '007_payments.sql',
    '008_relationships.sql',
    '009_indexes.sql',
    '010_identity_profiles.sql'
}
Migrations.checksum = checksum
Migrations.Runner = Runner
Migrations.new = Runner.new
NightShift.Migrations = Migrations
