local function check(value, message) assert(value, message) end

local function newDatabase(initialRows, missingSchema)
    local db = { rows = initialRows or {}, missingSchema = missingSchema, transactions = {}, healthChecks = 0 }
    function db:healthCheck()
        self.healthChecks = self.healthChecks + 1
        return NightShift.Result.ok({ healthy = true })
    end
    function db:query(sql)
        if sql:match('SELECT version') then
            if self.missingSchema then return NightShift.Result.err('DB_SCHEMA_MISSING', 'schema table missing') end
            return NightShift.Result.ok(self.rows)
        end
        return NightShift.Result.err('DB_QUERY_FAILED', 'unexpected query')
    end
    function db:transaction(statements)
        self.transactions[#self.transactions + 1] = statements
        self.missingSchema = false
        local marker = statements[2] and statements[2].parameters or {}
        self.rows[#self.rows + 1] = {
            version = marker.version or marker[1],
            name = marker.name or marker[2],
            checksum = marker.checksum or marker[3]
        }
        return NightShift.Result.ok({ committed = true })
    end
    return db
end

local definitions = {
    { version = 1, name = '001_init.sql', sql = 'CREATE TABLE schema_version (version INT)' },
    { version = 2, name = '002_extra.sql', sql = 'CREATE TABLE extra (id INT)' }
}

do
    local entries = {}
    local db = newDatabase({}, true)
    local runner = NightShift.Migrations.Runner.new({
        db = db,
        migrations = definitions,
        logger = NightShift.Logger.new({ sink = function(entry) entries[#entries + 1] = entry end })
    })
    local result = runner:run()
    check(result.ok and result.value.currentVersion == 2 and #result.value.applied == 2, 'fresh install must apply ordered migrations')
    check(#db.transactions == 2 and db.transactions[1][1].query == definitions[1].sql and db.transactions[2][1].query == definitions[2].sql, 'migration SQL must run in order')
    check(#entries == 2, 'applied migrations must be logged')
    local repeatResult = runner:run()
    check(repeatResult.ok and repeatResult.value.currentVersion == 2 and #repeatResult.value.applied == 0, 'repeat boot must be idempotent')
end

do
    local db = newDatabase({ { version = 2, name = definitions[2].name, checksum = NightShift.Migrations.checksum(definitions[2].sql) } })
    local result = NightShift.Migrations.Runner.new({ db = db, migrations = definitions }):run()
    check(not result.ok and result.error.code == 'MIGRATION_OUT_OF_ORDER', 'out-of-order applied version must fail')
end

do
    local db = newDatabase({ { version = 1, name = definitions[1].name, checksum = 'wrong' } })
    local result = NightShift.Migrations.Runner.new({ db = db, migrations = definitions }):run()
    check(not result.ok and result.error.code == 'MIGRATION_CHECKSUM_MISMATCH', 'checksum drift must fail closed')
end

do
    local db = newDatabase({}, false)
    function db:healthCheck() return NightShift.Result.err('DB_HEALTHCHECK_FAILED', 'offline') end
    local result = NightShift.Migrations.Runner.new({ db = db, migrations = definitions }):run()
    check(not result.ok and result.error.code == 'MIGRATION_DB_UNAVAILABLE', 'database health failure must block migrations')
end

do
    local config = NightShift.Validators.copy(NightShift.DefaultConfig)
    config.features.persistence = true
    local runner = { run = function() return NightShift.Result.ok({ currentVersion = 1, applied = {} }) end }
    local adapter = { healthCheck = function() return NightShift.Result.ok({ healthy = true }) end }
    local ok, result = NightShift.Server.bootstrap({
        config = config,
        databaseAdapter = adapter,
        migrationRunner = runner
    })
    check(ok and result.db.database == adapter and result.db.migrations.value.currentVersion == 1, 'persistence-enabled bootstrap must run database stage')

    local noAdapterOk, noAdapterError = NightShift.Server.bootstrap({ config = config })
    check(not noAdapterOk and noAdapterError.code == 'DB_UNAVAILABLE' and noAdapterError.stage == 'db', 'persistence-enabled startup must fail without a database')
end

do
    check(NightShift.Migrations.checksum('abc') == NightShift.Migrations.checksum('abc'), 'migration checksum must be deterministic')
    check(NightShift.Migrations.checksum('abc') ~= NightShift.Migrations.checksum('abd'), 'migration checksum must detect content changes')
end

do
    local db = newDatabase({}, true)
    local runner = NightShift.Migrations.Runner.new({
        db = db,
        loadFile = function(path)
            local handle = assert(io.open(path, 'r'))
            local content = handle:read('*a')
            handle:close()
            return content
        end
    })
    local result = runner:run()
    check(result.ok and result.value.currentVersion == 9 and #result.value.applied == 9, 'registered SQL migrations must run from default definitions')
end
