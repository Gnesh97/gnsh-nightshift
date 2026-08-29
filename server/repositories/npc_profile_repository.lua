NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.NpcProfile

local Repository = {}
Repository.__index = Repository

local profileColumns = {
    'id', 'profile_key', 'role', 'profile_type', 'display_name',
    'appearance_profile_ref', 'budget_class', 'price_class', 'rating',
    'availability', 'traits', 'tags', 'home_district', 'active_district',
    'travel_mode', 'generation_seed', 'completed_bookings',
    'cancelled_bookings', 'no_show_bookings', 'last_active_at', 'expires_at',
    'version', 'created_at', 'updated_at'
}

local workerColumns = {
    'id', 'worker_key', 'profile_id', 'state', 'current_location_id',
    'booking_id', 'reservation_key', 'hold_until', 'expires_at',
    'last_active_at', 'version', 'created_at', 'updated_at'
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

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function integer(value, minimum)
    value = tonumber(value)
    return value and value == math.floor(value) and value >= (minimum or 1) and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function codec(options, direction, value)
    if value == nil then return nil end
    local fn = options and options[direction]
    if type(fn) == 'function' then
        local ok, result = pcall(fn, value)
        if ok then return result end
        return nil
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
            if ok and type(result) == 'table' then return result end
        end
    end
    return value
end

local function mapProfile(row, options)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'NPC profile row is invalid') end
    local source = copy(row)
    if source.traits == nil and source.traits_json ~= nil then source.traits = source.traits_json end
    if source.tags == nil and source.tags_json ~= nil then source.tags = source.tags_json end
    if source.traits ~= nil then source.traits = codec(options, 'decode', source.traits) end
    if source.tags ~= nil then source.tags = codec(options, 'decode', source.tags) end
    local profile, errorResult = Domain.fromRow(source)
    if not profile then
        return nil, Result.err(Codes.MAPPING_FAILED, 'NPC profile row mapping failed', {
            cause = errorResult and errorResult.error and errorResult.error.code
        })
    end
    return profile
end

local function mapWorker(row, options)
    if type(row) ~= 'table' then return nil, Result.err(Codes.MAPPING_FAILED, 'NPC worker row is invalid') end
    local source = copy(row)
    local profile = source.profile
    if type(profile) ~= 'table' then
        local profileSource = {}
        for key, value in pairs(source) do
            if type(key) == 'string' and key:match('^profile_') then profileSource[key:gsub('^profile_', '')] = value end
        end
        if source.profile_id_value ~= nil then profileSource.id = source.profile_id_value end
        profile = mapProfile(profileSource, options)
    end
    if not profile then return nil, Result.err(Codes.MAPPING_FAILED, 'NPC worker profile mapping failed') end
    return {
        id = source.worker_id or source.id,
        workerKey = source.worker_key,
        profileId = source.profile_id or profile.id,
        state = type(source.state) == 'string' and source.state:upper() or source.state,
        currentLocationId = source.current_location_id,
        bookingId = source.booking_id,
        reservationKey = source.reservation_key,
        holdUntil = source.hold_until,
        expiresAt = source.expires_at,
        lastActiveAt = source.last_active_at,
        version = tonumber(source.version) or 1,
        createdAt = source.created_at,
        updatedAt = source.updated_at,
        profile = profile
    }
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'NPC profile repository requires a database adapter') end
    local profileTable = options.profileTableName or 'nightshift_npc_profiles'
    local workerTable = options.workerTableName or 'nightshift_npc_workers'
    if not token(profileTable, 64) or not token(workerTable, 64) then return nil, invalid('NPC profile table name is invalid') end
    local settings = copy(options)
    settings.db, settings.tableName, settings.columns = database, profileTable, profileColumns
    settings.mapper = function(row) return mapProfile(row, settings) end
    local profileBase, profileError = Base.new(settings)
    if not profileBase then return nil, profileError end
    local workerBase, workerError = Base.new({ db = database, tableName = workerTable, columns = workerColumns })
    if not workerBase then return nil, workerError end
    return setmetatable({
        _db = database,
        _profileTable = profileTable,
        _workerTable = workerTable,
        _profileBase = profileBase,
        _workerBase = workerBase,
        _options = settings
    }, Repository)
