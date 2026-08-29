NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function resultOk(value)
    if NightShift.Result and NightShift.Result.ok then return NightShift.Result.ok(value) end
    return { ok = true, success = true, value = copy(value), data = copy(value) }
end

local function resultErr(code, message, details)
    if NightShift.Result and NightShift.Result.err then return NightShift.Result.err(code, message, details) end
    return { ok = false, success = false, code = code, message = message, error = { code = code, message = message, details = details }, details = details }
end

local function text(value)
    return type(value) == 'string' and value:match('%S') and value:sub(1, 96) or nil
end

local function invoke(self, operation, fallback, ...)
    local handler = self._handlers[operation]
    if type(handler) ~= 'function' or not self:isAvailable() then return resultOk(fallback) end
    local ok, value = pcall(handler, ...)
    if not ok or value == false or value == nil then return resultErr('PROVIDER_UNAVAILABLE', 'target provider operation failed', { operation = operation }) end
    if type(value) == 'table' and value.ok ~= nil then return value end
    return resultOk(type(value) == 'table' and value or { operation = operation, result = value })
end

local Target = {}
Target.__index = Target

function Target.new(options)
    options = options or {}
    local handlers = {}
    for _, name in ipairs({ 'registerZone', 'removeZone', 'addEntity', 'removeEntity' }) do handlers[name] = options[name] end
    return setmetatable({
        name = 'target', _handlers = handlers, _available = options.available,
        _capabilities = { optional = true, target = true, provider = 'target' }
    }, Target)
end

function Target:isAvailable()
    if self._available ~= nil then return self._available == true end
    for _, handler in pairs(self._handlers) do if type(handler) == 'function' then return true end end
    return false
end

function Target:getCapabilities()
    local caps = copy(self._capabilities)
    caps.available = self:isAvailable()
    return caps
end

function Target:healthCheck() return resultOk({ provider = self.name, available = self:isAvailable(), healthy = self:isAvailable(), optional = true, capabilities = self:getCapabilities() }) end

function Target:registerZone(name, definition)
    if not text(name) or type(definition) ~= 'table' then return resultErr('PROVIDER_INVALID', 'target zone requires a name and definition') end
    return invoke(self, 'registerZone', { fallback = true, registered = false }, name, definition)
end

function Target:removeZone(name)
    if not text(name) then return resultErr('PROVIDER_INVALID', 'target zone name is required') end
    return invoke(self, 'removeZone', { fallback = true, removed = false }, name)
end

function Target:addEntity(entity, definition)
    if entity == nil or type(definition) ~= 'table' then return resultErr('PROVIDER_INVALID', 'target entity requires an entity and definition') end
    return invoke(self, 'addEntity', { fallback = true, registered = false }, entity, definition)
end

function Target:removeEntity(entity)
    if entity == nil then return resultErr('PROVIDER_INVALID', 'target entity is required') end
    return invoke(self, 'removeEntity', { fallback = true, removed = false }, entity)
end

NightShift.OptionalProviders.Target = Target
