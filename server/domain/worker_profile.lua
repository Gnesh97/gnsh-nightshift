NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local WorkerProfile = {}
WorkerProfile.__index = WorkerProfile

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

local function positiveInteger(value, maximum)
    value = tonumber(value)
    return value and value >= 0 and value == math.floor(value) and value ~= math.huge and value ~= -math.huge and (not maximum or value <= maximum)
end

local function trait(value, default)
    if value == nil then return default end
    value = tonumber(value)
    if not value or value < 0 or value > 100 or value ~= math.floor(value) then return nil end
    return value
end

local function profileError(message, details)
    return Result.err(Codes.PROFILE_INVALID, message, details)
end

local function normalizedAvailability(value)
    value = value == nil and 'offline' or tostring(value):lower()
    local allowed = { offline = true, available = true, busy = true, away = true }
    return allowed[value] and value or nil
end

local function makeIdentityKey(identifier, characterId)
    if NightShift.IdentityService and type(NightShift.IdentityService.makeKey) == 'function' then
        return NightShift.IdentityService.makeKey(identifier, characterId)
    end
    local character = characterId or ''
    return ('%d:%s|%d:%s'):format(#identifier, identifier, #character, character)
end

local function normalize(values)
    if type(values) ~= 'table' then return nil, profileError('worker profile must be a table') end
    local identifier = cleanText(values.playerIdentifier or values.player_identifier or values.identifier, 128)
    if not identifier then return nil, profileError('worker profile requires a persistent player identifier') end
    local characterId = cleanText(values.characterId or values.character_id, 128)
    local identity = values.identityKey or values.identity_key or makeIdentityKey(identifier, characterId)
    if not text(identity) then return nil, profileError('worker profile identity key is invalid') end
    local version = values.version == nil and 1 or tonumber(values.version)
    if not positiveInteger(version) or version < 1 then return nil, profileError('worker profile version is invalid') end
    local id = values.id
    if id ~= nil and (not positiveInteger(id) or id < 1) then return nil, profileError('worker profile ID is invalid') end
    local availability = normalizedAvailability(values.availability)
    if not availability then return nil, profileError('worker profile availability is invalid') end
    local professionalism = trait(values.professionalism, 0)
    local discretion = trait(values.discretion, 0)
    local reliability = trait(values.reliability, 0)
    if professionalism == nil or discretion == nil or reliability == nil then return nil, profileError('worker profile traits must be integers from 0 to 100') end
    local counters = {
        completedBookings = values.completedBookings or values.completed_bookings or values.bookingsCompleted,
        cancelledBookings = values.cancelledBookings or values.cancelled_bookings or values.bookingsCancelled,
        noShowBookings = values.noShowBookings or values.no_show_bookings or values.noShows or values.no_shows
    }
    for _, name in ipairs({ 'completedBookings', 'cancelledBookings', 'noShowBookings' }) do
        local value = counters[name]
        value = value == nil and 0 or value
        if not positiveInteger(value, 2147483647) then return nil, profileError('worker profile counters must be non-negative integers', { field = name }) end
        counters[name] = value
    end
    local displayName = alias(values.displayName or values.display_name or values.alias, values.characterName)
    local jobName = cleanText(values.jobName or values.job_name, 64)
    local lastActiveAt = values.lastActiveAt or values.last_active_at
    if lastActiveAt ~= nil and not text(tostring(lastActiveAt)) then return nil, profileError('worker profile last active timestamp is invalid') end
    local output = {
        id = id,
        identityKey = identity,
        key = identity,
        playerIdentifier = identifier,
        characterId = characterId,
        displayName = displayName,
        alias = displayName,
        jobName = jobName,
        availability = availability,
        professionalism = professionalism,
        discretion = discretion,
        reliability = reliability,
        completedBookings = counters.completedBookings,
        cancelledBookings = counters.cancelledBookings,
        noShowBookings = counters.noShowBookings,
        noShows = counters.noShowBookings,
        lastActiveAt = lastActiveAt,
        version = version,
        createdAt = values.createdAt or values.created_at,
        updatedAt = values.updatedAt or values.updated_at
    }
    return output
end

function WorkerProfile.new(values)
    return normalize(values)
end

function WorkerProfile.fromRow(row)
    return normalize(row)
end

function WorkerProfile.validate(values)
    local output, err = normalize(values)
    return output ~= nil, err
end

function WorkerProfile.copy(profile)
    return copy(profile)
end

function WorkerProfile.apply(profile, changes)
    if type(profile) ~= 'table' or type(changes) ~= 'table' then return nil, profileError('worker profile changes must be tables') end
    local merged = copy(profile)
    local fields = {
        alias = 'displayName', displayName = 'displayName',
        job = 'jobName', jobName = 'jobName', job_name = 'jobName',
        availability = 'availability', professionalism = 'professionalism',
        discretion = 'discretion', reliability = 'reliability',
        completedBookings = 'completedBookings', completed_bookings = 'completedBookings',
        cancelledBookings = 'cancelledBookings', cancelled_bookings = 'cancelledBookings',
        noShowBookings = 'noShowBookings', no_show_bookings = 'noShowBookings', noShows = 'noShowBookings', no_shows = 'noShowBookings',
        lastActiveAt = 'lastActiveAt', last_active_at = 'lastActiveAt'
    }
    for key, value in pairs(changes) do
        local field = fields[key]
        if not field then return nil, profileError('worker profile field is not mutable', { field = tostring(key) }) end
        merged[field] = value
    end
    return normalize(merged)
end

function WorkerProfile.toRow(profile)
    local value, err = normalize(profile)
    if not value then return nil, err end
    local row = {
        player_identifier = value.playerIdentifier,
        display_name = value.displayName,
        availability = value.availability,
        professionalism = value.professionalism,
        discretion = value.discretion,
        reliability = value.reliability,
        completed_bookings = value.completedBookings,
        cancelled_bookings = value.cancelledBookings,
        no_show_bookings = value.noShowBookings
    }
    if value.characterId ~= nil then row.character_id = value.characterId end
    if value.jobName ~= nil then row.job_name = value.jobName end
    if value.lastActiveAt ~= nil then row.last_active_at = value.lastActiveAt end
    return row
end

NightShift.Domain.WorkerProfile = WorkerProfile
NightShift.WorkerProfile = WorkerProfile
