NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Base = NightShift.ProviderBase
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local function wrap(handler, key)
    if type(handler) ~= 'function' then return nil end
    return function(...)
        local ok, value = pcall(handler, ...)
        if not ok then return false end
        if type(value) == 'table' and value.ok ~= nil then return value end
        if value == true then return { [key] = true } end
        return value
    end
end

local Evidence = {}

function Evidence.new(options)
    options = options or {}
    local adapter = Base.new('evidence', options, {
        optional = true, evidence = true, record = true, attach = true, list = true
    }, { 'record', 'attach', 'list' })
    adapter._handlers.record = wrap(options.record, 'recorded')
    adapter._handlers.attach = wrap(options.attach, 'attached')
    adapter._handlers.list = options.list
    adapter.record = function(self, event)
        if type(event) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'evidence event must be a table') end
        return self:invoke('record', { skipped = true, optional = true }, event)
    end
    adapter.attach = function(self, evidenceId, reference)
        if type(evidenceId) ~= 'string' or evidenceId:match('^%s*$') or type(reference) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'evidence attachment requires an id and reference') end
        return self:invoke('attach', { skipped = true, optional = true }, evidenceId, reference)
    end
    adapter.list = function(self, query)
        if query ~= nil and type(query) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'evidence query must be a table') end
        return self:invoke('list', { skipped = true, optional = true }, query or {})
    end
    return adapter
end

NightShift.OptionalProviders.Evidence = Evidence
