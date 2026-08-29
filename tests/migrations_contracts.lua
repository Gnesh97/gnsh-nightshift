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
        local marker = statements[#statements] and statements[#statements].parameters or {}
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
    local db = newDatabase({}, true)
    local runner = NightShift.Migrations.Runner.new({
        db = db,
        migrations = { {
            version = 1,
            name = '001_multi.sql',
            sql = "CREATE TABLE first_table (label VARCHAR(16) DEFAULT 'a;b'); CREATE TABLE second_table (id INT);"
        } }
    })
    local result = runner:run()
    local transaction = db.transactions[1]
    check(result.ok and transaction and #transaction == 3, 'multi-statement migrations must be split before the marker')
    check(transaction[1].query:find("DEFAULT 'a;b'", 1, true) ~= nil and transaction[2].query:find('second_table', 1, true) ~= nil, 'migration statement splitting must preserve quoted semicolons')
    check(transaction[3].query:find('nightshift_schema_migrations', 1, true) ~= nil, 'migration marker must remain the final transaction statement')
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
    local previousGetResourceName = rawget(_G, 'GetCurrentResourceName')
    local previousLoadResourceFile = rawget(_G, 'LoadResourceFile')
    local ok, errorMessage = pcall(function()
        _G.GetCurrentResourceName = function() return 'gnsh-nightshift' end
        _G.LoadResourceFile = function(resourceName, path)
            check(resourceName == 'gnsh-nightshift' and path == 'sql/001_schema_version.sql', 'default migration loader must target the current resource')
            return 'CREATE TABLE nightshift_schema_migrations (version INT)'
        end
        local runner = NightShift.Migrations.Runner.new({
            db = newDatabase({}, true),
            migrations = { { version = 1, name = '001_schema_version.sql', file = 'sql/001_schema_version.sql' } }
        })
        local result = runner:run()
        check(result.ok and result.value.currentVersion == 1 and #result.value.applied == 1, 'default migration loader must read SQL through FiveM natives')
    end)
    _G.GetCurrentResourceName = previousGetResourceName
    _G.LoadResourceFile = previousLoadResourceFile
    check(ok, errorMessage)
end

do
    local previousGetConvar = rawget(_G, 'GetConvar')
    local previousMySQL = rawget(_G, 'MySQL')
    local previousExports = rawget(_G, 'exports')
    local ok, errorMessage = pcall(function()
        _G.GetConvar = function(name, fallback)
            return name == 'nightshift_persistence' and 'true' or fallback
        end
        local source = NightShift.Validators.copy(NightShift.DefaultConfig)
        local enabled = NightShift.ServerBootstrap.applyRuntimeConfig(source)
        check(enabled ~= source and enabled.features.persistence == true, 'runtime persistence convar must return a config copy with persistence enabled')
        check(source.features.persistence == false, 'runtime persistence convar must not mutate the default config')

        _G.GetConvar = function(_, fallback) return fallback end
        local disabled = NightShift.ServerBootstrap.applyRuntimeConfig(source)
        check(disabled == source and disabled.features.persistence == false, 'disabled runtime persistence must preserve the source config')

        _G.GetConvar = function() return 'true' end
        _G.MySQL = { scalar = { await = function() return 1 end } }
        local adapter = NightShift.ServerBootstrap.createRuntimeDatabaseAdapter()
        check(adapter and adapter:healthCheck().ok, 'runtime oxmysql adapter must expose a healthy normalized database contract')

        local resolver = NightShift.ProviderResolver.new({
            frameworkAdapters = { standalone = NightShift.FrameworkAdapters.standalone.new({ available = true }) },
            moneyAdapters = { standalone = NightShift.MoneyAdapters.standalone.new({ enabled = false }) }
        })
        local bootOk, bootResult = NightShift.Server.bootstrap({
            config = source,
            providerResolver = resolver,
            migrationRunner = { run = function() return NightShift.Result.ok({ currentVersion = 12, applied = {} }) end }
        })
        check(bootOk and bootResult.config.config.features.persistence == true, 'runtime persistence convar must enable the default config stage')
        check(bootResult.db.database and bootResult.db.migrations.value.currentVersion == 12, 'runtime persistence bootstrap must auto-wire oxmysql before migrations')
    end)
    _G.GetConvar = previousGetConvar
    _G.MySQL = previousMySQL
    _G.exports = previousExports
    check(ok, errorMessage)
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
    check(result.ok and result.value.currentVersion == 13 and #result.value.applied == 13, 'registered SQL migrations must run from default definitions')
end
