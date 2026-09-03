NightShift = NightShift or {}

local getConvar = type(GetConvar) == 'function' and GetConvar or rawget(_G, 'GetConvar')
local registerCommand = type(RegisterCommand) == 'function' and RegisterCommand or rawget(_G, 'RegisterCommand')
if type(registerCommand) ~= 'function' then return end

local server = NightShift.Server
if type(server) == 'table' and server._s17SmokeCommandsLoaded == true then return end

local function stageResult(name)
    local instance = type(NightShift.Server) == 'table' and NightShift.Server.instance or nil
    return type(instance) == 'table' and type(instance.results) == 'table' and instance.results[name] or nil
end

local function services()
    local stage = stageResult('services')
    return type(stage) == 'table' and (stage.services or stage.value and stage.value.services or stage) or nil
end

local function environment()
    local stage = stageResult('config')
    local config = type(stage) == 'table' and (stage.config or stage.value and stage.value.config) or NightShift.DefaultConfig
    return type(config) == 'table' and tostring(config.environment or ''):lower() or nil
end

local function enabled()
    local value = environment() == 'development'
    if type(getConvar) == 'function' then
        local ok, configured = pcall(getConvar, 'nightshift_s17_smoke_commands', '')
        if ok then
            configured = tostring(configured):lower()
            if configured == 'true' or configured == '1' then value = true end
            if configured == 'false' or configured == '0' then value = false end
        end
    end
    return value
end

if not enabled() then return end

local function player(source, label)
    source = tonumber(source)
    if source and source >= 1 and source <= 65535 and source == math.floor(source) then return source end
    if type(print) == 'function' then print(('[gnsh-nightshift] S17 %s must be run in-game by a player'):format(label)) end
end

local function errorValue(result)
    return type(result) == 'table' and (result.error or result) or { code = 'INVALID_RESULT', message = 'invalid service result' }
end

