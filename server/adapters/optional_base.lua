NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Base = NightShift.ProviderBase or {}
local Adapter = {}
Adapter.__index = Adapter

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    return result
end

local function text(value, max)
    if type(value) ~= 'string' then return nil end
    local result = value:match('^%s*(.-)%s*$')
    if result == '' then return nil end
    return result:sub(1, max or 160)
end

function Base.copy(value) return copy(value) end
function Base.text(value, max) return text(value, max) end

function Base.new(name, options, capabilities, operations)
    options = options or {}
    local handlers = {}
    for _, operation in ipairs(operations or {}) do
        if type(options[operation]) == 'function' then handlers[operation] = options[operation] end
        if type(options.handlers) == 'table' and type(options.handlers[operation]) == 'function' then handlers[operation] = options.handlers[operation] end
    end
    local adapter = setmetatable({
        name = name,
        _handlers = handlers,
        _operations = copy(operations or {}),
        _available = options.available,
        _capabilities = copy(capabilities or {})
    }, Adapter)
    adapter._capabilities.provider = name
    return adapter
end

function Adapter:isAvailable()
    if type(self._available) == 'function' then
        local ok, value = pcall(self._available)
        return ok and value == true
    end
    if self._available ~= nil then return self._available == true end
    for _, operation in ipairs(self._operations) do
        if type(self._handlers[operation]) == 'function' then return true end
    end
    return false
end

function Adapter:_missing(operation, fallback)
    if fallback ~= nil then return Result.ok(copy(fallback)) end
    return Result.err(Codes.CAPABILITY_UNAVAILABLE, ('optional provider operation "%s" is unavailable'):format(operation), { provider = self.name, operation = operation })
end

function Adapter:invoke(operation, fallback, ...)
    local handler = self._handlers[operation]
    if type(handler) ~= 'function' or not self:isAvailable() then return self:_missing(operation, fallback) end
    local args = { ... }
    for i, value in ipairs(args) do args[i] = copy(value) end
    local ok, value = pcall(handler, table.unpack(args))
    if not ok then return Result.err(Codes.PROVIDER_UNAVAILABLE, ('optional provider operation "%s" failed'):format(operation), { provider = self.name, operation = operation }) end
    if type(value) == 'table' and value.ok ~= nil then return value end
    if value == false or value == nil then return Result.err(Codes.PROVIDER_UNAVAILABLE, ('optional provider operation "%s" was rejected'):format(operation), { provider = self.name, operation = operation }) end
    if type(value) == 'table' then return Result.ok(value) end
    return Result.ok({ operation = operation, result = value })
end

function Adapter:getCapabilities()
    local capabilities = copy(self._capabilities)
    capabilities.available = self:isAvailable()
    return capabilities
end

function Adapter:healthCheck()
    return Result.ok({ provider = self.name, available = self:isAvailable(), healthy = self:isAvailable(), optional = true, capabilities = self:getCapabilities() })
end

NightShift.ProviderBase = Base
NightShift.ProviderBase.Adapter = Adapter
