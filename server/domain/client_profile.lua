NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local ClientProfile = {}
ClientProfile.__index = ClientProfile

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function cleanText(value, maxLength)
    if value == nil then return nil end
    value = tostring(value):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' or #value > maxLength or value:find('%z') then return nil end
    return value
end

local function alias(value, fallback)
    value = cleanText(value or fallback or 'Player', 80) or 'Player'
    value = value:gsub("[^%w%s%._%-']", ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return value ~= '' and value:sub(1, 80) or 'Player'
end

local function integer(value, default)
    value = value == nil and default or tonumber(value)
    return value and value >= 0 and value == math.floor(value) and value <= 2147483647 and value ~= math.huge and value ~= -math.huge and value
end

local function score(value, default)
    value = value == nil and default or tonumber(value)
    return value and value >= 0 and value <= 100 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge and value
end

local function rating(value)
    if value == nil then return 0 end
    value = tonumber(value)
    if not value or value < 0 or value > 5 or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

local function profileError(message, details)
    return Result.err(Codes.PROFILE_INVALID, message, details)
end

local function makeIdentityKey(identifier, characterId)
    if NightShift.IdentityService and type(NightShift.IdentityService.makeKey) == 'function' then
        return NightShift.IdentityService.makeKey(identifier, characterId)
    end
    local character = characterId or ''
    return ('%d:%s|%d:%s'):format(#identifier, identifier, #character, character)
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, profileError('client profile must be a table') end
    local identifier = cleanText(values.playerIdentifier or values.player_identifier or values.identifier, 128)
    if not identifier then return nil, profileError('client profile requires a persistent player identifier') end
    local characterId = cleanText(values.characterId or values.character_id, 128)
    local identity = values.identityKey or values.identity_key or makeIdentityKey(identifier, characterId)
    if not text(identity) then return nil, profileError('client profile identity key is invalid') end
    local version = values.version == nil and 1 or tonumber(values.version)
    if not version or version < 1 or version ~= math.floor(version) or version == math.huge or version == -math.huge then return nil, profileError('client profile version is invalid') end
    local id = values.id
    if id ~= nil and (not integer(id) or id < 1) then return nil, profileError('client profile ID is invalid') end
    local completed = integer(values.completedBookings or values.completed_bookings, 0)
    local cancelled = integer(values.cancelledBookings or values.cancelled_bookings, 0)
    local noShows = integer(values.noShowBookings or values.no_show_bookings or values.noShows or values.no_shows, 0)
    if completed == nil or cancelled == nil or noShows == nil then return nil, profileError('client profile counters must be non-negative integers') end
    local risk = score(values.depositRiskScore or values.deposit_risk_score, 0)
    if risk == nil then return nil, profileError('client deposit risk score must be an integer from 0 to 100') end
    local reliability = score(values.reliability, 50)
    if reliability == nil then return nil, profileError('client reliability must be an integer from 0 to 100') end
    local displayName = alias(values.displayName or values.display_name or values.alias, values.characterName)
    local locale = cleanText(values.locale, 16) or 'en'
    if not locale:match('^[A-Za-z][A-Za-z0-9_%-]*$') then return nil, profileError('client profile locale is invalid') end
    local tier = cleanText(values.tier, 32) or 'standard'
    if not tier:match('^[A-Za-z0-9_%-]+$') then return nil, profileError('client profile tier is invalid') end
    local depositRiskReason = cleanText(values.depositRiskReason or values.deposit_risk_reason, 128)
    local ratingValue = rating(values.rating)
    if ratingValue == nil then return nil, profileError('client profile rating must be between 0 and 5') end
    local lastActiveAt = values.lastActiveAt or values.last_active_at
    if lastActiveAt ~= nil and not text(tostring(lastActiveAt)) then return nil, profileError('client profile last active timestamp is invalid') end
    return {
        id = id,
        identityKey = identity,
        key = identity,
        playerIdentifier = identifier,
        characterId = characterId,
        displayName = displayName,
        alias = displayName,
        locale = locale:lower(),
        completedBookings = completed,
        cancelledBookings = cancelled,
        noShowBookings = noShows,
        noShows = noShows,
        rating = ratingValue,
        reliability = reliability,
        tier = tier:lower(),
        depositRiskScore = risk,
        depositRiskReason = depositRiskReason,
        lastActiveAt = lastActiveAt,
        version = version,
        createdAt = values.createdAt or values.created_at,
        updatedAt = values.updatedAt or values.updated_at
    }
end

function ClientProfile.new(values)
    return normalize(values)
end

function ClientProfile.fromRow(row)
    return normalize(row)
end

function ClientProfile.validate(values)
    local output, err = normalize(values)
    return output ~= nil, err
end

function ClientProfile.copy(profile)
    return copy(profile)
end

function ClientProfile.apply(profile, changes)
    if type(profile) ~= 'table' or type(changes) ~= 'table' then return nil, profileError('client profile changes must be tables') end
    local merged = copy(profile)
    local fields = {
        alias = 'displayName', displayName = 'displayName',
        locale = 'locale', completedBookings = 'completedBookings', completed_bookings = 'completedBookings',
        cancelledBookings = 'cancelledBookings', cancelled_bookings = 'cancelledBookings',
        noShowBookings = 'noShowBookings', no_show_bookings = 'noShowBookings', noShows = 'noShowBookings', no_shows = 'noShowBookings',
        rating = 'rating', tier = 'tier', depositRiskScore = 'depositRiskScore',
        reliability = 'reliability',
        deposit_risk_score = 'depositRiskScore', depositRiskReason = 'depositRiskReason',
        deposit_risk_reason = 'depositRiskReason', lastActiveAt = 'lastActiveAt', last_active_at = 'lastActiveAt'
    }
    for key, value in pairs(changes) do
        local field = fields[key]
        if not field then return nil, profileError('client profile field is not mutable', { field = tostring(key) }) end
        merged[field] = value
    end
    return normalize(merged)
end

function ClientProfile.toRow(profile)
    local value, err = normalize(profile)
    if not value then return nil, err end
    local row = {
        player_identifier = value.playerIdentifier,
        display_name = value.displayName,
        locale = value.locale,
        completed_bookings = value.completedBookings,
        cancelled_bookings = value.cancelledBookings,
        no_show_bookings = value.noShowBookings,
        rating = value.rating,
        reliability = value.reliability,
        tier = value.tier,
        deposit_risk_score = value.depositRiskScore
    }
    if value.characterId ~= nil then row.character_id = value.characterId end
    if value.depositRiskReason ~= nil then row.deposit_risk_reason = value.depositRiskReason end
    if value.lastActiveAt ~= nil then row.last_active_at = value.lastActiveAt end
    return row
end

NightShift.Domain.ClientProfile = ClientProfile
NightShift.ClientProfile = ClientProfile
