NightShift = NightShift or {}
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Coordinator = {}
Coordinator.__index = Coordinator
local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end
local function token(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= maximum and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end
local function invalid(message, details) return Result.err(Codes.NPC_SPAWN_CONTEXT_REQUIRED, message, details) end
local function controller(value, method) return type(value) == 'table' and type(value[method]) == 'function' end
function Coordinator.new(options)
    options = options or {}
    if not controller(options.spawn, 'spawn') or not controller(options.navigation, 'start') or not controller(options.navigation, 'tick') or not controller(options.despawn, 'despawn') then
        return nil, invalid('NPC coordinator requires spawn, navigation, and despawn controllers')
    end
    return setmetatable({ _spawn = options.spawn, _navigation = options.navigation, _despawn = options.despawn, _onState = options.onState, _active = {} }, Coordinator)
end
function Coordinator:_notify(profileKey, state, payload)
    local active = self._active[profileKey]
    if active then
        local nextActive = copy(active)
        nextActive.state = state
        self._active[profileKey] = nextActive
    end
    if type(self._onState) == 'function' then pcall(self._onState, state, copy(payload)) end
end
function Coordinator:handleAuthorization(authorization)
    if type(authorization) ~= 'table' or authorization.serverOwned ~= true or not token(authorization.profileKey, 160) or not token(authorization.generationToken, 240) then return invalid('NPC authorization is invalid') end
    local existing = self._active[authorization.profileKey]
    if existing and existing.generationToken ~= authorization.generationToken then return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'NPC authorization generation is already active') end
    local spawned = self._spawn:spawn(copy(authorization))
    if not spawned.ok then return spawned end
    local context = copy(spawned.value)
    if type(context) ~= 'table' or not token(context.profileKey, 160)
        or not token(context.generationToken, 240) or context.entity == nil then
        return invalid('NPC spawn controller returned an invalid context')
    end
    context.serverOwned = true
    local resolved = authorization.resolvedDestination
    context.target = authorization.target or (type(resolved) == 'table' and resolved.worldTarget or nil)
    self._active[context.profileKey] = { profileKey = context.profileKey, generationToken = context.generationToken, bookingId = context.bookingId, entity = context.entity, state = 'BOUND' }
    self:_notify(context.profileKey, 'BOUND', context)
    if context.target ~= nil then
        -- Navigation has a deliberately narrow context contract. Do not pass
        -- model, candidate, network, or other spawn metadata into it.
        local navigationContext = {
            serverOwned = true,
            profileKey = context.profileKey,
            generationToken = context.generationToken,
            entity = context.entity,
            target = copy(context.target),
            travelKey = context.travelKey,
            bookingId = context.bookingId
        }
        local travelling = self._navigation:start(navigationContext)
        if not travelling.ok then
            self._active[context.profileKey] = nil
            pcall(self._despawn.despawn, self._despawn, {
                serverOwned = true, profileKey = context.profileKey,
                generationToken = context.generationToken, entity = context.entity
            })
            return travelling
        end
        self:_notify(context.profileKey, 'TRAVELLING', travelling.value)
    end
    return Result.ok({ state = self._active[context.profileKey].state, context = context })
end
Coordinator.spawn = Coordinator.handleAuthorization
function Coordinator:tick(atOrOptions)
    local result = self._navigation:tick(atOrOptions)
    local current = self._navigation:get()
    if current.ok and current.value.context and token(current.value.context.profileKey, 160) then self:_notify(current.value.context.profileKey, current.value.state, current.value) end
    return result
end
function Coordinator:cleanup(profileKey, generationToken, returnWorker)
    if not token(profileKey, 160) or not token(generationToken, 240) then return invalid('NPC cleanup references are invalid') end
    local active = self._active[profileKey]
    if not active then return Result.err(Codes.ENTITY_NOT_FOUND, 'NPC coordinator binding was not found') end
    if active.generationToken ~= generationToken then return Result.err(Codes.ENTITY_GENERATION_MISMATCH, 'NPC cleanup generation does not match') end
    local result = self._despawn:despawn({ serverOwned = true, profileKey = profileKey, generationToken = generationToken, entity = active.entity, returnWorker = returnWorker == true })
    if result.ok then self:_notify(profileKey, 'DESPAWNED', result.value); self._active[profileKey] = nil end
    return result
end

