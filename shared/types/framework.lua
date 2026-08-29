NightShift = NightShift or {}

NightShift.Types = NightShift.Types or {}
local FrameworkTypes = NightShift.Types.Framework or {}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function text(value)
    if type(value) ~= 'string' then return nil end
    local trimmed = value:match('^%s*(.-)%s*$')
    if trimmed == '' then return nil end
    return trimmed:sub(1, 160)
end

local function number(value, fallback)
    value = tonumber(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function job(values)
    values = type(values) == 'table' and values or {}
    local grade = number(values.grade, number(values.level, 0))
    grade = math.max(0, math.floor(grade or 0))
    return {
        name = text(values.name) or 'unassigned',
        grade = grade,
        onDuty = values.onDuty == true
    }
end

function FrameworkTypes.identity(values)
    values = type(values) == 'table' and values or {}
    local source = tonumber(values.source)
    local identifier = text(values.identifier)
    if not source or source < 1 or math.floor(source) ~= source or not identifier then return nil end
    local characterId = text(values.characterId) or identifier
    local characterName = text(values.characterName) or characterId
    return {
        source = source,
        identifier = identifier,
        characterId = characterId,
        characterName = characterName,
        job = job(values.job),
        loaded = values.loaded ~= false,
        provider = text(values.provider)
    }
end

function FrameworkTypes.job(values) return job(values) end
function FrameworkTypes.copy(value) return copy(value) end
function FrameworkTypes.text(value) return text(value) end

NightShift.Types.Framework = FrameworkTypes
