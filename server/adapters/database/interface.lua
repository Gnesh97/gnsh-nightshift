NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Database = {}
Database.__index = Database

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function validSql(sql)
    return type(sql) == 'string' and sql:match('%S') ~= nil
end

local function validParameters(parameters)
    return parameters == nil or type(parameters) == 'table'
end

local function invalid(operation, message)
    return Result.err(Codes.DB_INVALID_ARGUMENT, message, { operation = operation })
end

local function isMissingSchema(message)
    message = tostring(message or ''):lower()
    return message:find("doesn't exist", 1, true) ~= nil or message:find('no such table', 1, true) ~= nil or
        message:find('table not found', 1, true) ~= nil
end

local function invoke(driver, operation, ...)
    local method = driver and driver[operation]
    if type(method) ~= 'function' then
        return nil, Result.err(Codes.DB_UNAVAILABLE, ('Database operation "%s" is unavailable'):format(operation), {
            operation = operation
        })
    end
    local ok, value, driverError = pcall(method, driver, ...)
    if not ok or driverError ~= nil then
        local code
        if operation == 'transaction' then
            code = Codes.DB_TRANSACTION_FAILED
        elseif isMissingSchema(driverError or value) then
            code = Codes.DB_SCHEMA_MISSING
        else
            code = Codes.DB_QUERY_FAILED
        end
        return nil, Result.err(code, ('Database %s failed'):format(operation), { operation = operation })
    end
    return value
end

local function normalizeInsert(value)
    if type(value) == 'table' then
        local output = copy(value)
        if output.insertId == nil and output.insert_id ~= nil then output.insertId = output.insert_id end
        return output
    end
    return { insertId = value }
end

local function normalizeUpdate(value)
    if type(value) == 'table' then
        local affected = value.affectedRows
        if affected == nil then affected = value.affected end
        if affected == nil then affected = value.affected_rows end
        return { affectedRows = tonumber(affected) or 0 }
    end
    return { affectedRows = tonumber(value) or 0 }
end

local function validateStatements(statements)
    if type(statements) ~= 'table' then return false end
    local count = 0
    for key, statement in pairs(statements) do
        if type(key) ~= 'number' or key < 1 or math.floor(key) ~= key or type(statement) ~= 'table' then
            return false
        end
        count = count + 1
    end
    for index = 1, count do
        local statement = rawget(statements, index)
        local query = type(statement) == 'table' and rawget(statement, 'query') or nil
        if query == nil and type(statement) == 'table' then query = rawget(statement, 'sql') end
        local parameters = type(statement) == 'table' and rawget(statement, 'parameters') or nil
        if parameters == nil and type(statement) == 'table' then parameters = rawget(statement, 'params') end
        if type(statement) ~= 'table' or not validSql(query) or not validParameters(parameters) then
            return false
        end
    end
    return count > 0
end

function Database.new(options)
    options = options or {}
    return setmetatable({
        _driver = options.driver,
        _logger = options.logger
    }, Database)
end

function Database.wrap(driver, options)
    options = options or {}
    local normalized = {}
    for key, value in pairs(options) do normalized[key] = value end
    normalized.driver = driver
    return Database.new(normalized)
end

function Database:isAvailable()
    return type(self._driver) == 'table'
end

function Database:query(sql, parameters)
    if not validSql(sql) or not validParameters(parameters) then
        return invalid('query', 'query requires non-empty SQL and table parameters')
    end
    local value, err = invoke(self._driver, 'query', sql, parameters or {})
    if err then return err end
    return Result.ok(type(value) == 'table' and copy(value) or {}, { operation = 'query' })
end

function Database:single(sql, parameters)
    if not validSql(sql) or not validParameters(parameters) then
        return invalid('single', 'single requires non-empty SQL and table parameters')
    end
    local value, err = invoke(self._driver, 'single', sql, parameters or {})
    if err then return err end
    return Result.ok(copy(value), { operation = 'single' })
end

function Database:scalar(sql, parameters)
    if not validSql(sql) or not validParameters(parameters) then
        return invalid('scalar', 'scalar requires non-empty SQL and table parameters')
    end
    local value, err = invoke(self._driver, 'scalar', sql, parameters or {})
    if err then return err end
    return Result.ok(value, { operation = 'scalar' })
end

function Database:insert(sql, parameters)
    if not validSql(sql) or not validParameters(parameters) then
        return invalid('insert', 'insert requires non-empty SQL and table parameters')
    end
    local value, err = invoke(self._driver, 'insert', sql, parameters or {})
    if err then return err end
    return Result.ok(normalizeInsert(value), { operation = 'insert' })
end

function Database:update(sql, parameters)
    if not validSql(sql) or not validParameters(parameters) then
        return invalid('update', 'update requires non-empty SQL and table parameters')
    end
    local value, err = invoke(self._driver, 'update', sql, parameters or {})
    if err then return err end
    return Result.ok(normalizeUpdate(value), { operation = 'update' })
end

function Database:transaction(statements)
    if not validateStatements(statements) then
        return invalid('transaction', 'transaction requires contiguous parameterized statements')
    end
    local normalized = {}
    for index, statement in ipairs(statements) do
        local query = rawget(statement, 'query')
        if query == nil then query = rawget(statement, 'sql') end
        local parameters = rawget(statement, 'parameters')
        if parameters == nil then parameters = rawget(statement, 'params') end
        normalized[index] = {
            query = query,
            parameters = copy(parameters or {})
        }
    end
    local value, err = invoke(self._driver, 'transaction', normalized)
    if err then return err end
    if value == false then
        return Result.err(Codes.DB_TRANSACTION_FAILED, 'Database transaction was rolled back', { operation = 'transaction' })
    end
    return Result.ok({ committed = true, results = copy(value) }, { operation = 'transaction' })
end

function Database:healthCheck()
    local result = self:scalar('SELECT 1 AS health', {})
    if not result.ok or result.value == nil or (result.value ~= true and result.value ~= 1 and result.value ~= '1') then
        return Result.err(Codes.DB_HEALTHCHECK_FAILED, 'Database health check failed', {
            cause = result.error and result.error.code or Codes.DB_QUERY_FAILED
        })
    end
    return Result.ok({ healthy = true, value = result.value })
end

NightShift.Database = Database
NightShift.DatabaseInterface = Database