end

function Repository:findProfileById(id)
    return self._profileBase:findById(id)
end

function Repository:findProfileByKey(profileKey)
    if not token(profileKey, 96) then return invalid('NPC profile key is invalid') end
    local selectList, errorResult = self._profileBase:_selectList()
    if not selectList then return errorResult end
    local result = self._db:single(('SELECT %s FROM %s WHERE profile_key = ? LIMIT 1'):format(selectList, self._profileTable), { profileKey })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'NPC profile was not found', { profileKey = profileKey }) end
    local mapped, mapResult = self._profileBase:_map(result.value)
    if not mapped then return mapResult end
    return Result.ok(mapped, { profileKey = profileKey })
end

function Repository:findProfiles(options)
    return self._profileBase:findAll(options)
end

function Repository:createProfile(profile)
    local row, errorResult = Domain.toRow(profile)
    if not row then return errorResult end
    local encoded = {
        profile_key = row.profile_key,
        role = row.role,
        profile_type = row.profile_type,
        display_name = row.display_name,
        appearance_profile_ref = row.appearance_profile_ref,
        budget_class = row.budget_class,
        price_class = row.price_class,
        rating = row.rating,
        availability = row.availability,
        traits = codec(self._options, 'encode', row.traits),
        tags = codec(self._options, 'encode', row.tags),
        home_district = row.home_district,
        active_district = row.active_district,
        travel_mode = row.travel_mode,
        generation_seed = row.generation_seed,
        completed_bookings = row.completed_bookings,
        cancelled_bookings = row.cancelled_bookings,
        no_show_bookings = row.no_show_bookings,
        last_active_at = row.last_active_at,
        expires_at = row.expires_at
    }
    return self._profileBase:create(encoded)
end

Repository.create = Repository.createProfile

function Repository:updateProfileExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('NPC profile changes must be a table') end
    local mapped, aliases, seen = {}, {
        profileType = 'profile_type', profile_type = 'profile_type',
        alias = 'display_name', displayName = 'display_name', display_name = 'display_name',
        appearanceProfileRef = 'appearance_profile_ref', appearance_profile_ref = 'appearance_profile_ref',
        budgetClass = 'budget_class', budget_class = 'budget_class',
        priceClass = 'price_class', price_class = 'price_class',
        rating = 'rating', availability = 'availability',
        traits = 'traits', tags = 'tags',
        homeDistrict = 'home_district', home_district = 'home_district',
        activeDistrict = 'active_district', active_district = 'active_district',
        travelMode = 'travel_mode', travel_mode = 'travel_mode',
        completedBookings = 'completed_bookings', completed_bookings = 'completed_bookings',
        cancelledBookings = 'cancelled_bookings', cancelled_bookings = 'cancelled_bookings',
        noShowBookings = 'no_show_bookings', no_show_bookings = 'no_show_bookings',
        lastActiveAt = 'last_active_at', last_active_at = 'last_active_at',
        expiresAt = 'expires_at', expires_at = 'expires_at'
    }, {}
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field or seen[field] then return invalid('NPC profile field is not mutable', { field = tostring(key) }) end
        seen[field] = true
        if field == 'traits' or field == 'tags' then value = codec(self._options, 'encode', value) end
        mapped[field] = value
    end
    return self._profileBase:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateProfileExpectedVersion

function Repository:findWorkerById(id)
    local result = self._workerBase:findById(id)
    if type(result) ~= 'table' or not result.ok then return result end
    local profileResult = self:findProfileById(result.value.profile_id)
    if type(profileResult) ~= 'table' or not profileResult.ok then return profileResult end
    result.value.profile = profileResult.value
    return Result.ok(mapWorker(result.value, self._options))
end

