NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Enums = NightShift.Enums

local Profile = {}
Profile.__index = Profile

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    local metatable = getmetatable(value)
    if metatable ~= nil then setmetatable(output, metatable) end
    return output
end

local function invalid(message, details)
    return Result.err(Codes.NPC_PROFILE_INVALID, message, details)
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    return value and finite(value) and value == math.floor(value) and value >= (minimum or 0) and (not maximum or value <= maximum) and value
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function enum(value, values, default)
    if value == nil then value = default end
    value = type(value) == 'string' and value:upper() or nil
    return value and values[value] and value or nil
end

local function safeAlias(value, fallback)
    value = tostring(value or fallback or 'NPC'):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    value = value:gsub("[^%w%s%._%-']", ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then value = 'NPC' end
    return value:sub(1, 80)
end

local function safeDistrict(value, fallback)
    value = value == nil and fallback or value
    if value == nil then return 'unknown' end
    value = tostring(value):lower()
    return token(value, 64) and value or nil
end

local function timestamp(value)
    if value == nil then return nil end
    if finite(tonumber(value)) then return tonumber(value) end
    if text(tostring(value), 64) then return tostring(value) end
    return nil
end

local function normalizeTags(raw)
    if raw == nil then return {} end
    if type(raw) ~= 'table' or #raw ~= (function()
        local count = 0
        for key in pairs(raw) do
            if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then return -1 end
            count = count + 1
        end
        return count
    end)() then return nil end
    local output, seen = {}, {}
    for index, value in ipairs(raw) do
        value = type(value) == 'string' and value:upper() or nil
        if not token(value, 64) or seen[value] then return nil end
        seen[value], output[index] = true, value
    end
    return output
end

local function normalizeTraits(raw)
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return nil end
    local output = {
        reliability = 0,
        discretion = 0,
        patience = 0,
        negotiation = 0
    }
    local allowed = { reliability = true, discretion = true, patience = true, negotiation = true }
    for key, value in pairs(raw) do
        if not allowed[key] then return nil end
        value = integer(value, 0, 100)
        if value == nil then return nil end
        output[key] = value
    end
    return output
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, invalid('NPC profile must be a table') end
    local profileKey = values.profileKey or values.profile_key or values.workerId or values.worker_id or values.npcId or values.npc_id
    if not token(profileKey, 96) then return nil, invalid('NPC profile key is invalid') end
    profileKey = tostring(profileKey)
    local role = enum(values.role or values.profileRole, Enums.NpcRoles, 'WORKER')
    if not role then return nil, invalid('NPC profile role is invalid') end
    local profileType = enum(values.profileType or values.profile_type, Enums.NpcProfileTypes, 'SEMI_PERSISTENT')
    if not profileType then return nil, invalid('NPC profile persistence type is invalid') end
    local id = values.id
    if id ~= nil and integer(id, 1) == nil then return nil, invalid('NPC profile ID is invalid') end
    local alias = safeAlias(values.alias or values.displayName or values.display_name, profileKey)
    if #alias > 80 then return nil, invalid('NPC profile alias is too long') end
    local appearance = values.appearanceProfileRef or values.appearance_profile_ref
    if appearance ~= nil and not token(appearance, 96) then return nil, invalid('NPC appearance profile reference is invalid') end
    local budgetClass = integer(values.budgetClass or values.budget_class or 1, 1, 5)
    local priceClass = integer(values.priceClass or values.price_class or 1, 1, 5)
    if not budgetClass or not priceClass then return nil, invalid('NPC budget or price class is invalid') end
    local rating = values.rating == nil and 0 or tonumber(values.rating)
    if not finite(rating) or rating < 0 or rating > 5 then return nil, invalid('NPC profile rating is invalid') end
    rating = math.floor(rating * 100 + 0.5) / 100
    local traits = normalizeTraits(values.traits)
    if not traits then return nil, invalid('NPC profile traits are invalid') end
    local tags = normalizeTags(values.tags)
    if not tags then return nil, invalid('NPC profile tags are invalid') end
    local homeDistrict = safeDistrict(values.homeDistrict or values.home_district)
    local activeDistrict = safeDistrict(values.activeDistrict or values.active_district, homeDistrict)
    if not homeDistrict or not activeDistrict then return nil, invalid('NPC profile district is invalid') end
    local availability = enum(values.availability, Enums.NpcAvailability, 'AVAILABLE')
    if not availability then return nil, invalid('NPC profile availability is invalid') end
    local travelMode = enum(values.travelMode or values.travel_mode, Enums.NpcTravelModes, 'UNKNOWN')
    if not travelMode then return nil, invalid('NPC profile travel mode is invalid') end
    local generationSeed = values.generationSeed or values.generation_seed
    if generationSeed ~= nil and not text(tostring(generationSeed), 96) then return nil, invalid('NPC profile generation seed is invalid') end
    generationSeed = generationSeed == nil and nil or tostring(generationSeed)
    local counters = {
        completedBookings = values.completedBookings or values.completed_bookings or 0,
        cancelledBookings = values.cancelledBookings or values.cancelled_bookings or 0,
        noShowBookings = values.noShowBookings or values.no_show_bookings or 0
    }
    for key, value in pairs(counters) do
        value = integer(value, 0, 2147483647)
        if value == nil then return nil, invalid('NPC profile counters are invalid', { field = key }) end
        counters[key] = value
    end
    local version = integer(values.version or 1, 1)
    if not version then return nil, invalid('NPC profile version is invalid') end
    local createdAt = timestamp(values.createdAt or values.created_at)
    local updatedAt = timestamp(values.updatedAt or values.updated_at)
    local lastActiveAt = timestamp(values.lastActiveAt or values.last_active_at)
    local expiresAt = timestamp(values.expiresAt or values.expires_at)
    if (values.createdAt ~= nil or values.created_at ~= nil) and createdAt == nil then return nil, invalid('NPC profile created timestamp is invalid') end
    if (values.updatedAt ~= nil or values.updated_at ~= nil) and updatedAt == nil then return nil, invalid('NPC profile updated timestamp is invalid') end
    if (values.lastActiveAt ~= nil or values.last_active_at ~= nil) and lastActiveAt == nil then return nil, invalid('NPC profile last active timestamp is invalid') end
    if (values.expiresAt ~= nil or values.expires_at ~= nil) and expiresAt == nil then return nil, invalid('NPC profile expiry timestamp is invalid') end
    return {
        id = id,
        profileKey = profileKey,
        key = profileKey,
        role = role,
        profileType = profileType,
        alias = alias,
        displayName = alias,
        appearanceProfileRef = appearance,
        budgetClass = budgetClass,
        priceClass = priceClass,
        rating = rating,
        traits = traits,
        tags = tags,
        homeDistrict = homeDistrict,
        activeDistrict = activeDistrict,
        availability = availability,
        travelMode = travelMode,
        generationSeed = generationSeed,
        completedBookings = counters.completedBookings,
        cancelledBookings = counters.cancelledBookings,
        noShowBookings = counters.noShowBookings,
        version = version,
        createdAt = createdAt,
        updatedAt = updatedAt,
        lastActiveAt = lastActiveAt,
        expiresAt = expiresAt
    }
