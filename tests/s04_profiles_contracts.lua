local function check(value, message) assert(value, message) end

local function result(value) return NightShift.Result.ok(value) end

local state = {
    [10] = {
        identifier = 'license:alpha',
        characterId = 'character-1',
        characterName = 'Alice Example',
        job = { name = 'worker', grade = 1, onDuty = true }
    }
}

local lifecycle = {}
local framework = assert(NightShift.FrameworkInterface.new({
    name = 's04-test',
    getPlayer = function(source) return state[tonumber(source)] end,
    isPlayerLoaded = function(source) return state[tonumber(source)] ~= nil end,
    onJobChanged = function(handler) lifecycle.job = handler; return 'job-token' end,
    onPlayerUnloaded = function(handler) lifecycle.unloaded = handler; return 'unloaded-token' end,
    capabilities = { identity = true, characterId = true, job = true, lifecycle = true }
}))

do
    local service = assert(NightShift.IdentityService.new({ framework = framework }))
    local first = service:resolve(10, { alias = ' <Alice>\nExample ' })
    check(first.ok, 'identity must resolve from the normalized framework adapter')
    check(first.value.identityKey == first.value.key, 'identity must expose one stable composite key')
    check(first.value.identityKey:find('license:alpha', 1, true) ~= nil, 'identity key must include persistent identifier')
    check(first.value.identityKey:find('character-1', 1, true) ~= nil, 'identity key must include character ID')
    check(first.value.displayName == 'Alice Example', 'display alias must strip unsafe/control characters')
    check(first.value.displayName:find('[<>\r\n]') == nil, 'display alias must not contain markup/control characters')
    check(first.value.source == 10, 'runtime source may be exposed only as an ephemeral field')

    state[22] = NightShift.Validators.copy(state[10])
    local reconnect = service:resolve(22)
    check(reconnect.ok and reconnect.value.identityKey == first.value.identityKey, 'reconnect must map to the same persistent identity')
    check(reconnect.value.source == 22, 'reconnect must refresh the ephemeral source')

    state[22].characterId = 'character-2'
    state[22].characterName = 'Alice Two'
    local switched = service:resolve(22)
    check(switched.ok and switched.value.identityKey ~= first.value.identityKey, 'character switch must create a distinct identity key')

    state[22].identifier = 'license:other'
    local reused = service:resolve(22)
    check(reused.ok and reused.value.identityKey ~= switched.value.identityKey, 'source ID reuse must not reuse the old identity')

    local released = service:releaseSource(22)
    check(released.ok and released.value.released == true, 'source release must clear only the ephemeral mapping')
    check(service:getSource(first.value.identityKey) == nil, 'released source mapping must not survive')
end

