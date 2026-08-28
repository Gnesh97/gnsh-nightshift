local function check(value, message) assert(value, message) end

local function result(value) return NightShift.Result.ok(value) end

do
    local calls = {}
    local db = {
        single = function(_, sql, params) calls.single = { sql = sql, params = params }; return result({ id = 7, status = 'PENDING' }) end,
        query = function(_, sql, params) calls.query = { sql = sql, params = params }; return result({ { id = 7, status = 'PENDING' }, { id = 8, status = 'READY' } }) end,
        insert = function(_, sql, params) calls.insert = { sql = sql, params = params }; return result({ insertId = 7 }) end,
        update = function(_, sql, params) calls.update = { sql = sql, params = params }; return result({ affectedRows = 1 }) end,
        scalar = function(_, sql, params) calls.scalar = { sql = sql, params = params }; return result(1) end
    }
    local repo = assert(NightShift.Repositories.Base.new({ db = db, tableName = 'nightshift_bookings' }))
    check(repo:findById(0).error.code == 'REPOSITORY_INVALID', 'non-positive IDs must fail validation')
    local row = assert(repo:findById(7)).value
    check(row.id == 7 and calls.single.sql:find('`nightshift_bookings`', 1, true) and calls.single.params[1] == 7, 'findById must use a parameterized table query')
    local rows = assert(repo:findAll({ limit = 10, offset = 2 })).value
    check(#rows == 2 and calls.query.params[1] == 10 and calls.query.params[2] == 2, 'findAll must map rows and parameterize paging')
    local created = repo:create({ status = 'PENDING', service_package_id = 'standard' })
    check(created.ok and created.value.insertId == 7 and calls.insert.sql:find('service_package_id', 1, true), 'create must use sorted allowlisted columns')
    local changes = { status = 'ARRIVED' }
    local updated = repo:updateExpectedVersion(7, 1, changes)
    check(updated.ok and updated.value.version == 2 and calls.update.sql:find('version = version + 1', 1, true), 'expected-version update must increment version conditionally')
    check(changes.status == 'ARRIVED', 'repository must not mutate caller changes')
    local deleted = repo:deleteExpectedVersion(7, 1)
    check(deleted.ok and deleted.value.deleted and calls.update.sql:find('DELETE FROM', 1, true), 'expected-version delete must be conditional')
end

do
    local db = {
        update = function() return result({ affectedRows = 0 }) end,
        scalar = function() return result(nil) end
    }
    local repo = assert(NightShift.Repositories.Base.new({ db = db, tableName = 'nightshift_bookings' }))
    local resultValue = repo:updateExpectedVersion(7, 1, { status = 'ARRIVED' })
    check(not resultValue.ok and resultValue.error.code == 'REPOSITORY_NOT_FOUND', 'zero update must distinguish missing row')

    db.scalar = function() return result(1) end
    resultValue = repo:updateExpectedVersion(7, 1, { status = 'ARRIVED' })
    check(not resultValue.ok and resultValue.error.code == 'VERSION_CONFLICT', 'existing row with stale version must conflict')
    check(repo:findAll(false).error.code == 'REPOSITORY_INVALID', 'malformed findAll options must fail closed')
end

do
    local mapper = function() error('mapper failure') end
    local repo = assert(NightShift.Repositories.Base.new({
        db = { single = function() return result({ id = 1 }) end },
        tableName = 'nightshift_bookings',
        mapper = mapper
    }))
    local mapped = repo:findById(1)
    check(not mapped.ok and mapped.error.code == 'MAPPING_FAILED', 'row mapper failures must be typed')
    local invalid, err = NightShift.Repositories.Base.new({ db = {}, tableName = 'nightshift_bookings; DROP TABLE users' })
    check(not invalid and err.error.code == 'REPOSITORY_INVALID', 'table identifiers must be allowlisted')
end
