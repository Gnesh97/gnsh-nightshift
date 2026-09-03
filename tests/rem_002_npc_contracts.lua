local function check(value, message) assert(value, message) end

do
    local config = NightShift.Validators.copy(NightShift.DefaultConfig)
    config.features.physicalNpc = true
    config.npcStreaming.modelAllowlist = {}
    config.npcStreaming.defaultModel = nil
    local normalized, err = NightShift.Validators.validateConfig(config)
    check(not normalized and err and err.code == 'NPC_SPAWN_MODEL_NOT_ALLOWED',
        'physical NPC mode must reject an empty model allowlist')

    config = NightShift.Validators.copy(NightShift.DefaultConfig)
    config.features.physicalNpc = true
    config.npcStreaming.modelAllowlist = { ['a_m_m_business_01'] = true }
    config.npcStreaming.defaultModel = 'a_m_m_invalid'
    normalized, err = NightShift.Validators.validateConfig(config)
    check(not normalized and err and err.code == 'INVALID_CONFIG',
        'physical NPC mode must reject a default model outside the allowlist')

    config = NightShift.Validators.copy(NightShift.DefaultConfig)
    config.environment = 'production'
    config.npcStreaming.modelAllowlist = {}
    config.npcStreaming.defaultModel = nil
    normalized, err = NightShift.Validators.validateConfig(config)
    check(not normalized and err and err.code == 'NPC_SPAWN_MODEL_NOT_ALLOWED',
        'production config must fail closed when NPC model policy is empty')
end

do
    local started, navigated, despawned = 0, 0, 0
    local navigationContext
    local spawn = {
        spawn = function(_, authorization)
            started = started + 1
            return NightShift.Result.ok({
                serverOwned = true, profileKey = authorization.profileKey,
                generationToken = authorization.generationToken,
                travelKey = authorization.travelKey, bookingId = authorization.bookingId,
                generation = authorization.generation or 1, entity = authorization.entity or 501
            })
        end
    }
    local navigation = {
        start = function(_, context)
            navigated = navigated + 1
            navigationContext = NightShift.Validators.copy(context)
            return NightShift.Result.ok({ state = 'TRAVELLING', context = context })
        end,
        tick = function() return NightShift.Result.ok({ state = 'TRAVELLING' }) end,
        get = function() return NightShift.Result.ok({ state = 'TRAVELLING' }) end
    }
    local despawn = {
        despawn = function(_, context)
            despawned = despawned + 1
            return NightShift.Result.ok({ profileKey = context.profileKey,
                generationToken = context.generationToken, entity = context.entity })
        end
    }
    local coordinator = assert(NightShift.ClientNpcCoordinator.new({
        spawn = spawn, navigation = navigation, despawn = despawn
    }))
    local authorization = {
        serverOwned = true, profileKey = 'npc-profile:one',
        generationToken = 'npc-generation:one', generation = 1,
        travelKey = 'npc-travel:one', bookingId = 'booking:one', entity = 501,
        model = 'a_m_m_business_01', candidate = { kind = 'coords', x = 1, y = 2, z = 3 },
        target = { kind = 'coords', x = 10, y = 20, z = 30 }
    }
    local bound = coordinator:handleAuthorization(authorization)
    check(bound.ok and bound.value.state == 'TRAVELLING' and started == 1 and navigated == 1,
        'authorized NPC spawn must bind and start navigation')
    check(navigationContext.model == nil and navigationContext.candidate == nil
        and navigationContext.target.x == 10, 'navigation must receive only the narrow context contract')

    local stale = coordinator:handleAuthorization({
        serverOwned = true, profileKey = authorization.profileKey,
        generationToken = 'npc-generation:stale', generation = 2,
        travelKey = authorization.travelKey, bookingId = authorization.bookingId,
        entity = 502, model = authorization.model, candidate = authorization.candidate,
        target = authorization.target
    })
    check(not stale.ok and stale.error.code == NightShift.Errors.Codes.ENTITY_GENERATION_MISMATCH,
        'stale NPC generation must be rejected')

    local cleaned = coordinator:cleanup(authorization.profileKey, authorization.generationToken, true)
    check(cleaned.ok and despawned == 1, 'NPC cleanup must release the active generation')
    local repeated = coordinator:cleanupAll(true)
    check(repeated.ok and repeated.metadata and repeated.metadata.idempotent == true,
        'repeated NPC cleanup must be idempotent')
end

do
    local generatorCalls, createCalls = 0, 0
    local generator = {
        _config = { workerPool = { targetSize = 2, maxSize = 2 } },
        generate = function(_, options)
            generatorCalls = generatorCalls + 1
            return NightShift.Result.ok({
                profileKey = options.profileKey, role = 'WORKER', profileType = 'PERSISTENT',
                alias = options.profileKey, priceClass = 1, rating = 4,
                homeDistrict = 'vinewood', activeDistrict = 'vinewood',
                travelMode = 'WALK', availability = 'AVAILABLE'
            })
        end
    }
    local repository = {
        findWorkerByKey = function() return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        findProfileByKey = function() return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'missing') end,
        createProfile = function(_, profile) return NightShift.Result.ok({ insertId = profile.profileKey }) end,
        createWorker = function(_, worker) createCalls = createCalls + 1; return NightShift.Result.ok({ insertId = worker.id }) end
    }
    local service = assert(NightShift.NpcWorkerService.new({ generator = generator, repository = repository }))
    local first = service:ensurePool({ targetSize = 2, seed = 'rem002' })
    check(first.ok and #first.value == 2 and generatorCalls == 2 and createCalls == 2,
        'NPC pool ensure must create the configured target once')
    local second = service:ensurePool({ targetSize = 2, seed = 'rem002' })
    check(second.ok and #second.value == 2 and generatorCalls == 2 and createCalls == 2,
        'NPC pool ensure must be idempotent across repeated boots')
end

print('REM-002/003 NPC contracts passed: model policy, coordinator authority, stale generations, cleanup, and idempotent pool')
