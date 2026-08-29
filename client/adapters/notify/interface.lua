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

local Notify = {}
Notify.__index = Notify

function Notify.new(options)
    options = options or {}
    return setmetatable({
        name = 'notify', _handler = options.send, _available = options.available,
        _capabilities = { optional = true, notify = true, provider = 'notify' }
    }, Notify)
end

function Notify:isAvailable()
    if self._available ~= nil then return self._available == true end
    return type(self._handler) == 'function'
end

function Notify:getCapabilities()
    local caps = copy(self._capabilities)
    caps.available = self:isAvailable()
    return caps
end

function Notify:healthCheck() return resultOk({ provider = self.name, available = self:isAvailable(), healthy = self:isAvailable(), optional = true, capabilities = self:getCapabilities() }) end

function Notify:send(playerSource, payload)
    if tonumber(playerSource) == nil or tonumber(playerSource) < 1 or type(payload) ~= 'table' then return resultErr('PROVIDER_INVALID', 'notification requires a player source and payload') end
    if type(self._handler) ~= 'function' or not self:isAvailable() then return resultOk({ fallback = true, sent = false }) end
    local ok, value = pcall(self._handler, playerSource, copy(payload))
    if not ok or value == false or value == nil then return resultErr('PROVIDER_UNAVAILABLE', 'notification provider operation failed') end
    if type(value) == 'table' and value.ok ~= nil then return value end
    return resultOk({ sent = true })
end

NightShift.OptionalProviders.Notify = Notify
