NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.Repositories.Base
local Domain = NightShift.Domain.ClientProfile

local Repository = {}
Repository.__index = Repository

local columns = {
    'id', 'player_identifier', 'character_id', 'display_name', 'locale',
    'completed_bookings', 'cancelled_bookings', 'no_show_bookings', 'rating', 'tier',
    'deposit_risk_score', 'deposit_risk_reason', 'last_active_at', 'version', 'created_at', 'updated_at'
}

local mutable = {
    alias = 'display_name', displayName = 'display_name', locale = 'locale',
    completedBookings = 'completed_bookings', completed_bookings = 'completed_bookings',
    cancelledBookings = 'cancelled_bookings', cancelled_bookings = 'cancelled_bookings',
    noShowBookings = 'no_show_bookings', no_show_bookings = 'no_show_bookings',
    rating = 'rating', tier = 'tier',
    depositRiskScore = 'deposit_risk_score', deposit_risk_score = 'deposit_risk_score',
    depositRiskReason = 'deposit_risk_reason', deposit_risk_reason = 'deposit_risk_reason',
    lastActiveAt = 'last_active_at', last_active_at = 'last_active_at'
}

local function text(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function identityValid(identifier, characterId)
    return text(identifier) and #identifier <= 128 and (characterId == nil or (text(characterId) and #characterId <= 128))
end

function Repository.new(options)
    options = options or {}
    local database = options.db or options.databaseAdapter
    if type(database) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'client profile repository requires a database adapter') end
    local base, err = Base.new({ db = database, tableName = options.tableName or 'nightshift_client_profiles', columns = columns, mapper = function(row)
        local profile, profileError = Domain.fromRow(row)
        if not profile then return Result.err(Codes.MAPPING_FAILED, 'client profile row is invalid', { cause = profileError and profileError.error and profileError.error.code }) end
        return profile
    end })
    if not base then return nil, err end
    return setmetatable({ _base = base, _db = database, _table = options.tableName or 'nightshift_client_profiles' }, Repository)
end

function Repository:findById(id)
    return self._base:findById(id)
end

function Repository:findAll(options)
    return self._base:findAll(options)
end

function Repository:findByIdentity(identifier, characterId)
    if not identityValid(identifier, characterId) then return invalid('client profile identity is invalid') end
    local selectList, selectError = self._base:_selectList()
    if not selectList then return selectError end
    local sql = ('SELECT %s FROM `%s` WHERE `player_identifier` = ? AND `character_id` <=> ? LIMIT 1'):format(selectList, self._table)
    local result = self._db:single(sql, { identifier, characterId })
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'client profile was not found', { playerIdentifier = identifier, characterId = characterId }) end
    local profile, mapResult = self._base:_map(result.value)
    if not profile then return mapResult end
    return Result.ok(profile, { playerIdentifier = identifier, characterId = characterId })
end

function Repository:create(profile)
    local row, err = Domain.toRow(profile)
    if not row then return err end
    return self._base:create(row)
end

function Repository:updateExpectedVersion(id, expectedVersion, changes)
    if type(changes) ~= 'table' then return invalid('client profile changes must be a table') end
    local mapped, seen = {}, {}
    for key, value in pairs(changes) do
        local field = mutable[key]
        if not field then return invalid('client profile field is not mutable', { field = tostring(key) }) end
        if seen[field] then return invalid('client profile field was supplied more than once', { field = field }) end
        seen[field] = true
        mapped[field] = value
    end
    return self._base:updateExpectedVersion(id, expectedVersion, mapped)
end

Repository.update = Repository.updateExpectedVersion
Repository.findByID = Repository.findById
Repository.findByPlayerIdentity = Repository.findByIdentity
NightShift.Repositories.ClientProfile = Repository
NightShift.Repositories.ClientProfiles = Repository