function Repository:findWorkerByKey(workerKey)
    if not token(workerKey, 160) then return invalid('NPC worker key is invalid') end
    local selectList, selectError = self._workerBase:_selectList()
    if not selectList then return selectError end
    local result = self._db:single(('SELECT %s FROM %s WHERE worker_key = ? LIMIT 1'):format(selectList, self._workerTable), { workerKey })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'NPC worker was not found', { workerKey = workerKey }) end
    local row = result.value
    local profileResult = self:findProfileById(row.profile_id)
    if type(profileResult) ~= 'table' or not profileResult.ok then return profileResult end
    row.profile = profileResult.value
    local mapped, mapResult = mapWorker(row, self._options)
    if not mapped then return mapResult end
    return Result.ok(mapped, { workerKey = workerKey })
end

function Repository:createWorker(values)
    if type(values) ~= 'table' then return invalid('NPC worker values must be a table') end
    if not token(values.workerKey or values.worker_key, 160) then return invalid('NPC worker key is invalid') end
    if not integer(values.profileId or values.profile_id, 1) then return invalid('NPC worker profile ID is invalid') end
    local state = tostring(values.state or 'AVAILABLE'):upper()
    if not NightShift.Enums.NpcWorkerStates[state] then return invalid('NPC worker state is invalid') end
    return self._workerBase:create({
        worker_key = values.workerKey or values.worker_key,
        profile_id = values.profileId or values.profile_id,
        state = state,
        current_location_id = values.currentLocationId or values.current_location_id,
        booking_id = values.bookingId or values.booking_id,
        reservation_key = values.reservationKey or values.reservation_key,
        hold_until = values.holdUntil or values.hold_until,
        expires_at = values.expiresAt or values.expires_at,
        last_active_at = values.lastActiveAt or values.last_active_at
    })
end

