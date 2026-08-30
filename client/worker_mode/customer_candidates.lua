NightShift = NightShift or {}
NightShift.Client = NightShift.Client or {}

local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}

local Controller = {}
Controller.__index = Controller

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function cleanText(value, maximum)
    if not text(value, maximum) or value:find('%z') then return nil end
    value = value:gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return text(value, maximum) and value or nil
end

local function token(value, maximum)
    return cleanText(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function invalid(message, details)
    return Result.err(Codes.NPC_CUSTOMER_INVALID or 'NPC_CUSTOMER_INVALID', message, details)
end

local function payloadItems(payload)
    if type(payload) ~= 'table' then return nil end
    if payload.ok == false then return nil, payload end
    if payload.ok == true then payload = payload.value end
    if type(payload) ~= 'table' then return nil end
    if type(payload.items) == 'table' then return payload.items end
    if #payload > 0 then return payload end
    return {}
end

local function normalize(candidate)
    if type(candidate) ~= 'table' then return nil, invalid('customer candidate must be a table') end
    local key = candidate.opportunityKey or candidate.key or candidate.id
    key = cleanText(key, 200)
    if not token(key, 200) then return nil, invalid('customer candidate key is invalid') end
    local district = candidate.district
    district = cleanText(district, 64)
    if not token(district, 64) then return nil, invalid('customer candidate district is invalid') end
    local zone = candidate.zone or candidate.discoveryZone
    if zone ~= nil then
        zone = cleanText(zone, 64)
        if not token(zone, 64) then return nil, invalid('customer candidate zone is invalid') end
    end
    local score = candidate.demandScore or candidate.score
    if score ~= nil then
        score = tonumber(score)
        if not finite(score) or score < 0 or score > 100 then return nil, invalid('customer candidate demand score is invalid') end
    end
    local budget = candidate.budgetClass
    if budget == nil and type(candidate.customer) == 'table' then budget = candidate.customer.budgetClass end
    if budget ~= nil then
        budget = tonumber(budget)
        if not budget or budget ~= math.floor(budget) or budget < 1 or budget > 5 then return nil, invalid('customer candidate budget class is invalid') end
    end
    local alias = candidate.alias or candidate.displayName
    if alias == nil and type(candidate.customer) == 'table' then alias = candidate.customer.alias or candidate.customer.displayName end
    if alias ~= nil then
        alias = cleanText(alias, 80)
        if not alias then return nil, invalid('customer candidate alias is invalid') end
    end
    local state = candidate.state == nil and 'AVAILABLE' or tostring(candidate.state):upper()
    if state ~= 'AVAILABLE' and state ~= 'CLAIMED' and state ~= 'DISMISSED' and state ~= 'EXPIRED' then return nil, invalid('customer candidate state is invalid') end
    local demandBand = candidate.demandBand or candidate.band
    if demandBand ~= nil then
        demandBand = tostring(demandBand):upper()
        if demandBand ~= 'LOW' and demandBand ~= 'NORMAL' and demandBand ~= 'HIGH' then return nil, invalid('customer candidate demand band is invalid') end
    end
    local createdAt = candidate.createdAt
    local expiresAt = candidate.expiresAt
    if createdAt ~= nil and not finite(createdAt) then return nil, invalid('customer candidate creation timestamp is invalid') end
    if expiresAt ~= nil and not finite(expiresAt) then return nil, invalid('customer candidate expiry timestamp is invalid') end
    return {
        opportunityKey = key,
        key = key,
        district = tostring(district):lower(),
        zone = zone and tostring(zone):lower() or nil,
        alias = alias,
        displayName = alias,
        budgetClass = budget,
        demandScore = score,
        demandBand = demandBand,
        state = state,
        createdAt = createdAt,
        expiresAt = expiresAt
    }
end

function Controller.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('customer candidate controller options must be a table') end
    if options.enabled ~= nil and type(options.enabled) ~= 'boolean' then return nil, invalid('customer candidate enabled flag must be boolean') end
    return setmetatable({
        _enabled = options.enabled == nil and true or options.enabled,
        _items = {},
        _listeners = {},
        _mapper = options.physicalMapper
    }, Controller)
end

function Controller:isEnabled()
    return self._enabled == true
end

function Controller:setEnabled(value)
    if type(value) ~= 'boolean' then return invalid('customer candidate enabled flag must be boolean') end
    self._enabled = value
    if not value then self:clear() end
    return Result.ok({ enabled = value })
end

function Controller:_notify()
    local snapshot = self:list()
    for _, listener in ipairs(self._listeners) do pcall(listener, copy(snapshot)) end
end

function Controller:sync(payload)
    if not self:isEnabled() then return Result.ok({ items = {}, count = 0 }, { disabled = true }) end
    local items, payloadError = payloadItems(payload)
    if not items then return payloadError or invalid('customer candidate payload must contain an item array') end
    local normalized = {}
    for index, candidate in ipairs(items) do
        local value, errorResult = normalize(candidate)
        if not value then
            if errorResult and errorResult.error then
                local details = copy(errorResult.error.details or {})
                details.index = index
                return Result.err(errorResult.error.code, errorResult.error.message, details, errorResult.metadata)
            end
            return errorResult or invalid('customer candidate is invalid', { index = index })
        end
        normalized[#normalized + 1] = value
    end
    self._items = normalized
    self:_notify()
    return Result.ok({ items = self:list(), count = #normalized })
end

function Controller:list()
    return copy(self._items)
end

function Controller:get(opportunityKey)
    if not text(opportunityKey, 200) then return nil end
    for _, item in ipairs(self._items) do if item.opportunityKey == opportunityKey then return copy(item) end end
    return nil
end

function Controller:clear()
    self._items = {}
    self:_notify()
    return Result.ok({ items = {}, count = 0 })
end

function Controller:onUpdate(listener)
    if type(listener) ~= 'function' then return invalid('customer candidate listener must be a function') end
    self._listeners[#self._listeners + 1] = listener
    return true
end

function Controller:mapPhysical(opportunityKey, mapper)
    local candidate = self:get(opportunityKey)
    if not candidate then return Result.err(Codes.NPC_CUSTOMER_NOT_FOUND or 'NPC_CUSTOMER_NOT_FOUND', 'customer candidate was not found') end
    mapper = mapper or self._mapper
    if type(mapper) ~= 'function' then return Result.err(Codes.NPC_CUSTOMER_UNAVAILABLE or 'NPC_CUSTOMER_UNAVAILABLE', 'physical candidate mapping is unavailable') end
    local ok, value = pcall(mapper, candidate)
    if not ok then return Result.err(Codes.NPC_CUSTOMER_UNAVAILABLE or 'NPC_CUSTOMER_UNAVAILABLE', 'physical candidate mapping failed') end
    return Result.ok(value)
end

Controller.receive = Controller.sync
Controller.setCandidates = Controller.sync
Controller.getCandidates = Controller.list

NightShift.ClientWorkerModeCustomerCandidates = Controller
NightShift.Client.WorkerModeCustomerCandidates = Controller
