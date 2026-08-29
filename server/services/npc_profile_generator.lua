NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Profile = NightShift.Domain.NpcProfile
local Enums = NightShift.Enums

local Generator = {}
Generator.__index = Generator

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function invalid(message, details)
    return Result.err(Codes.NPC_PROFILE_GENERATION_FAILED, message, details)
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    return value and value == math.floor(value) and value >= (minimum or 0) and (not maximum or value <= maximum) and value ~= math.huge and value ~= -math.huge
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function list(value, field, maximum)
    if type(value) ~= 'table' or #value == 0 then return nil, invalid(field .. ' must be a non-empty array') end
    local output, seen = {}, {}
    for index, item in ipairs(value) do
        if type(item) ~= 'string' or not text(item, maximum or 96) then return nil, invalid(field .. ' contains an invalid value', { index = index }) end
        local normalized = item
        if field:find('travel', 1, true) or field:find('role', 1, true) then normalized = item:upper() end
        if seen[normalized] then return nil, invalid(field .. ' contains a duplicate value', { index = index }) end
        seen[normalized], output[index] = true, normalized
    end
    return output
end

local function range(value, field, minimum, maximum, floating)
    if type(value) == 'number' then
        if value < minimum or value > maximum or value ~= value or value == math.huge or value == -math.huge then return nil, invalid(field .. ' is outside safe bounds') end
        return value
    end
    if type(value) ~= 'table' then return nil, invalid(field .. ' must be a bounded range') end
    local low, high = tonumber(value.min), tonumber(value.max)
    if not low or not high or low > high or low < minimum or high > maximum then return nil, invalid(field .. ' range is invalid') end
    if not floating and (low ~= math.floor(low) or high ~= math.floor(high)) then return nil, invalid(field .. ' range must be integral') end
    return { min = low, max = high }
end

local function seedHash(value)
    value = tostring(value or '')
    local hash = 2166136261
    for index = 1, #value do
        hash = (hash ~ value:byte(index)) * 16777619
        hash = hash % 2147483647
    end
    return hash
end

