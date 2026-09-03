NightShift = NightShift or {}
NightShift.Network = NightShift.Network or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Policy = {}
Policy.__index = Policy

local orderedKeys = {
    'nightshift:npcId', 'nightshift:bookingId', 'nightshift:generation',
    'nightshift:generationToken', 'nightshift:entityState'
}

local keySet = {}
for _, key in ipairs(orderedKeys) do keySet[key] = true end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function finite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not finite(value) or value ~= math.floor(value) then return nil end
    if minimum ~= nil and value < minimum then return nil end
    if maximum ~= nil and value > maximum then return nil end
    return math.floor(value)
end

local function token(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= (maximum or 160)
        and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function entity(value)
    if integer(value, 1, 2147483647) then return tonumber(value) end
    if token(value, 96) then return value end
    return nil
end

local function invalid(code, message, details)
    return Result.err(Codes[code] or code, message, details)
end

local function normalizedValue(key, value)
    if key == 'nightshift:generation' then return integer(value, 1, 2147483647) end
    if key == 'nightshift:entityState' then
        local state = type(value) == 'string' and value:upper() or nil
        local states = NightShift.Enums and NightShift.Enums.NpcEntityStates or {}
        return state and states[state] == true and state or nil
    end
    return token(value, key == 'nightshift:generationToken' and 240 or 160) and value or nil
end

function Policy.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('STATE_BAG_INVALID', 'state bag policy options must be a table') end
    local config = type(options.config) == 'table' and options.config or {}
    local function configured(name, fallback)
        return config[name] == nil and fallback or config[name]
    end
    local maxKeys = integer(configured('maxKeys', 5), 1, #orderedKeys)
    local maxBytes = integer(configured('maxBytes', 512), 64, 4096)
    if not maxKeys or not maxBytes then return nil, invalid('STATE_BAG_INVALID', 'state bag policy bounds are invalid') end
    return setmetatable({ _maxKeys = maxKeys, _maxBytes = maxBytes,
        _setState = options.setState, _getState = options.getState }, Policy)
end

function Policy:config()
    return { maxKeys = self._maxKeys, maxBytes = self._maxBytes }
end

function Policy:normalize(metadata)
    if type(metadata) ~= 'table' then return invalid('STATE_BAG_INVALID', 'state bag metadata must be a table') end
    local output, count, bytes = {}, 0, 0
    for key, value in pairs(metadata) do
        if not keySet[key] then return invalid('STATE_BAG_INVALID', 'state bag key is not allowlisted', { key = tostring(key) }) end
        if value ~= nil then
            count = count + 1
            if count > self._maxKeys then return invalid('STATE_BAG_INVALID', 'state bag metadata has too many keys') end
            local normalized = normalizedValue(key, value)
            if normalized == nil then return invalid('STATE_BAG_INVALID', 'state bag value is invalid', { key = key }) end
            output[key] = normalized
            bytes = bytes + #key + #tostring(normalized)
            if bytes > self._maxBytes then return invalid('STATE_BAG_INVALID', 'state bag metadata exceeds the byte budget') end
        end
    end
    return Result.ok(output)
end

function Policy:fromLogical(binding)
    if type(binding) ~= 'table' then return invalid('STATE_BAG_INVALID', 'logical entity binding must be a table') end
    local metadata = {
        ['nightshift:npcId'] = binding.profileKey or binding.npcId,
        ['nightshift:bookingId'] = binding.bookingId,
        ['nightshift:generation'] = binding.generation,
        ['nightshift:generationToken'] = binding.generationToken,
        ['nightshift:entityState'] = binding.state
    }
    return self:normalize(metadata)
end

function Policy:write(entityHandle, metadata, setter)
    entityHandle = entity(entityHandle)
    if not entityHandle then return invalid('STATE_BAG_INVALID', 'state bag entity handle is invalid') end
    local normalized = self:normalize(metadata)
    if not normalized.ok then return normalized end
    setter = setter or self._setState
    if type(setter) ~= 'function' then return invalid('STATE_BAG_UNAVAILABLE', 'state bag writer is unavailable') end
    local written = {}
    for _, key in ipairs(orderedKeys) do
        local value = normalized.value[key]
        if value ~= nil then
            local ok, result = pcall(setter, entityHandle, key, value, true)
            if not ok or result == false then
                return invalid('STATE_BAG_WRITE_FAILED', 'state bag write failed', { key = key, written = written })
            end
            written[#written + 1] = key
        end
    end
    return Result.ok({ entity = entityHandle, keys = written, metadata = copy(normalized.value) })
end

function Policy:read(entityHandle, getter)
    entityHandle = entity(entityHandle)
    if not entityHandle then return invalid('STATE_BAG_INVALID', 'state bag entity handle is invalid') end
    getter = getter or self._getState
    if type(getter) ~= 'function' then return invalid('STATE_BAG_UNAVAILABLE', 'state bag reader is unavailable') end
    local raw = {}
    for _, key in ipairs(orderedKeys) do
        local ok, value = pcall(getter, entityHandle, key)
        if not ok then return invalid('STATE_BAG_READ_FAILED', 'state bag read failed', { key = key }) end
        if value ~= nil then raw[key] = value end
    end
    local normalized = self:normalize(raw)
    if not normalized.ok then return invalid('STATE_BAG_READ_FAILED', 'state bag contains invalid metadata', normalized.error) end
    return Result.ok({ entity = entityHandle, metadata = copy(normalized.value) })
end

NightShift.StateBagPolicy = Policy
NightShift.Network.StateBagPolicy = Policy
