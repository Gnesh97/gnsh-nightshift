local function check(value, message) assert(value, message) end

do
    local calls = {}
    local driver = {
        query = function(_, sql, params) calls[#calls + 1] = { operation = 'query', sql = sql, params = params }; return { { id = 1 } } end,
        single = function() return { id = 1 } end,
        scalar = function() return 1 end,
        insert = function() return 42 end,
        update = function() return 3 end,
        transaction = function(_, statements) return { committed = true, count = #statements } end
    }
    local db = NightShift.Database.new({ driver = driver })
    local rows = db:query('SELECT * FROM test WHERE id = ?', { 1 })
    check(rows.ok and rows.value[1].id == 1, 'query must return structured rows')
    check(calls[1].params[1] == 1, 'query parameters must remain separate from SQL')
    check(db:single('SELECT 1').value.id == 1, 'single must return one row')
    check(db:scalar('SELECT 1').value == 1, 'scalar must return scalar value')
    check(db:insert('INSERT INTO test (id) VALUES (?)', { 1 }).value.insertId == 42, 'insert must normalize insert ID')
    check(db:update('UPDATE test SET id = ?', { 2 }).value.affectedRows == 3, 'update must normalize affected rows')
    check(db:transaction({ { query = 'SELECT 1', parameters = {} } }).ok, 'transaction must return committed result')
    check(db:healthCheck().ok, 'health check must use adapter contract')
end

do
    local db = NightShift.Database.new({ driver = {
        query = function() error('connection refused') end,
        transaction = function() error('rollback') end
    } })
    local query = db:query('SELECT 1')
    check(not query.ok and query.error.code == 'DB_QUERY_FAILED', 'driver query failure must be typed')
    local transaction = db:transaction({ { query = 'SELECT 1', parameters = {} } })
    check(not transaction.ok and transaction.error.code == 'DB_TRANSACTION_FAILED', 'transaction rollback must be typed')
    local health = db:healthCheck()
    check(not health.ok and health.error.code == 'DB_HEALTHCHECK_FAILED', 'health failure must be typed')
end

do
    local db = NightShift.Database.new({ driver = {} })
    check(not db:query('SELECT 1').ok, 'missing driver method must fail')
    check(db:query('SELECT 1').error.code == 'DB_UNAVAILABLE', 'missing driver must be unavailable')
    check(db:query('', {}).error.code == 'DB_INVALID_ARGUMENT', 'empty SQL must fail validation')
    check(db:query('SELECT 1', 'unsafe').error.code == 'DB_INVALID_ARGUMENT', 'non-table parameters must fail validation')
end

do
    local observed
    local adapter = NightShift.Database.OxMySQL.new({
        executor = function(operation, sql, params)
            observed = { operation = operation, sql = sql, params = params }
            return 7
        end
    })
    local db = NightShift.Database.new({ driver = adapter })
    local result = db:insert('INSERT INTO test (id) VALUES (?)', { 7 })
    check(result.ok and result.value.insertId == 7 and observed.operation == 'insert', 'oxmysql adapter must delegate normalized operations')
end
