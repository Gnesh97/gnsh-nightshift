NightShift = NightShift or {}
NightShift.Validators = NightShift.Validators or {}

local V = NightShift.Validators
local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for k, v in pairs(value) do result[copy(k, seen)] = copy(v, seen) end
    return result
end

local function errorOf(code, path, message)
    local err = NightShift.Errors.create(code, message, { path = path, field = path })
    err.path, err.field = path, path
    return err
end

local function fail(code, path, message) return nil, errorOf(code, path, message) end
local function nonempty(value) return type(value) == 'string' and value:match('%S') ~= nil end
local function positiveNumber(value) return type(value) == 'number' and value > 0 end
local function positiveInteger(value) return type(value) == 'number' and value > 0 and math.floor(value) == value end

local function uniqueIds(list, path, label)
    if type(list) ~= 'table' then return fail('INVALID_CONFIG', path, label .. ' must be an array') end
    local result, seen = {}, {}
    for i, item in ipairs(list) do
        if type(item) ~= 'table' or not nonempty(item.id) then
            return fail('INVALID_CONFIG', path .. '[' .. i .. '].id', label .. ' IDs must be non-empty')
        end
        if seen[item.id] then return fail('DUPLICATE_ID', path .. '[' .. i .. '].id', 'duplicate ' .. label .. ' ID') end
        seen[item.id] = true; result[#result + 1] = copy(item)
    end
    return result, seen
end

local function locationIds(item)
    return item.locationIds or item.location_ids or item.locations
end

function V.validateConfig(input, options)
    options = options or {}; input = input or {}
    if type(input) ~= 'table' then return fail('INVALID_CONFIG', 'config', 'configuration must be a table') end
    local out = copy(input)
    local provider = input.provider or input.providerSelection or {}
    if type(provider) == 'string' then provider = { mode = 'explicit', name = provider } end
    if type(provider) ~= 'table' then return fail('INVALID_CONFIG', 'provider', 'provider selection must be a table') end
    local mode = provider.mode or 'auto'
    if not NightShift.ProviderModes[mode] then return fail('INVALID_CONFIG', 'provider.mode', 'provider mode must be auto or explicit') end
    local registry = options.registry or NightShift.ProviderRegistry
    local selected, capabilities
    if mode == 'explicit' then
        selected = provider.name or provider.provider
        if not nonempty(selected) or not registry[selected] then return fail('UNKNOWN_PROVIDER', 'provider.name', 'provider is not allowlisted') end
        capabilities = copy(registry[selected].capabilities or {})
    else
        local resolver = options.resolveProvider or options.providerResolver
        if type(resolver) ~= 'function' then return fail('PROVIDER_UNAVAILABLE', 'provider', 'auto provider detection is unavailable') end
        local ok, result = pcall(resolver, copy(registry))
        if not ok or result == nil then return fail('PROVIDER_UNAVAILABLE', 'provider', 'no supported provider was detected') end
        selected = type(result) == 'string' and result or result.name
        if not nonempty(selected) or not registry[selected] then return fail('UNKNOWN_PROVIDER', 'provider', 'detected provider is not allowlisted') end
        capabilities = copy((type(result) == 'table' and result.capabilities) or registry[selected].capabilities or {})
    end
    out.provider = { mode = mode, name = selected, capabilities = capabilities }
    local features = copy(NightShift.FeatureDefaults)
    if type(input.features) == 'table' then for key, value in pairs(input.features) do if type(features[key]) ~= 'boolean' or type(value) ~= 'boolean' then return fail('INVALID_CONFIG', 'features.' .. tostring(key), 'feature flags must be boolean') end; features[key] = value end end
    out.features = features
    local packages, packageSeen = uniqueIds(input.servicePackages or input.packages or {}, 'servicePackages', 'service package')
    if not packages then return nil, packageSeen end
    for i, package in ipairs(packages) do
        if not positiveInteger(package.price or package.priceMinor) then return fail('INVALID_PRICE', 'servicePackages[' .. i .. '].price', 'price must be a positive integer in minor units') end
        package.price = package.price or package.priceMinor
        if not positiveNumber(package.duration) then return fail('INVALID_DURATION', 'servicePackages[' .. i .. '].duration', 'duration must be positive') end
        local refs = locationIds(package)
        if refs ~= nil and type(refs) ~= 'table' then return fail('INVALID_CONFIG', 'servicePackages[' .. i .. '].locations', 'location references must be an array') end
        package.locationIds = copy(refs or {})
        if package.provider ~= nil and (not nonempty(package.provider) or not registry[package.provider]) then
            return fail('UNKNOWN_PROVIDER', 'servicePackages[' .. i .. '].provider', 'provider reference is not allowlisted')
        end
    end
    out.servicePackages = packages
    local locations, locationSeen = uniqueIds(input.locations or {}, 'locations', 'location')
    if not locations then return nil, locationSeen end
    out.locations = locations
    for i, package in ipairs(packages) do for j, id in ipairs(package.locationIds) do if not locationSeen[id] then return fail('INVALID_LOCATION_REFERENCE', 'servicePackages[' .. i .. '].locationIds[' .. j .. ']', 'location reference is not allowlisted') end end end
    local profiles, profileSeen = uniqueIds(input.npcProfiles or {}, 'npcProfiles', 'NPC profile')
    if not profiles then return nil, profileSeen end
    local forbiddenProfileFields = { model = true, ped = true, weapon = true, outfit = true, nude = true, explicit = true, sexual = true }
    for i, profile in ipairs(profiles) do
        for key in pairs(profile) do
            if forbiddenProfileFields[key] then return fail('INVALID_CONFIG', 'npcProfiles[' .. i .. '].' .. tostring(key), 'NPC profiles may contain abstract data only') end
        end
    end
    out.npcProfiles = profiles
    local function bounded(value, path, default)
        value = value == nil and default or value
        if type(value) ~= 'number' or value < 0 or value > 100 then return fail('INVALID_CONFIG', path, 'value must be between 0 and 100') end
        return value
    end
    local function range(name)
        local src = input[name] or {}; local min, err = bounded(src.min, name .. '.min', 0); if min == nil then return nil, err end
        local max; max, err = bounded(src.max, name .. '.max', 100); if max == nil then return nil, err end
        if max < min then return fail('INVALID_CONFIG', name .. '.max', 'maximum must not be below minimum') end
        local result = copy(src); result.min, result.max = min, max; return result
    end
    local demand, err = range('demand'); if not demand then return nil, err end
    local heat; heat, err = range('heat'); if not heat then return nil, err end
    out.demand, out.heat = demand, heat
    return out
end

V.copy = copy
NightShift.Config = NightShift.Config or { validate = V.validateConfig }
