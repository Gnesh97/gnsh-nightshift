NightShift = NightShift or {}

local Logger = NightShift.Logger or {}
local sensitive = {
    token=true, password=true, secret=true, authorization=true, account=true,
    identifier=true, phone=true, coordinates=true, coordinate=true, rawpayload=true,
    payload=true
}

local function copyAndRedact(value, seen, key)
    if sensitive[(tostring(key or ''):lower():gsub('[%W_]', ''))] then return '[REDACTED]' end
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for childKey, child in pairs(value) do output[childKey] = copyAndRedact(child, seen, childKey) end
    return output
end

local function normalizeId(value, generate)
    local text = type(value) == 'string' and value or ''
    text = text:gsub('[^%w%._%-:]', ''):sub(1, 96)
    if text ~= '' then return text end
    local ok, generated = pcall(generate)
    generated = ok and tostring(generated or '') or ''
    return generated:gsub('[^%w%._%-:]', ''):sub(1, 96)
end

function Logger.new(options)
    options = options or {}
    local clock = options.clock or NightShift.Clock.new()
    local generate = type(options.idGenerator) == 'function' and options.idGenerator or function()
        return ('ns-%d-%d'):format(os.time(), math.random(100000, 999999))
    end
    local filter = options.filter
    if type(filter) ~= 'function' then
        local categories = options.debugCategories or {}
        filter = function(category, level)
            return level ~= 'debug' or categories[category] == true or categories['*'] == true
        end
    end
    return setmetatable({ _clock=clock, _generate=generate, _filter=filter,
        _sink=type(options.sink) == 'function' and options.sink or function(entry) print(entry.level .. ': ' .. entry.message) end,
        correlationId=normalizeId(options.correlationId, generate) }, { __index=Logger })
end

function Logger:withCorrelation(correlationId)
    local options = { clock=self._clock, idGenerator=self._generate, filter=self._filter, sink=self._sink,
        correlationId=correlationId }
    return Logger.new(options)
end

function Logger:log(level, category, message, context)
    if type(category) ~= 'string' then category, message, context = 'general', category, message end
    local filterOk, allowed = pcall(self._filter, category, level)
    if not filterOk or not allowed then return false end
    local entry = { level=level, category=category, message=tostring(message or ''),
        timestamp=self._clock:timestamp(), correlationId=self.correlationId,
        context=copyAndRedact(context) }
    pcall(self._sink, entry)
    return true
end

function Logger:debug(category, message, context) return self:log('debug', category, message, context) end
function Logger:info(category, message, context) return self:log('info', category, message, context) end
function Logger:warn(category, message, context) return self:log('warn', category, message, context) end
function Logger:error(category, message, context) return self:log('error', category, message, context) end

NightShift.Logger = Logger
