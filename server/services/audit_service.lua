NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local blockedKeys = {
    token = true, secret = true, password = true, credential = true,
    authorization = true, accessToken = true, refreshToken = true
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil
        and #value <= (maxLength or 160)
end

local function integer(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or math.floor(value) ~= value or (minimum and value < minimum) then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function safeKey(key)
    if type(key) ~= 'string' then return false end
    local normalized = key:gsub('[^%w]', ''):lower()
    return blockedKeys[key] ~= true and not normalized:find('token', 1, true)
        and not normalized:find('secret', 1, true)
        and not normalized:find('password', 1, true)
        and not normalized:find('credential', 1, true)
        and not normalized:find('authorization', 1, true)
end

local function redact(value, depth, budget, seen)
    if budget.count <= 0 then return '[TRUNCATED]' end
    budget.count = budget.count - 1
    if type(value) == 'string' then
        if #value > 512 then return value:sub(1, 512) .. '…' end
        return value
    end
    if type(value) ~= 'table' then
        if type(value) == 'number' and (value ~= value or value == math.huge or value == -math.huge) then return nil end
        return value
    end
    if depth >= 4 or seen[value] then return '[TRUNCATED]' end
    seen[value] = true
    local output = {}
    local keys = {}
    for key in pairs(value) do if safeKey(key) then keys[#keys + 1] = key end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for index = 1, math.min(#keys, 48) do
        local key = keys[index]
        output[key] = redact(value[key], depth + 1, budget, seen)
    end
    seen[value] = nil
    return output
end

local function resultInfo(result)
    if type(result) == 'boolean' then return result and 'OK' or 'ERROR', nil end
    if type(result) ~= 'table' then return 'UNKNOWN', nil end
    local status = result.ok == true and 'OK' or result.ok == false and 'ERROR' or 'UNKNOWN'
    local source = result.error or result
    local code = type(source) == 'table' and source.code or result.code
    return status, text(code, 96) and code or nil
end

function Service.new(options)
    options = options or {}
    local repository = options.repository or options.auditRepository
    if type(repository) ~= 'table' or type(repository.create) ~= 'function'
        or type(repository.findRecent) ~= 'function' then
        return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'audit service requires an audit repository')
    end
    return setmetatable({
        _repository = repository,
        _clock = options.clock,
        _metadataBudget = integer(options.metadataBudget, 32) or 512
    }, Service)
end

function Service:sanitize(value)
    return redact(value, 0, { count = self._metadataBudget }, {})
end

function Service:_timestamp()
    if type(self._clock) == 'table' and type(self._clock.timestamp) == 'function' then
        local ok, value = pcall(self._clock.timestamp, self._clock)
        if ok and text(value, 80) then return value end
    end
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

function Service:record(event)
    if type(event) ~= 'table' then return invalid('audit event must be a table') end
    if not text(event.action, 96) then return invalid('audit action is required') end
    local actor = type(event.actor) == 'table' and event.actor or {}
    local target = type(event.target) == 'table' and event.target or {}
    local actorSource = actor.source or event.actorSource
    if actorSource ~= nil and not integer(actorSource, 1) then return invalid('audit actor source is invalid') end
    local status, code = resultInfo(event.result)
    status = event.resultStatus and tostring(event.resultStatus):upper() or status
    if status ~= 'OK' and status ~= 'ERROR' and status ~= 'UNKNOWN' then return invalid('audit result status is invalid') end
    local metadata = self:sanitize(event.metadata or {})
    local row = {
        actorSource = actorSource,
        actorType = actor.actorType or event.actorType,
        actorRef = actor.ref or actor.actorRef or event.actorRef,
        action = event.action,
        targetType = target.type or target.targetType or event.targetType,
        targetRef = target.ref or target.targetRef or event.targetRef,
        resultStatus = status,
        resultCode = event.resultCode or code,
        reason = event.reason,
        correlationId = event.correlationId,
        metadata = metadata,
        occurredAt = event.occurredAt or self:_timestamp()
    }
    for key, value in pairs({
        actorType = row.actorType, actorRef = row.actorRef,
        targetType = row.targetType, targetRef = row.targetRef,
        resultCode = row.resultCode, reason = row.reason, correlationId = row.correlationId
    }) do
        if value ~= nil and not text(value, key == 'reason' and 512 or 160) then
            return invalid('audit ' .. key .. ' is invalid')
        end
    end
    return self._repository:create(row)
end

Service.append = Service.record
Service.log = Service.record

function Service:list(options)
    return self._repository:findRecent(options)
end

Service.findRecent = Service.list
NightShift.AuditService = Service
NightShift.Services.Audit = Service