local function makeDb()
    local db = { rows = {}, nextId = 1, calls = {} }

    local function insertColumns(sql)
        local body = sql:match('VALUES') and sql:match('INSERT INTO.-%((.-)%) VALUES') or nil
        local fields = {}
        if body then
            for field in body:gmatch('`([A-Za-z_][A-Za-z0-9_]*)`') do fields[#fields + 1] = field end
        end
        return fields
    end

    function db:single(sql, params)
        self.calls.single = { sql = sql, params = NightShift.Validators.copy(params) }
        local row
        if sql:find('`player_identifier`', 1, true) then
            local identifier, characterId = params[1], params[2]
            for _, candidate in ipairs(self.rows) do
                if candidate.player_identifier == identifier and candidate.character_id == characterId then
                    row = NightShift.Validators.copy(candidate)
                    break
                end
            end
        else
            local id = tonumber(params[1])
            for _, candidate in ipairs(self.rows) do
                if tonumber(candidate.id) == id then row = NightShift.Validators.copy(candidate); break end
            end
        end
        return result(row)
    end

    function db:query(sql, params)
        self.calls.query = { sql = sql, params = NightShift.Validators.copy(params) }
        local rows = {}
        for index, row in ipairs(self.rows) do rows[index] = NightShift.Validators.copy(row) end
        return result(rows)
    end

    function db:insert(sql, params)
        self.calls.insert = { sql = sql, params = NightShift.Validators.copy(params) }
        local row = {}
        local fields = insertColumns(sql)
        for index, field in ipairs(fields) do row[field] = params[index] end
        row.id = self.nextId
        self.nextId = self.nextId + 1
        row.version = row.version or 1
        self.rows[#self.rows + 1] = row
        return result({ insertId = row.id })
    end

    function db:update(sql, params)
        self.calls.update = { sql = sql, params = NightShift.Validators.copy(params) }
        local id = tonumber(params[#params - 1])
        local expectedVersion = tonumber(params[#params])
        for _, row in ipairs(self.rows) do
            if tonumber(row.id) == id and tonumber(row.version or 1) == expectedVersion then
                row.version = expectedVersion + 1
                return result({ affectedRows = 1 })
            end
        end
        return result({ affectedRows = 0 })
    end

    function db:scalar(sql, params)
        local id = tonumber(params[1])
        for _, row in ipairs(self.rows) do
            if tonumber(row.id) == id then return result(1) end
        end
        return result(nil)
    end

    return db
end

local identityService = assert(NightShift.IdentityService.new({ framework = framework }))
local db = makeDb()
local workerRepository = assert(NightShift.Repositories.WorkerProfile.new({ db = db }))
local clientRepository = assert(NightShift.Repositories.ClientProfile.new({ db = db }))
local workerService = assert(NightShift.WorkerProfileService.new({ identityService = identityService, repository = workerRepository }))
local clientService = assert(NightShift.ClientProfileService.new({ identityService = identityService, repository = clientRepository }))

do
    state[10].identifier = 'license:alpha'
    state[10].characterId = 'character-1'
    state[10].characterName = 'Alice Example'
    state[10].job = { name = 'worker', grade = 1, onDuty = true }
    local missing = workerRepository:findByIdentity('license:alpha', 'character-1')
    check(not missing.ok and missing.error.code == NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'worker identity lookup must be typed when absent')

    local created = workerService:ensure(10, { alias = 'Alice', availability = 'available', reliability = 44 })
    check(created.ok and created.value.id == 1, 'worker ensure must create a persistent profile')
    check(created.value.playerIdentifier == 'license:alpha' and created.value.characterId == 'character-1', 'worker profile must persist normalized identity fields')
    check(created.value.availability == 'available' and created.value.reliability == 44, 'worker profile fields must normalize')
    check(db.calls.insert.sql:find('`player_identifier`', 1, true) ~= nil, 'worker create must use the repository boundary')

    state[22] = NightShift.Validators.copy(state[10])
    local reconnect = workerService:ensure(22)
    check(reconnect.ok and reconnect.value.id == created.value.id, 'worker profile must survive reconnect/source change')

    local updated = workerService:update(22, { availability = 'busy', reliability = 55 })
    check(updated.ok and updated.value.version == 2 and updated.value.availability == 'busy', 'worker update must be versioned and immutable')
    check(created.value.availability == 'available' and created.value.version == 1, 'worker update must not mutate the old profile value')

    state[22].characterId = 'character-2'
    local switched = workerService:ensure(22, { alias = 'Alice Two' })
    check(switched.ok and switched.value.id ~= created.value.id, 'worker profile must be isolated per character')

    state[22].identifier = 'license:source-reused'
    local sourceReused = workerService:get(22)
    check(not sourceReused.ok and sourceReused.error.code == NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'source reuse must not return a previous profile')
end

do
    state[10].identifier = 'license:client'
    state[10].characterId = 'client-character-1'
    state[10].characterName = 'Client One'
    local first = clientService:ensure(10, { alias = 'Client One', locale = 'tr', tier = 'new' })
    check(first.ok and first.value.completedBookings == 0 and first.value.noShowBookings == 0, 'client profile must initialize counters')

    state[10].characterId = 'client-character-2'
    local second = clientService:ensure(10, { alias = 'Client Two', locale = 'en' })
    check(second.ok and second.value.id ~= first.value.id, 'client profile must be isolated by character ID')

    local updated = clientService:update(10, { completedBookings = 2, depositRiskScore = 10 })
    check(updated.ok and updated.value.version == 2 and updated.value.completedBookings == 2, 'client profile updates must be versioned')
    check(first.value.completedBookings == 0, 'client profile update must preserve immutable prior values')
end

do
    local permissionConfig = {
        permissions = {
            ['admin.manage'] = { ace = 'nightshift.admin', jobs = { admin = 0 } },
            ['worker.profile.update'] = { jobs = { worker = 0 } }
        }
    }
    local ace = {}
    state[10].identifier = 'license:permissions'
    state[10].characterId = 'permission-character'
    state[10].job = { name = 'worker', grade = 1, onDuty = true }
    local permissions = assert(NightShift.PermissionService.new({
        framework = framework,
        identityService = identityService,
        config = permissionConfig,
        aceChecker = function(source, aceName) return ace[tonumber(source)] == aceName end
    }))

    local denied = permissions:authorize(10, 'admin.manage')
    check(not denied.ok and denied.error.code == NightShift.Errors.Codes.PERMISSION_DENIED, 'unauthorized admin action must fail closed')

    local workerAllowed = permissions:authorize(10, 'worker.profile.update')
    check(workerAllowed.ok and workerAllowed.value.allowed == true, 'configured framework job must grant only its mapped permission')

    state[10].job = { name = 'admin', grade = 0, onDuty = true }
    check(type(lifecycle.job) == 'function', 'permission service must subscribe to job changes')
    lifecycle.job(10)
    local adminAllowed = permissions:authorize(10, 'admin.manage')
    check(adminAllowed.ok and adminAllowed.value.via == 'job', 'job change must invalidate authorization cache')

    state[10].job = { name = 'civilian', grade = 0, onDuty = false }
    lifecycle.job(10)
    local invalidated = permissions:authorize(10, 'admin.manage')
    check(not invalidated.ok and invalidated.error.code == NightShift.Errors.Codes.PERMISSION_DENIED, 'stale authorization must not survive a job change')

    ace[10] = 'nightshift.admin'
    local aceAllowed = permissions:authorize(10, 'admin.manage')
    check(aceAllowed.ok and aceAllowed.value.via == 'ace', 'ACE authorization must be evaluated server-side')

    local unknown = permissions:authorize(10, 'client.supplied.flag')
    check(not unknown.ok and unknown.error.code == NightShift.Errors.Codes.PERMISSION_INVALID, 'unknown permission keys must fail closed')
end

do
    local config = NightShift.Validators.copy(NightShift.DefaultConfig)
    config.features.persistence = true
    local databaseAdapter = { healthCheck = function() return NightShift.Result.ok({ healthy = true }) end }
    local migrationRunner = { run = function() return NightShift.Result.ok({ currentVersion = 10, applied = {} }) end }
    local resolver = {
        resolve = function()
            return NightShift.Result.ok({ framework = framework, money = nil, optional = {}, capabilities = {}, diagnostics = {} })
        end
    }
    local ok, boot = NightShift.Server.bootstrap({
        config = config,
        databaseAdapter = databaseAdapter,
        migrationRunner = migrationRunner,
        providerResolverRuntime = resolver,
        permissionConfig = { permissions = { ['admin.manage'] = { jobs = { admin = 0 } } } }
    })
    check(ok and boot.repositories.repositories.workerProfile and boot.repositories.repositories.clientProfile, 'S04 bootstrap must construct profile repositories')
    check(boot.services.services.identity and boot.services.services.workerProfile and boot.services.services.clientProfile and boot.services.services.permissions, 'S04 bootstrap must construct identity/profile/permission services')
end

print('NS-040..NS-043 tests passed: identity, player profiles, persistence, and centralized permissions')
