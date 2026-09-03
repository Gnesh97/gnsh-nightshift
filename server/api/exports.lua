NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local function unavailable(capability)
    return Result.err(Codes.API_UNAVAILABLE, capability .. ' is unavailable')
end

local function services()
    local server = NightShift.Server
    local instance = type(server) == 'table' and server.instance or nil
    local results = type(instance) == 'table' and instance.results or nil
    local stage = type(results) == 'table' and results.services or nil
    if type(stage) ~= 'table' then return nil end
    return stage.services or stage.value and stage.value.services or stage
end

local function dto()
    return NightShift.Api and NightShift.Api.Dto
end

local function install()
    if NightShift.Api and NightShift.Api._publicExportsInstalled then return true end
    local export = type(exports) == 'function' and exports or rawget(_G, 'exports')
    if type(export) ~= 'function' then return false end
    local function register(name, handler)
        pcall(export, name, handler)
    end
    register('GetBooking', function(bookingId)
        local current = services()
        if not current or type(current.booking) ~= 'table' or type(current.booking.get) ~= 'function' then
            return unavailable('booking lookup') end
        local result = current.booking:get(bookingId)
        if type(result) ~= 'table' or result.ok ~= true then return result end
        local mapper = dto()
        if type(mapper) ~= 'table' or type(mapper.booking) ~= 'function' then return unavailable('booking DTO') end
        local value, mapError = mapper.booking(result.value)
        if mapError then return mapError end
        return Result.ok(value)
    end)
    register('ListAvailableNPCWorkers', function(options)
        local current = services()
        local marketplace = current and (current.marketplace or current.npcWorker)
        if type(marketplace) ~= 'table' then return unavailable('NPC worker listing') end
        local request = type(options) == 'table' and options or {}
        local result
        if type(marketplace.list) == 'function' then
            result = marketplace:list(request)
        elseif type(marketplace.listAvailable) == 'function' then
            result = marketplace:listAvailable(request)
        else
            return unavailable('NPC worker listing')
        end
        if type(result) ~= 'table' or result.ok ~= true then return result end
        local mapper = dto()
        if type(mapper) ~= 'table' or type(mapper.worker) ~= 'function' then return unavailable('worker DTO') end
        local source = result.value or {}
        local items = source.items or source
        if type(items) ~= 'table' then return Result.err(Codes.API_INVALID, 'worker listing returned invalid items') end
        local mapped = {}
        for index, item in ipairs(items) do
            local worker, mapError = mapper.worker(item)
            if mapError then return mapError end
            mapped[index] = worker
        end
        return Result.ok({ items = mapped, total = source.total or #mapped, limit = source.limit, offset = source.offset })
    end)
    register('GetClientProfileSummary', function(playerSource)
        local current = services()
        if not current or type(current.clientProfile) ~= 'table' or type(current.clientProfile.get) ~= 'function' then
            return unavailable('client profile summary') end
        local result = current.clientProfile:get(playerSource)
        if type(result) ~= 'table' or result.ok ~= true then return result end
        local mapper = dto()
        if type(mapper) ~= 'table' or type(mapper.profileSummary) ~= 'function' then return unavailable('profile DTO') end
        local value, mapError = mapper.profileSummary(result.value)
        if mapError then return mapError end
        return Result.ok(value)
    end)
    register('ListLocationProviders', function()
        local current = services()
        local api = current and current.locationProviderApi
        if type(api) ~= 'table' or type(api.list) ~= 'function' then return unavailable('location provider listing') end
        return api:list()
    end)
    register('GetHealth', function(options)
        local current = services()
        local diagnostics = current and current.diagnostics
        if type(diagnostics) ~= 'table' or type(diagnostics.snapshot) ~= 'function' then
            return unavailable('health diagnostics') end
        return diagnostics:snapshot(0, type(options) == 'table' and options or {})
    end)
    register('GetSecurityStatus', function()
        local current = services() or {}
        local rateLimiter = current.rateLimiter
        local actionTokens = current.actionTokens
        local rateStatus = type(rateLimiter) == 'table' and type(rateLimiter.status) == 'function'
            and rateLimiter:status() or nil
        local tokenStatus = type(actionTokens) == 'table' and type(actionTokens.status) == 'function'
            and actionTokens:status() or nil
        if type(rateStatus) ~= 'table' and type(tokenStatus) ~= 'table' then
            return unavailable('security status')
        end
        return Result.ok({
            rateLimit = rateStatus and rateStatus.ok == true and rateStatus.value or nil,
            actionTokens = tokenStatus and tokenStatus.ok == true and tokenStatus.value or nil
        })
    end)
    register('CreateExternalBookingRequest', function()
        return Result.err(Codes.API_FORBIDDEN, 'external booking writes are disabled until caller authentication is configured')
    end)
    NightShift.Api = NightShift.Api or {}
    NightShift.Api._publicExportsInstalled = true
    return true
end

NightShift.Api = NightShift.Api or {}
NightShift.Api.installPublicExports = install
install()
