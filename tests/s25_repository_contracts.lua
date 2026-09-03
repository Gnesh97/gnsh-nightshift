local function check(value, message) assert(value, message) end

local previousJson = rawget(_G, 'json')
local previousRows = rawget(_G, '__s25Rows')
local rows = {}
_G.__s25Rows = rows
_G.json = {
    encode = function() return '{}' end,
    decode = function() return { persisted = true } end
}

local db = {}
function db:single(sql, parameters)
    if sql:find('WHERE scope =', 1, true) then
        for _, row in ipairs(rows) do
            if row.scope == parameters[1] and row.idempotency_key == parameters[2] then return NightShift.Result.ok(row) end
        end
        return NightShift.Result.ok(nil)
    end
    if sql:find('WHERE id =', 1, true) then
        for _, row in ipairs(rows) do
            if row.id == parameters[1] then return NightShift.Result.ok(row) end
        end
    end
    return NightShift.Result.ok(nil)
end
function db:scalar(_, parameters)
    for _, row in ipairs(rows) do if row.id == parameters[1] then return NightShift.Result.ok(1) end end
    return NightShift.Result.ok(nil)
end
function db:insert(_, parameters)
    local row = {
        id = #rows + 1, scope = parameters[1], idempotency_key = parameters[2],
        fingerprint = parameters[3], status = parameters[4], result_json = parameters[5],
        created_at = parameters[6], updated_at = parameters[7], expires_at = parameters[8], version = 1
    }
    rows[#rows + 1] = row
    return NightShift.Result.ok({ insertId = row.id })
end
function db:update(sql, parameters)
    if sql:find('DELETE FROM', 1, true) then return NightShift.Result.ok({ affectedRows = #rows }) end
    local id, expected = parameters[#parameters - 1], parameters[#parameters]
    for _, row in ipairs(rows) do
        if row.id == id and row.version == expected then
            if sql:find('result_json', 1, true) then row.result_json = parameters[1] end
            if sql:find('status', 1, true) then row.status = parameters[2] end
            row.version = row.version + 1
            return NightShift.Result.ok({ affectedRows = 1 })
        end
    end
    return NightShift.Result.ok({ affectedRows = 0 })
end

do
    local repository, repositoryError = NightShift.Repositories.Idempotency.new({ db = db })
    check(repository and not repositoryError, 'idempotency repository must initialize')
    local created = repository:create({
        scope = 'smoke', key = 'request-1', fingerprint = 'deadbeef', status = 'PENDING',
        createdAt = 1000, updatedAt = 1000, expiresAt = 1010
    })
    check(created.ok and created.value.insertId == 1, 'idempotency repository must create a row')
    local found = repository:findByKey('smoke', 'request-1')
    check(found.ok and found.value.status == 'PENDING' and found.value.version == 1, 'idempotency repository must map a row')
    local updated = repository:updateExpectedVersion(1, 1, { status = 'COMPLETED', value = { accepted = true }, updatedAt = 1005 })
    check(updated.ok and updated.value.version == 2, 'idempotency repository must support optimistic completion')
    found = repository:findByKey('smoke', 'request-1')
    check(found.ok and found.value.status == 'COMPLETED' and found.value.value.persisted == true, 'idempotency result must be decoded safely')
    check(repository:deleteExpired(1011, 10).ok, 'idempotency repository must expose bounded purge')
end

_G.json = previousJson
_G.__s25Rows = previousRows
print('NS-260..NS-262 tests passed: persisted idempotency mapping, optimistic update, and purge')