function Coordinator:cleanupAll(returnWorker)
    local results = {}
    for profileKey, active in pairs(copy(self._active)) do
        results[#results + 1] = self:cleanup(profileKey, active.generationToken, returnWorker)
    end
    return Result.ok(results, { count = #results, idempotent = #results == 0 })
end

function Coordinator:get(profileKey)
    if not token(profileKey, 160) then return invalid('NPC profile key is invalid') end
    local active = self._active[profileKey]
    if not active then return Result.err(Codes.ENTITY_NOT_FOUND, 'NPC coordinator binding was not found') end
    return Result.ok(copy(active))
end
-- Build the optional FiveM projection only when all required natives and
-- controllers are present. The logical server flow remains usable without a
-- physical projection (for example in a headless contract test).
local function runtimeCoordinator()
    local registryType, spawnType = NightShift.ClientNpcEntityRegistry, NightShift.ClientNpcSpawn
    local navigationType, despawnType = NightShift.ClientNpcNavigation, NightShift.ClientNpcDespawn
    if type(registryType) ~= 'table' or type(spawnType) ~= 'table'
        or type(navigationType) ~= 'table' or type(despawnType) ~= 'table' then return nil end
    if type(registryType.new) ~= 'function' or type(spawnType.new) ~= 'function'
        or type(navigationType.new) ~= 'function' or type(despawnType.new) ~= 'function' then return nil end
    local doesEntityExist = rawget(_G, 'DoesEntityExist')
    local getEntityCoords = rawget(_G, 'GetEntityCoords')
    local playerPedId = rawget(_G, 'PlayerPedId')
    local taskGoStraight = rawget(_G, 'TaskGoStraightToCoord')
    local createPed = rawget(_G, 'CreatePed')
    local requestModel = rawget(_G, 'RequestModel')
    local hasModelLoaded = rawget(_G, 'HasModelLoaded')
    if type(doesEntityExist) ~= 'function' or type(getEntityCoords) ~= 'function'
        or type(playerPedId) ~= 'function' or type(taskGoStraight) ~= 'function'
        or type(createPed) ~= 'function' or type(requestModel) ~= 'function'
        or type(hasModelLoaded) ~= 'function' then return nil end
    local function coords(entity)
        local ok, value = pcall(getEntityCoords, entity)
        if not ok or value == nil then return nil end
        local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not x or not y or not z then return nil end
        return { x = x, y = y, z = z }
    end
    local function distance(left, right)
        local a, b = coords(left), right
        if not a or type(b) ~= 'table' then return nil end
        local x, y, z = tonumber(b.x), tonumber(b.y), tonumber(b.z)
        if not x or not y or not z then return nil end
        local dx, dy, dz = a.x - x, a.y - y, a.z - z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local function loadModel(model)
        local hashFn = rawget(_G, 'GetHashKey')
        local hash = type(hashFn) == 'function' and hashFn(model) or model
        local requested = pcall(requestModel, hash)
        if not requested then return false end
        local timer, wait = rawget(_G, 'GetGameTimer'), rawget(_G, 'Wait')
        local deadline = type(timer) == 'function' and (tonumber(timer()) or 0) + 5000 or nil
        while true do
            local loaded, value = pcall(hasModelLoaded, hash)
            if loaded and value == true then return true end
            if deadline == nil or type(timer) ~= 'function' or (tonumber(timer()) or 0) >= deadline then return false end
            if type(wait) ~= 'function' then return false end
            wait(0)
        end
    end
    local registry = registryType.new({ entityExists = function(entity)
        local ok, value = pcall(doesEntityExist, entity)
        return ok and value == true
    end })
    local spawn = spawnType.new({
        registry = registry,
        modelAllowlist = NightShift.NpcStreamingConfig and NightShift.NpcStreamingConfig.modelAllowlist or {},
        loadModel = loadModel,
        createPed = function(model, candidate)
            local hashFn = rawget(_G, 'GetHashKey')
            local hash = type(hashFn) == 'function' and hashFn(model) or model
            local heading = tonumber(candidate.heading) or 0.0
            local ok, entity = pcall(createPed, 4, hash, candidate.x, candidate.y, candidate.z, heading, false, true)
            if not ok or entity == nil then return nil end
            return entity
        end,
        entityExists = function(entity)
            local ok, value = pcall(doesEntityExist, entity)
            return ok and value == true
        end
    })
    if not spawn then return nil end
    local streaming = NightShift.NpcStreamingConfig or {}
    local navigation = navigationType.new({
        registry = registry, arrivalRadius = streaming.arrivalRadius,
        navigationTimeout = streaming.navigationTimeout, stuckTimeout = streaming.stuckTimeout,
        playerAwayDistance = streaming.playerAwayDistance, distance = distance,
        playerDistance = function(context)
            return distance(playerPedId(), context and context.target)
        end,
        moveTo = function(entity, target)
            local ok = pcall(taskGoStraight, entity, target.x, target.y, target.z, 1.0, -1, target.heading or 0.0, 0.0)
            return ok
        end,
        entityExists = function(entity)
            local ok, value = pcall(doesEntityExist, entity)
            return ok and value == true
        end
    })
    if not navigation then return nil end
    local despawn = despawnType.new({
        registry = registry,
        fadeOut = function(entity)
            local native = rawget(_G, 'NetworkFadeOutEntity')
            if type(native) ~= 'function' then return true end
            return pcall(native, entity, true, false)
        end,
        deleteEntity = function(entity)
            local native = rawget(_G, 'DeleteEntity')
            if type(native) ~= 'function' then return true end
            return pcall(native, entity)
        end
    })
    if not despawn then return nil end
    return Coordinator.new({
        spawn = spawn, navigation = navigation, despawn = despawn,
        onState = function(state, payload)
            local send = rawget(_G, 'SendNUIMessage')
            if type(send) == 'function' then
                pcall(send, { type = 'nightshift:npc-state', state = state,
                    profileKey = payload and payload.profileKey, bookingId = payload and payload.bookingId })
            end
        end
    })
end

local runtime = runtimeCoordinator()
if runtime then
    NightShift.ClientNpcCoordinatorInstance = runtime
    local addEventHandler, getResourceName = rawget(_G, 'AddEventHandler'), rawget(_G, 'GetCurrentResourceName')
    if type(addEventHandler) == 'function' and type(getResourceName) == 'function' then
        local ownName = getResourceName()
        addEventHandler('onResourceStop', function(resourceName)
            if resourceName == ownName then
                runtime:cleanupAll(false)
                NightShift.ClientNpcCoordinatorInstance = nil
            end
        end)
    end
    local createThread, wait = rawget(_G, 'CreateThread'), rawget(_G, 'Wait')
    if type(createThread) == 'function' and type(wait) == 'function' then
        createThread(function()
            while NightShift.ClientNpcCoordinatorInstance == runtime do
                wait(250)
                if NightShift.ClientNpcCoordinatorInstance == runtime then runtime:tick() end
            end
        end)
    end
end

NightShift.ClientNpcCoordinator = Coordinator