local function report(label, result)
    if type(print) ~= 'function' then return end
    if type(result) ~= 'table' then
        print(('[gnsh-nightshift] S17 %s failed: invalid service result'):format(label))
        return
    end
    if result.ok ~= true then
        local errorResult = errorValue(result)
        print(('[gnsh-nightshift] S17 %s failed: code=%s message=%s'):format(label, tostring(errorResult.code or 'UNKNOWN'), tostring(errorResult.message or 'unknown error')))
        return
    end
    local value = type(result.value) == 'table' and result.value or {}
    if label == 'favorite-list' then
        local items = value.items
        if type(items) ~= 'table' then
            print('[gnsh-nightshift] S17 favorite-list failed: code=INVALID_RESULT message=favorite list returned invalid items')
            return
        end
        local workers = {}
        for _, item in ipairs(items) do
            if type(item) == 'table' then
                local favorite = type(item.favorite) == 'table' and item.favorite or {}
                local workerKey = favorite.workerKey or item.workerKey or item.workerProfileKey or item.workerProfileId
                if workerKey ~= nil then workers[#workers + 1] = tostring(workerKey) end
            end
        end
        print(('[gnsh-nightshift] S17 favorite-list ok: count=%d workers=%s'):format(
            #items, #workers > 0 and table.concat(workers, ',') or 'none'))
        return
    end
    if label == 'worker-list' then
        local items = value.items
        if type(items) ~= 'table' then
            print('[gnsh-nightshift] S17 worker-list failed: code=INVALID_RESULT message=worker list returned invalid items')
            return
        end
        local workers = {}
        for _, item in ipairs(items) do
            if type(item) == 'table' then
                local workerKey = item.workerId or item.publicId or item.workerKey
                if workerKey ~= nil then workers[#workers + 1] = tostring(workerKey) end
            end
        end
        print(('[gnsh-nightshift] S17 worker-list ok: count=%d workers=%s'):format(
            #items, #workers > 0 and table.concat(workers, ',') or 'none'))
        return
    end
    local relationship = value.relationship or {}
    local review = value.review or {}
    local quote = value.quote or {}
    print(('[gnsh-nightshift] S17 %s ok: relationship=%s count=%s regular=%s trust=%s review=%s rating=%s quote=%s booking=%s'):format(
        label, tostring(relationship.id or 'n/a'), tostring(relationship.interactionCount or 'n/a'),
        tostring(relationship.regular or 'n/a'), tostring(relationship.trustScore or 'n/a'),
        tostring(review.id or 'n/a'), tostring(review.rating or 'n/a'),
        tostring(quote.quoteId or value.quoteId or 'n/a'),
        tostring(value.bookingId or value.booking and value.booking.id or 'n/a')))
end

local function requireService(name, code)
    local value = services() and services()[name]
    if type(value) == 'table' then return value end
    return nil, NightShift.Result.err(code, ('%s service is unavailable'):format(name))
end

registerCommand('nightshift_s17_favorite_add', function(source, args)
    source = player(source, 'favorite add')
    if not source then return end
    local service, unavailable = requireService('favorite', NightShift.Errors.Codes.FAVORITE_OPERATION_FAILED)
    report('favorite-add', service and args and args[1] and service:add(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s17_favorite_remove', function(source, args)
    source = player(source, 'favorite remove')
    if not source then return end
    local service, unavailable = requireService('favorite', NightShift.Errors.Codes.FAVORITE_OPERATION_FAILED)
    report('favorite-remove', service and args and args[1] and service:remove(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s17_favorite_list', function(source, args)
    source = player(source, 'favorite list')
    if not source then return end
    local service, unavailable = requireService('favorite', NightShift.Errors.Codes.FAVORITE_OPERATION_FAILED)
    report('favorite-list', service and service:list(source, {}) or unavailable)
end, false)

registerCommand('nightshift_s17_worker_list', function(source, args)
    source = player(source, 'worker list')
    if not source then return end
    local service, unavailable = requireService('marketplace', NightShift.Errors.Codes.MARKETPLACE_QUERY_FAILED)
    report('worker-list', service and service:list({}) or unavailable)
end, false)

registerCommand('nightshift_s17_relationship', function(source, args)
    source = player(source, 'relationship')
    if not source then return end
    local service, unavailable = requireService('relationship', NightShift.Errors.Codes.RELATIONSHIP_NOT_FOUND)
    report('relationship', service and args and args[1] and service:get(source, args[1]) or unavailable)
end, false)

registerCommand('nightshift_s17_review', function(source, args)
    source = player(source, 'review')
    if not source then return end
    local service, unavailable = requireService('review', NightShift.Errors.Codes.REVIEW_OPERATION_FAILED)
    local rating = args and tonumber(args[2])
    local payload = args and args[1] and { bookingId = args[1], rating = rating, reviewText = args[3] } or nil
    report('review', service and payload and service:submit(source, payload) or unavailable)
end, false)

registerCommand('nightshift_s17_book_again', function(source, args)
    source = player(source, 'book again')
    if not source then return end
    local service, unavailable = requireService('bookAgain', NightShift.Errors.Codes.BOOK_AGAIN_NOT_AVAILABLE)
    local payload = args and args[1] and {
        workerId = args[1], packageId = args[2] or 'standard',
        meetingMode = args[3] or 'come_to_me', locationId = args[4] or 'configured_default'
    } or nil
    report('book-again', service and payload and service:quote(source, payload) or unavailable)
end, false)

registerCommand('nightshift_s17_book_again_confirm', function(source, args)
    source = player(source, 'book again confirmation')
    if not source then return end
    local service, unavailable = requireService('bookAgain', NightShift.Errors.Codes.BOOK_AGAIN_NOT_AVAILABLE)
    report('book-again-confirm', service and args and args[1] and service:confirm(source, { quoteId = args[1] }) or unavailable)
end, false)

if type(print) == 'function' then
    print('[gnsh-nightshift] S17 smoke commands enabled: /nightshift_s17_worker_list, /nightshift_s17_favorite_add [workerKey], /nightshift_s17_favorite_remove [workerKey], /nightshift_s17_favorite_list, /nightshift_s17_relationship [workerKey], /nightshift_s17_review [bookingId] [rating] [text], /nightshift_s17_book_again [workerKey] [packageId] [meetingMode] [locationId], /nightshift_s17_book_again_confirm [quoteId]')
end
if type(server) == 'table' then server._s17SmokeCommandsLoaded = true end