local function choose(seed, index, values)
    return values[(seedHash(seed .. ':' .. tostring(index)) % #values) + 1]
end

local function chooseRange(seed, index, value, floating)
    if type(value) == 'number' then return value end
    local low, high = value.min, value.max
    if floating then
        local bucket = seedHash(seed .. ':' .. tostring(index)) % (math.floor((high - low) * 100) + 1)
        return math.floor((low * 100) + bucket + 0.5) / 100
    end
    return low + (seedHash(seed .. ':' .. tostring(index)) % (high - low + 1))
end

local function safeKey(role, seed)
    local value = tostring(seed):lower():gsub('[^a-z0-9_.:%-]', '-'):gsub('%-+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
    if value == '' then value = tostring(seedHash(seed)) end
    return 'npc:' .. tostring(role):lower() .. ':' .. value:sub(1, 80)
end

local function normalizeTemplate(template, index)
    if type(template) ~= 'table' then return nil, invalid('NPC template must be a table', { index = index }) end
    local id = template.id or template.key
    if not token(id, 96) then return nil, invalid('NPC template ID is invalid', { index = index }) end
    local role = type(template.role) == 'string' and template.role:upper() or nil
    if not role or not Enums.NpcRoles[role] then return nil, invalid('NPC template role is invalid', { index = index }) end
    local profileType = template.profileType or template.profile_type or 'SEMI_PERSISTENT'
    profileType = type(profileType) == 'string' and profileType:upper() or nil
    if not profileType or not Enums.NpcProfileTypes[profileType] then return nil, invalid('NPC template profile type is invalid', { index = index }) end
    local weight = tonumber(template.weight or 1)
    if not weight or weight <= 0 or weight ~= weight or weight == math.huge then return nil, invalid('NPC template weight is invalid', { index = index }) end
    local aliases, aliasError = list(template.aliases or template.names, 'template.aliases', 80)
    if not aliases then return nil, aliasError end
    local districts, districtError = list(template.districts or { 'unknown' }, 'template.districts', 64)
    if not districts then return nil, districtError end
    local travelModes = template.travelModes or template.travel_modes or { 'UNKNOWN' }
    local travelError
    travelModes, travelError = list(travelModes, 'template.travelModes', 24)
    if not travelModes then return nil, travelError end
    for modeIndex, mode in ipairs(travelModes) do
        if not Enums.NpcTravelModes[mode] then return nil, invalid('NPC template travel mode is invalid', { index = index, mode = modeIndex }) end
    end
    local priceClass, priceError = range(template.priceClass or template.price_class or template.budgetClass or template.budget_class or { min = 1, max = 1 }, 'template.priceClass', 1, 5, false)
    if not priceClass then return nil, priceError end
    local budgetClass, budgetError = range(template.budgetClass or template.budget_class or { min = 1, max = 5 }, 'template.budgetClass', 1, 5, false)
    if not budgetClass then return nil, budgetError end
    local rating, ratingError = range(template.rating or { min = 0, max = 5 }, 'template.rating', 0, 5, true)
    if not rating then return nil, ratingError end
    local traits = {}
    for _, name in ipairs({ 'reliability', 'discretion', 'patience', 'negotiation' }) do
        local value, errorResult = range(template.traits and template.traits[name] or { min = 0, max = 100 }, 'template.traits.' .. name, 0, 100, false)
        if not value then return nil, errorResult end
        traits[name] = value
    end
    local appearance = template.appearanceProfileRefs or template.appearance_profile_refs
    if appearance ~= nil then
        local appearanceError
        appearance, appearanceError = list(appearance, 'template.appearanceProfileRefs', 96)
        if not appearance then return nil, appearanceError end
    end
    local tags = template.tags or {}
    if type(tags) ~= 'table' then return nil, invalid('NPC template tags must be an array', { index = index }) end
    return {
        id = tostring(id),
        role = role,
        profileType = profileType,
        weight = weight,
        aliases = aliases,
        appearanceProfileRefs = appearance,
        priceClass = priceClass,
        budgetClass = budgetClass,
        rating = rating,
        traits = traits,
        districts = districts,
        travelModes = travelModes,
        tags = copy(tags)
    }
end

local function normalizeConfig(config)
    if config == nil then config = NightShift.NpcProfileConfig end
    if type(config) ~= 'table' then return nil, invalid('NPC profile generator config must be a table') end
    local templates = config.templates or {}
    if type(templates) ~= 'table' or #templates == 0 then return nil, invalid('NPC profile generator requires templates') end
    local normalized, seen = {}, {}
    for index, template in ipairs(templates) do
        local value, errorResult = normalizeTemplate(template, index)
        if not value then return nil, errorResult end
        if seen[value.id] then return nil, invalid('NPC template IDs must be unique', { id = value.id }) end
        seen[value.id] = true
        normalized[index] = value
    end
    local promotion = config.promotion or {}
    local threshold = tonumber(promotion.completedBookings or promotion.completed_bookings or 3)
    if not integer(threshold, 1, 2147483647) then return nil, invalid('NPC promotion threshold is invalid') end
    local ttl = tonumber(config.semiPersistentTtl or config.semi_persistent_ttl or 1800)
    if not integer(ttl, 1, 604800) then return nil, invalid('NPC semi-persistent TTL is invalid') end
    local pool = config.workerPool or config.worker_pool or {}
    if type(pool) ~= 'table' then return nil, invalid('NPC worker pool config must be a table') end
    local targetSize = tonumber(pool.targetSize or pool.target_size or 5)
    local maxSize = tonumber(pool.maxSize or pool.max_size or 50)
    local reservationTtl = tonumber(pool.reservationTtl or pool.reservation_ttl or 300)
    if not integer(targetSize, 1, 1000) or not integer(maxSize, 1, 1000) or targetSize > maxSize then
        return nil, invalid('NPC worker pool size is invalid')
    end
    if not integer(reservationTtl, 1, 86400) then return nil, invalid('NPC worker reservation TTL is invalid') end
    return {
        enabled = config.enabled ~= false,
        seed = tostring(config.seed or 'nightshift-default'),
        templates = normalized,
        promotion = { completedBookings = threshold },
        semiPersistentTtl = ttl,
        workerPool = {
            targetSize = targetSize,
            maxSize = maxSize,
            reservationTtl = reservationTtl
        }
    }
end

local function selectTemplate(templates, role, seed)
    local candidates, total = {}, 0
    for _, template in ipairs(templates) do
        if template.role == role then
            candidates[#candidates + 1] = template
            total = total + template.weight
        end
    end
    if #candidates == 0 then return nil end
    local bucket = (seedHash(seed .. ':template') % math.max(1, math.floor(total * 100))) / 100
    local cursor = 0
    for _, template in ipairs(candidates) do
        cursor = cursor + template.weight
        if bucket < cursor then return template end
    end
    return candidates[#candidates]
end

function Generator.new(options)
    options = options or {}
    local config, errorResult = normalizeConfig(options.config)
    if not config then return nil, errorResult end
    return setmetatable({
        _config = config,
        _clock = options.clock,
        _repository = options.repository or options.npcProfileRepository,
        _generated = {},
        _aliases = {}
    }, Generator)
end

function Generator:generate(input)
    input = input or {}
    if type(input) ~= 'table' then return invalid('NPC profile generation input must be a table') end
    local role = type(input.role) == 'string' and input.role:upper() or 'WORKER'
    if not Enums.NpcRoles[role] then return invalid('NPC generation role is invalid') end
    local seed = input.seed or input.generationSeed or self._config.seed
    if not text(tostring(seed), 96) then return invalid('NPC generation seed is invalid') end
    seed = tostring(seed)
    local profileKey = input.profileKey or input.profile_key or safeKey(role, seed)
    if not token(profileKey, 96) then return invalid('NPC generated profile key is invalid') end
    if self._generated[profileKey] then return Result.ok(copy(self._generated[profileKey]), { generated = false, idempotent = true }) end
    local template = selectTemplate(self._config.templates, role, seed)
    if not template then return invalid('no NPC template is configured for the requested role', { role = role }) end
    local alias = choose(seed, 'alias', template.aliases)
    local aliasKey, aliasNumber = alias:lower(), 1
    while self._aliases[aliasKey] and self._aliases[aliasKey] ~= profileKey do
        aliasNumber = aliasNumber + 1
        aliasKey = alias:lower() .. '-' .. tostring(aliasNumber)
    end
    if aliasNumber > 1 then alias = alias .. '-' .. tostring(aliasNumber) end
    self._aliases[aliasKey] = profileKey
    local appearance = template.appearanceProfileRefs and choose(seed, 'appearance', template.appearanceProfileRefs) or nil
    local district = choose(seed, 'district', template.districts)
    local travelMode = choose(seed, 'travel', template.travelModes)
    local traits = {}
    for _, name in ipairs({ 'reliability', 'discretion', 'patience', 'negotiation' }) do
        traits[name] = chooseRange(seed, 'trait:' .. name, template.traits[name], false)
    end
    local profileType = input.profileType or template.profileType
    profileType = type(profileType) == 'string' and profileType:upper() or profileType
    local completedBookings = tonumber(input.completedBookings or input.completed_bookings or 0) or 0
    if completedBookings >= self._config.promotion.completedBookings then profileType = 'PERSISTENT' end
    local expiresAt = input.expiresAt or input.expires_at
    if profileType == 'SEMI_PERSISTENT' and expiresAt == nil then
        local at = self._clock and type(self._clock.now) == 'function' and tonumber(self._clock:now()) or os.time()
        expiresAt = at + self._config.semiPersistentTtl
    end
    if profileType == 'PERSISTENT' then expiresAt = nil end
    local profile, profileError = Profile.new({
        profileKey = profileKey,
        role = role,
        profileType = profileType,
        alias = alias,
        appearanceProfileRef = input.appearanceProfileRef or input.appearance_profile_ref or appearance,
        budgetClass = input.budgetClass or input.budget_class or chooseRange(seed, 'budget', template.budgetClass, false),
        priceClass = input.priceClass or input.price_class or chooseRange(seed, 'price', template.priceClass, false),
        rating = input.rating == nil and chooseRange(seed, 'rating', template.rating, true) or input.rating,
        traits = traits,
        tags = input.tags or template.tags,
        homeDistrict = input.homeDistrict or input.home_district or district,
        activeDistrict = input.activeDistrict or input.active_district or district,
        availability = input.availability or 'AVAILABLE',
        travelMode = input.travelMode or input.travel_mode or travelMode,
        generationSeed = seed,
        completedBookings = completedBookings,
        cancelledBookings = input.cancelledBookings or input.cancelled_bookings or 0,
        noShowBookings = input.noShowBookings or input.no_show_bookings or 0,
        expiresAt = expiresAt
    })
    if not profile then return profileError end
    self._generated[profileKey] = profile
    return Result.ok(copy(profile), { generated = true, template = template.id, seed = seed })
end

function Generator:generateMany(count, input)
    count = tonumber(count)
    if not integer(count, 1, 1000) then return invalid('NPC generation count is invalid') end
    input = copy(input or {})
    local values = {}
    for index = 1, count do
        local nextInput = copy(input)
        nextInput.seed = tostring(input.seed or self._config.seed) .. ':' .. tostring(index)
        nextInput.profileKey = input.profileKey and (tostring(input.profileKey) .. ':' .. tostring(index)) or nil
        local generated, errorResult = self:generate(nextInput)
        if not generated then return errorResult end
        values[index] = generated.value
    end
    return Result.ok(values, { count = count })
end

function Generator:promote(profile, reason)
    local promoted, errorResult = Profile.apply(profile, { profileType = 'PERSISTENT', expiresAt = nil })
    if not promoted then return errorResult end
    if promoted.profileKey then self._generated[promoted.profileKey] = promoted end
    return Result.ok(promoted, { reason = reason or 'promotion' })
end

Generator.validateConfig = normalizeConfig
NightShift.NpcProfileGenerator = Generator
NightShift.Services = NightShift.Services or {}
NightShift.Services.NpcProfileGenerator = Generator
