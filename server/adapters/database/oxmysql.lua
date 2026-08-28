NightShift = NightShift or {}

local OxMySQL = {}
OxMySQL.__index = OxMySQL

local function defaultExecutor()
    local mysql = rawget(_G, 'MySQL')
    if type(mysql) == 'table' then
        return function(operation, sql, parameters)
            local target = mysql[operation]
            if type(target) == 'table' and type(target.await) == 'function' then
                return target.await(sql, parameters)
            end
            if type(target) == 'function' then return target(sql, parameters) end
            error('MySQL operation unavailable')
        end
    end

    local exports = rawget(_G, 'exports')
    local oxmysql
    if exports ~= nil then
        local ok, value = pcall(function() return exports.oxmysql end)
        if ok then oxmysql = value end
    end
    if oxmysql ~= nil then
        return function(operation, sql, parameters)
            local names = { operation .. '_async', operation }
            for _, name in ipairs(names) do
                local target = oxmysql[name]
                if type(target) == 'function' then return target(oxmysql, sql, parameters) end
            end
            error('oxmysql export unavailable')
        end
    end

    return function() error('oxmysql is not configured') end
end

function OxMySQL.new(options)
    options = options or {}
    return setmetatable({
        _executor = type(options.executor) == 'function' and options.executor or defaultExecutor()
    }, OxMySQL)
end

function OxMySQL:_execute(operation, sql, parameters)
    return self._executor(operation, sql, parameters)
end

function OxMySQL:query(sql, parameters) return self:_execute('query', sql, parameters) end
function OxMySQL:single(sql, parameters) return self:_execute('single', sql, parameters) end
function OxMySQL:scalar(sql, parameters) return self:_execute('scalar', sql, parameters) end
function OxMySQL:insert(sql, parameters) return self:_execute('insert', sql, parameters) end
function OxMySQL:update(sql, parameters) return self:_execute('update', sql, parameters) end
function OxMySQL:transaction(statements) return self:_execute('transaction', statements) end

NightShift.Database = NightShift.Database or {}
NightShift.Database.OxMySQL = OxMySQL