end

function Profile.new(values)
    local normalized, errorResult = normalize(values)
    if not normalized then return nil, errorResult end
    return setmetatable(normalized, Profile)
end

function Profile.fromRow(row)
    if type(row) ~= 'table' then return nil, invalid('NPC profile row must be a table') end
    return Profile.new(row)
end

function Profile.validate(values)
    local normalized, errorResult = normalize(values)
    return normalized ~= nil, errorResult
end

function Profile.copy(profile)
    return copy(profile)
end

function Profile.apply(profile, changes)
    if type(profile) ~= 'table' or type(changes) ~= 'table' then return nil, invalid('NPC profile changes must be tables') end
    local merged = copy(profile)
    local aliases = {
        alias = 'alias', displayName = 'alias', display_name = 'alias',
        appearanceProfileRef = 'appearanceProfileRef', appearance_profile_ref = 'appearanceProfileRef',
        budgetClass = 'budgetClass', budget_class = 'budgetClass',
        priceClass = 'priceClass', price_class = 'priceClass',
        rating = 'rating', traits = 'traits', tags = 'tags',
        homeDistrict = 'homeDistrict', home_district = 'homeDistrict',
        activeDistrict = 'activeDistrict', active_district = 'activeDistrict',
        availability = 'availability', travelMode = 'travelMode', travel_mode = 'travelMode',
        completedBookings = 'completedBookings', completed_bookings = 'completedBookings',
        cancelledBookings = 'cancelledBookings', cancelled_bookings = 'cancelledBookings',
        noShowBookings = 'noShowBookings', no_show_bookings = 'noShowBookings',
        lastActiveAt = 'lastActiveAt', last_active_at = 'lastActiveAt',
        expiresAt = 'expiresAt', expires_at = 'expiresAt',
        profileType = 'profileType', profile_type = 'profileType'
    }
    for key, value in pairs(changes) do
        local field = aliases[key]
        if not field then return nil, invalid('NPC profile field is not mutable', { field = tostring(key) }) end
        merged[field] = value
    end
    return Profile.new(merged)
end

function Profile.toRow(profile)
    local value, errorResult = Profile.new(profile)
    if not value then return nil, errorResult end
    return {
        profile_key = value.profileKey,
        role = value.role,
        profile_type = value.profileType,
        display_name = value.alias,
        appearance_profile_ref = value.appearanceProfileRef,
        budget_class = value.budgetClass,
        price_class = value.priceClass,
        rating = value.rating,
        availability = value.availability,
        traits = copy(value.traits),
        tags = copy(value.tags),
        home_district = value.homeDistrict,
        active_district = value.activeDistrict,
        travel_mode = value.travelMode,
        generation_seed = value.generationSeed,
        completed_bookings = value.completedBookings,
        cancelled_bookings = value.cancelledBookings,
        no_show_bookings = value.noShowBookings,
        last_active_at = value.lastActiveAt,
        expires_at = value.expiresAt
    }
end

function Profile.isExpired(profile, at)
    if type(profile) ~= 'table' or profile.profileType == 'PERSISTENT' or profile.expiresAt == nil then return false end
    at = tonumber(at) or os.time()
    return type(profile.expiresAt) == 'number' and profile.expiresAt <= at
end

NightShift.Domain.NpcProfile = Profile
NightShift.NpcProfile = Profile