function Repository:listWorkers(options)
    options = options or {}
    if type(options) ~= 'table' then return invalid('NPC worker list options are invalid') end
    local limit = options.limit == nil and 100 or tonumber(options.limit)
    local offset = options.offset == nil and 0 or tonumber(options.offset)
    if not integer(limit, 1) or limit > 100 or not integer(offset, 0) then return invalid('NPC worker pagination is invalid') end
    local where, parameters = {
        "w.state = 'AVAILABLE'",
        "NOT (p.profile_type = 'SEMI_PERSISTENT' AND ((w.expires_at IS NOT NULL AND w.expires_at <= CURRENT_TIMESTAMP(3)) OR (p.expires_at IS NOT NULL AND p.expires_at <= CURRENT_TIMESTAMP(3))))"
    }, {}
    if options.district ~= nil then
        if not token(tostring(options.district), 64) then return invalid('NPC worker district filter is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'p.active_district = ?', tostring(options.district):lower()
    end
    if options.priceClass ~= nil then
        if not integer(options.priceClass, 1) or tonumber(options.priceClass) > 5 then return invalid('NPC worker price filter is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'p.price_class = ?', tonumber(options.priceClass)
    end
    if options.maxPriceClass ~= nil then
        if not integer(options.maxPriceClass, 1) or tonumber(options.maxPriceClass) > 5 then return invalid('NPC worker maximum price filter is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'p.price_class <= ?', tonumber(options.maxPriceClass)
    end
    if options.minRating ~= nil then
        local rating = tonumber(options.minRating)
        if not rating or rating < 0 or rating > 5 then return invalid('NPC worker rating filter is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'p.rating >= ?', rating
    end
    if options.travelMode ~= nil then
        local travelMode = type(options.travelMode) == 'string' and options.travelMode:upper() or nil
        if not travelMode or not NightShift.Enums.NpcTravelModes[travelMode] then return invalid('NPC worker travel filter is invalid') end
        where[#where + 1], parameters[#parameters + 1] = 'p.travel_mode = ?', travelMode
    end
    parameters[#parameters + 1], parameters[#parameters + 1] = limit, offset
    local sql = ([[
        SELECT
            w.id AS worker_id, w.worker_key, w.profile_id, w.state,
            w.current_location_id, w.booking_id, w.reservation_key,
            w.hold_until, w.expires_at, w.last_active_at, w.version,
            w.created_at, w.updated_at,
            p.id AS profile_id_value, p.profile_key AS profile_profile_key,
            p.role AS profile_role, p.profile_type AS profile_profile_type,
            p.display_name AS profile_display_name,
            p.appearance_profile_ref AS profile_appearance_profile_ref,
            p.budget_class AS profile_budget_class, p.price_class AS profile_price_class,
            p.rating AS profile_rating, p.availability AS profile_availability,
            p.traits AS profile_traits, p.tags AS profile_tags,
            p.home_district AS profile_home_district, p.active_district AS profile_active_district,
            p.travel_mode AS profile_travel_mode, p.generation_seed AS profile_generation_seed,
            p.completed_bookings AS profile_completed_bookings,
            p.cancelled_bookings AS profile_cancelled_bookings,
            p.no_show_bookings AS profile_no_show_bookings,
            p.last_active_at AS profile_last_active_at, p.expires_at AS profile_expires_at,
            p.version AS profile_version, p.created_at AS profile_created_at,
            p.updated_at AS profile_updated_at
        FROM %s w INNER JOIN %s p ON p.id = w.profile_id
        WHERE %s
        ORDER BY w.worker_key ASC LIMIT ? OFFSET ?
    ]]):format(self._workerTable, self._profileTable, table.concat(where, ' AND '))
    local result = self._db:query(sql, parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local values = {}
    for index, row in ipairs(result.value or {}) do
        local mapped, mapResult = mapWorker(row, self._options)
        if not mapped then return mapResult end
        values[index] = mapped
    end
    return Result.ok(values, { limit = limit, offset = offset })
end

function Repository:reserveWorkerAtomic(workerKey, bookingId, reservationKey, holdUntil, expectedVersion)
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) or not token(reservationKey, 200) then
        return invalid('NPC worker reservation identity is invalid')
    end
    local parameters = { tostring(bookingId), reservationKey, holdUntil, workerKey }
    local predicate = "w.worker_key = ? AND w.state = 'AVAILABLE' AND (w.hold_until IS NULL OR w.hold_until <= CURRENT_TIMESTAMP(3)) AND NOT (p.profile_type = 'SEMI_PERSISTENT' AND ((w.expires_at IS NOT NULL AND w.expires_at <= CURRENT_TIMESTAMP(3)) OR (p.expires_at IS NOT NULL AND p.expires_at <= CURRENT_TIMESTAMP(3))))"
    if expectedVersion ~= nil then
        if not integer(expectedVersion, 1) then return invalid('NPC worker expected version is invalid') end
        predicate = predicate .. ' AND version = ?'
        parameters[#parameters + 1] = expectedVersion
    end
    local result = self._db:update(("UPDATE %s w INNER JOIN %s p ON p.id = w.profile_id SET w.state = 'RESERVED', w.booking_id = ?, w.reservation_key = ?, w.hold_until = ?, w.version = w.version + 1, w.updated_at = CURRENT_TIMESTAMP(3) WHERE %s"):format(self._workerTable, self._profileTable, predicate), parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local affected = tonumber(result.value and result.value.affectedRows) or 0
    if affected > 0 then return Result.ok({ workerKey = workerKey, bookingId = tostring(bookingId), reservationKey = reservationKey, state = 'RESERVED', affectedRows = affected }) end
    return Result.err(Codes.NPC_WORKER_CONFLICT, 'NPC worker is not available for reservation', { workerKey = workerKey })
end

function Repository:occupyWorkerAtomic(workerKey, bookingId, expectedVersion)
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) then return invalid('NPC worker occupancy identity is invalid') end
    local parameters, predicate = { tostring(bookingId), workerKey }, 'worker_key = ? AND booking_id = ? AND state = \'RESERVED\''
    if expectedVersion ~= nil then
        if not integer(expectedVersion, 1) then return invalid('NPC worker expected version is invalid') end
        predicate = predicate .. ' AND version = ?'
        parameters[#parameters + 1] = expectedVersion
    end
    local result = self._db:update(("UPDATE %s SET state = 'OCCUPIED', version = version + 1, updated_at = CURRENT_TIMESTAMP(3) WHERE %s"):format(self._workerTable, predicate), parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local affected = tonumber(result.value and result.value.affectedRows) or 0
    if affected > 0 then return Result.ok({ workerKey = workerKey, bookingId = tostring(bookingId), state = 'OCCUPIED', affectedRows = affected }) end
    return Result.err(Codes.NPC_WORKER_CONFLICT, 'NPC worker cannot be occupied by this booking', { workerKey = workerKey })
end

function Repository:releaseWorkerAtomic(workerKey, bookingId, expectedVersion)
    if not token(workerKey, 160) or not text(tostring(bookingId), 160) then return invalid('NPC worker release identity is invalid') end
    local parameters, predicate = { workerKey, tostring(bookingId) }, 'worker_key = ? AND booking_id = ? AND state IN (\'RESERVED\', \'OCCUPIED\')'
    if expectedVersion ~= nil then
        if not integer(expectedVersion, 1) then return invalid('NPC worker expected version is invalid') end
        predicate = predicate .. ' AND version = ?'
        parameters[#parameters + 1] = expectedVersion
    end
    local result = self._db:update(("UPDATE %s SET state = 'AVAILABLE', booking_id = NULL, reservation_key = NULL, hold_until = NULL, version = version + 1, updated_at = CURRENT_TIMESTAMP(3) WHERE %s"):format(self._workerTable, predicate), parameters)
    if type(result) ~= 'table' or not result.ok then return result end
    local affected = tonumber(result.value and result.value.affectedRows) or 0
    if affected > 0 then return Result.ok({ workerKey = workerKey, bookingId = tostring(bookingId), state = 'AVAILABLE', affectedRows = affected }) end
    return Result.err(Codes.NPC_WORKER_OWNER_MISMATCH, 'NPC worker is not owned by this booking', { workerKey = workerKey })
end

function Repository:expireWorkers()
    local result = self._db:update(([[
        UPDATE %s w
        INNER JOIN %s p ON p.id = w.profile_id
        SET w.state = CASE
                WHEN p.profile_type = 'SEMI_PERSISTENT'
                     AND ((w.expires_at IS NOT NULL AND w.expires_at <= CURRENT_TIMESTAMP(3))
                       OR (p.expires_at IS NOT NULL AND p.expires_at <= CURRENT_TIMESTAMP(3)))
                    THEN 'EXPIRED'
                ELSE 'AVAILABLE'
            END,
            w.booking_id = NULL, w.reservation_key = NULL,
            w.hold_until = NULL, w.version = w.version + 1,
            w.updated_at = CURRENT_TIMESTAMP(3)
        WHERE (w.state = 'RESERVED' AND w.hold_until IS NOT NULL AND w.hold_until <= CURRENT_TIMESTAMP(3))
           OR (p.profile_type = 'SEMI_PERSISTENT'
             AND ((w.expires_at IS NOT NULL AND w.expires_at <= CURRENT_TIMESTAMP(3))
               OR (p.expires_at IS NOT NULL AND p.expires_at <= CURRENT_TIMESTAMP(3))))
    ]]):format(self._workerTable, self._profileTable), {})
    if type(result) ~= 'table' or not result.ok then return result end
    return Result.ok({ expired = tonumber(result.value and result.value.affectedRows) or 0 })
end

Repository.findById = Repository.findProfileById
Repository.findByKey = Repository.findProfileByKey
Repository.findAll = Repository.findProfiles
Repository.findWorkerByID = Repository.findWorkerById

NightShift.Repositories.NpcProfile = Repository
NightShift.Repositories.NPCProfile = Repository
NightShift.Repositories.NpcProfiles = Repository
