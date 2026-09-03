NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Service = {}
Service.__index = Service

local activeStates = {
    DRAFT = true, QUOTED = true, OFFERED = true, ACCEPTED = true,
    RESERVED = true, PREPARING = true, TRAVELLING = true, ARRIVED = true,
    ACTIVE = true, COMPLETED = true, RECOVERY_REQUIRED = true
}

local failedPaymentStates = { FAILED = true, DECLINED = true, UNKNOWN = true }

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

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or math.floor(value) ~= value then return nil end
    if minimum and value < minimum then return nil end
    if maximum and value > maximum then return nil end
    return value
end

local function invalid(message, details)
    return Result.err(Codes.REPOSITORY_INVALID, message, details)
end

local function safeCapabilities(value, depth, seen)
    if depth > 3 or type(value) ~= 'table' then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local output = {}
    for key, item in pairs(value) do
        local normalizedKey = type(key) == 'string' and key:gsub('[^%w]', ''):lower() or ''
        local sensitiveKey = normalizedKey:find('token', 1, true)
            or normalizedKey:find('secret', 1, true)
            or normalizedKey:find('password', 1, true)
            or normalizedKey:find('credential', 1, true)
            or normalizedKey:find('authorization', 1, true)
        if type(key) == 'string' and not sensitiveKey
            and key:match('^[A-Za-z][A-Za-z0-9_.%-]*$')
            and (type(item) == 'boolean' or type(item) == 'string'
                or (type(item) == 'table' and depth < 3)) then
            if type(item) == 'table' then
                output[key] = safeCapabilities(item, depth + 1, seen)
            elseif #tostring(item) <= 128 then
                output[key] = item
            end
        end
    end
    seen[value] = nil
    return output
end

local function call(service, method, ...)
    if type(service) ~= 'table' or type(service[method]) ~= 'function' then return nil end
    local ok, result = pcall(service[method], service, ...)
    return ok and result or nil
end

function Service.new(options)
    options = options or {}
    local permissionCheck = options.adminCheck or options.permissionCheck
    if permissionCheck ~= nil and type(permissionCheck) ~= 'function' then
        return nil, Result.err(Codes.PERMISSION_INVALID, 'diagnostic permission check must be a function')
    end
    return setmetatable({
        _database = options.database or options.databaseAdapter,
        _booking = options.bookingRepository,
        _payment = options.paymentRepository,
        _reservation = options.locationReservationRepository,
        _analytics = options.analyticsService or options.analytics,
        _audit = options.auditService or options.audit,
        _providers = options.providers or options.capabilities,
        _permission = permissionCheck,
        _maxRows = integer(options.maxRows, 1, 100) or 100
    }, Service)
end

function Service:_allowed(source)
    source = tonumber(source)
    if source == 0 then return true end
    if source == nil or source < 1 or source ~= math.floor(source) then return false end
    if type(self._permission) ~= 'function' then return false end
    local ok, value = pcall(self._permission, source)
    if not ok then return false end
    if type(value) == 'table' and value.ok ~= nil then return value.ok == true end
    return value == true
end

function Service:_databaseHealth()
    if type(self._database) ~= 'table' or type(self._database.healthCheck) ~= 'function' then
        return { available = false, status = 'UNCONFIGURED' }
    end
    local result = call(self._database, 'healthCheck')
    if type(result) == 'table' and result.ok == true then
        return { available = true, status = 'HEALTHY' }
    end
    return {
        available = true, status = 'UNHEALTHY',
        code = type(result) == 'table' and result.error and result.error.code or Codes.DB_HEALTHCHECK_FAILED
    }
end

function Service:_activeBookings()
    local result = call(self._booking, 'findAll', { limit = self._maxRows, offset = 0 })
    if type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table' then
        return { available = false, count = 0, byStatus = {} }
    end
    local count, byStatus, travelPlans = 0, {}, {}
    for _, booking in ipairs(result.value) do
        if type(booking) == 'table' and activeStates[tostring(booking.status or ''):upper()] then
            count = count + 1
            local status = tostring(booking.status):upper()
            byStatus[status] = (byStatus[status] or 0) + 1
            if status == 'TRAVELLING' and #travelPlans < self._maxRows then
                travelPlans[#travelPlans + 1] = {
                    bookingId = booking.id,
                    updatedAt = booking.updatedAt,
                    scheduledAt = booking.scheduledAt,
                    requiresReview = true
                }
            end
        end
    end
    return {
        available = true, count = count, byStatus = byStatus,
        stuckTravelPlans = {
            available = true, count = #travelPlans, items = travelPlans,
            sampled = #travelPlans >= self._maxRows
        },
        sampled = #result.value >= self._maxRows
    }
end

function Service:_failedSettlements()
    local result
    if type(self._payment) == 'table' and type(self._payment.findAll) == 'function' then
        result = call(self._payment, 'findAll', { limit = self._maxRows, offset = 0 })
    end
    if type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table' then
        return { available = false, count = 0, byStatus = {} }
    end
    local count, byStatus = 0, {}
    for _, payment in ipairs(result.value) do
        if type(payment) == 'table' and failedPaymentStates[tostring(payment.status or ''):upper()] then
            count = count + 1
            local status = tostring(payment.status):upper()
            byStatus[status] = (byStatus[status] or 0) + 1
        end
    end
    return { available = true, count = count, byStatus = byStatus, sampled = #result.value >= self._maxRows }
end

function Service:_expiredReservations()
    local result = call(self._reservation, 'findExpired', { limit = self._maxRows })
    if type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table' then
        return { available = false, count = 0 }
    end
    return { available = true, count = #result.value, sampled = #result.value >= self._maxRows }
end

function Service:snapshot(source, options)
    if not self:_allowed(source) then return Result.err(Codes.PERMISSION_DENIED, 'diagnostics access is restricted') end
    options = type(options) == 'table' and options or {}
    local analytics
    if options.includeAnalytics ~= false and self._analytics then
        local result = call(self._analytics, 'summary', options.analytics)
        if type(result) == 'table' and result.ok == true then analytics = result.value end
    end
    local serverError = NightShift.Server and NightShift.Server.error
    return Result.ok({
        server = {
            readiness = NightShift.Server and NightShift.Server.readiness or 'UNKNOWN',
            errorCode = type(serverError) == 'table' and serverError.code or nil
        },
        database = self:_databaseHealth(),
        providers = safeCapabilities(self._providers or {}, 0, {}),
        activeBookings = self:_activeBookings(),
        failedSettlements = self:_failedSettlements(),
        expiredReservations = self:_expiredReservations(),
        analytics = analytics,
        auditAvailable = self._audit ~= nil,
        bounded = true
    }, { serverAuthoritative = true, sensitiveFieldsRedacted = true })
end

Service.get = Service.snapshot
Service.health = Service.snapshot
NightShift.DiagnosticsService = Service
NightShift.Services.Diagnostics = Service
