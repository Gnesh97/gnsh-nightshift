local function check(value, message) assert(value, message) end
local function ok(result, message)
    check(type(result) == 'table' and result.ok == true, message or 'expected successful result')
    return result.value
end
local function err(result, code, message)
    check(type(result) == 'table' and result.ok == false, message or 'expected failed result')
    check(result.error and result.error.code == code, (message or 'unexpected error') .. ': ' .. tostring(result.error and result.error.code))
end

local function frameworkFixture()
    local callbacks = {}
    local raw = {
        identifier = 'license:test',
        characterId = 'char-1',
        characterName = 'Test Player',
        job = { name = 'nightshift', grade = 2, onDuty = true }
    }
    local adapter = NightShift.FrameworkInterface.new({
        name = 'fixture',
        available = true,
        capabilities = { identity = true, characterId = true, job = true, grade = true, duty = true, lifecycle = true },
        getPlayer = function(source) return source == 7 and raw or nil end,
        isPlayerLoaded = function(source) return source == 7 end,
        getIdentifier = function(player) return player and player.identifier end,
        getCharacterId = function(player) return player and player.characterId end,
        getCharacterName = function(player) return player and player.characterName end,
        getJob = function(player) return player and player.job end,
        getJobName = function(player) return player and player.job.name end,
        getJobGrade = function(player) return player and player.job.grade end,
        isOnDuty = function(player) return player and player.job.onDuty end,
        onPlayerLoaded = function(handler) callbacks.loaded = handler; return 'loaded' end,
        onPlayerUnloaded = function(handler) callbacks.unloaded = handler; return 'unloaded' end,
        onJobChanged = function(handler) callbacks.job = handler; return 'job' end,
        onDutyChanged = function(handler) callbacks.duty = handler; return 'duty' end
    })
    return adapter, callbacks, raw
end

do
    local adapter, callbacks, raw = frameworkFixture()
    check(adapter and adapter.name == 'fixture', 'framework interface should create adapter')
    local identity = ok(adapter:getPlayer(7), 'framework identity should normalize')
    check(identity.source == 7 and identity.identifier == 'license:test' and identity.characterId == 'char-1', 'normalized identity fields')
    check(identity.job.name == 'nightshift' and identity.job.grade == 2 and identity.job.onDuty == true, 'normalized job fields')
    check(identity.raw == nil and identity.player == nil, 'raw framework object must not leak')
    check(adapter:isPlayerLoaded(7) == true and adapter:isPlayerLoaded(8) == false, 'loaded predicate')
    check(adapter:onPlayerLoaded(function() end) == 'loaded', 'lifecycle registration')
    check(callbacks.loaded ~= nil, 'lifecycle callback should be registered')
    local delivered
    adapter:onPlayerLoaded(function(value) delivered = value end)
    callbacks.loaded(7, raw)
    check(delivered and delivered.identifier == 'license:test' and delivered.raw == nil, 'callback receives normalized DTO')
    local caps = adapter:getCapabilities()
    caps.identity = false
    check(adapter:getCapabilities().identity == true, 'capabilities must be copied')
end

do
    local adapter, error = NightShift.FrameworkInterface.new({ name = 'invalid' })
    check(adapter == nil and error and error.code == 'PROVIDER_INVALID', 'framework contract must validate required methods')
end

local function qbPlayer()
    return {
        PlayerData = {
            license = 'license:qb', citizenid = 'CID-QB',
            charinfo = { firstname = 'Ada', lastname = 'Qb' },
            job = { name = 'worker', grade = { level = 3, name = 'Senior' }, onduty = true }
        },
        Functions = {}
    }
end

do
    local player = qbPlayer()
    local registrations = {}
    local core = { Functions = { GetPlayer = function(source) return source == 11 and player or nil end } }
    local adapter = NightShift.FrameworkAdapters.qbcore.new({
        core = core,
        eventRegistrar = function(name, callback) registrations[name] = callback; return name end
    })
    local identity = ok(adapter:getPlayer(11), 'QBCore adapter should normalize player')
    check(identity.identifier == 'license:qb' and identity.characterId == 'CID-QB' and identity.characterName == 'Ada Qb', 'QBCore identity normalization')
    check(identity.job.name == 'worker' and identity.job.grade == 3 and identity.job.onDuty == true, 'QBCore job normalization')
    check(adapter.name == 'qbcore' and adapter:getCapabilities().native == true, 'QBCore capability declaration')
    local delivered
    adapter:onJobChanged(function(value) delivered = value end)
    check(registrations['QBCore:Server:OnJobUpdate'] ~= nil, 'QBCore job event registration')
    registrations['QBCore:Server:OnJobUpdate'](11, { name = 'worker', grade = { level = 4 }, onduty = false })
    check(delivered and delivered.job.grade == 4 and delivered.job.onDuty == false, 'QBCore job event normalization')
end

do
    local player = { PlayerData = { license = 'license:qbox', citizenid = 'CID-QBOX', charinfo = { firstname = 'Q', lastname = 'Box' }, job = { name = 'qbox', grade = 4, onduty = true } } }
    local adapter = NightShift.FrameworkAdapters.qbox.new({
        getPlayer = function(source) return source == 12 and player or nil end,
        eventRegistrar = function(name, callback) return { name = name, callback = callback } end
    })
    local identity = ok(adapter:getPlayer(12), 'Qbox adapter should normalize player')
    check(identity.identifier == 'license:qbox' and identity.characterId == 'CID-QBOX' and identity.job.grade == 4, 'Qbox identity/job normalization')
    check(adapter.name == 'qbox' and adapter:getCapabilities().qboxNative == true, 'Qbox must be an independent adapter')
end

do
    local xPlayer = {
        identifier = 'license:esx',
        getIdentifier = function(self) return self.identifier end,
        getName = function() return 'Esx Player' end,
        getJob = function() return { name = 'night', grade = 2 } end
    }
    local adapter = NightShift.FrameworkAdapters.esx.new({
        getPlayerFromId = function(source) return source == 13 and xPlayer or nil end,
        eventRegistrar = function(name, callback) return { name = name, callback = callback } end
    })
    local identity = ok(adapter:getPlayer(13), 'ESX adapter should normalize xPlayer')
    check(identity.identifier == 'license:esx' and identity.characterId == 'license:esx' and identity.characterName == 'Esx Player', 'ESX identity normalization')
    check(identity.job.name == 'night' and identity.job.grade == 2 and identity.job.onDuty == true, 'ESX internal duty fallback')
    check(adapter:getCapabilities().duty == false and adapter:getCapabilities().internalDuty == true, 'ESX duty capability fallback')
    check(adapter:setAvailability(13, false).ok and ok(adapter:getPlayer(13)).job.onDuty == false, 'ESX availability fallback')
end

do
    local adapter = NightShift.FrameworkAdapters.standalone.new({
        identifierResolver = function(source) return 'license:standalone:' .. tostring(source) end,
        nameResolver = function() return 'Standalone Player' end,
        isPlayerLoaded = function(source) return source == 14 end
    })
    local identity = ok(adapter:getPlayer(14), 'standalone adapter should normalize identity')
    check(identity.identifier == 'license:standalone:14' and identity.characterId == identity.identifier, 'standalone identity fallback')
    check(identity.job.name == 'unassigned' and identity.job.onDuty == true, 'standalone no-job profile')
    check(adapter:getCapabilities().job == false and adapter:getCapabilities().availability == true, 'standalone reduced capabilities')
    local nativeOnly = NightShift.FrameworkAdapters.standalone.new()
    err(nativeOnly:getPlayer(14), 'PROVIDER_UNAVAILABLE', 'standalone must not fabricate missing identifiers')
end

do
    local balance = 100
    local observedKey
    local money = NightShift.MoneyInterface.new({
        name = 'fixture', accounts = { cash = true }, capabilities = { atomicTransfer = false, idempotency = true },
        has = function(_, _, amount) return balance >= amount end,
        remove = function(_, _, amount, _, key) observedKey = key; balance = balance - amount; return true end,
        add = function(_, _, amount, _, key) observedKey = key; balance = balance + amount; return true end
    })
    check(ok(money:has(1, 'cash', 50)) == true, 'money has')
    err(money:has(1, 'bank', 10), 'MONEY_UNSUPPORTED_ACCOUNT', 'unsupported account should fail')
    err(money:remove(1, 'cash', 150), 'MONEY_INSUFFICIENT_FUNDS', 'insufficient funds should fail')
    check(ok(money:remove(1, 'cash', 40, 'test debit', 'deposit:test')).amount == 40 and balance == 60 and observedKey == 'deposit:test', 'money remove')
    check(ok(money:add(1, 'cash', 20, 'test credit', 'refund:test')).amount == 20 and balance == 80 and observedKey == 'refund:test', 'money add')
    check(money:getCapabilities().atomicTransfer == false, 'money capability declaration')
end

do
    local balance = 75
    local player = qbPlayer()
    player.Functions.GetMoney = function(_, account) return account == 'cash' and balance or 0 end
    player.Functions.RemoveMoney = function(_, account, amount) if account ~= 'cash' or balance < amount then return false end; balance = balance - amount; return true end
    player.Functions.AddMoney = function(_, account, amount) if account ~= 'cash' then return false end; balance = balance + amount; return true end
    local adapter = NightShift.MoneyAdapters.qbcore.new({ playerResolver = function(source) return source == 21 and player or nil end })
    check(ok(adapter:has(21, 'cash', 50)) == true, 'QBCore money has')
    check(ok(adapter:remove(21, 'cash', 25)).amount == 25 and balance == 50, 'QBCore money remove')
    check(ok(adapter:add(21, 'cash', 10)).amount == 10 and balance == 60, 'QBCore money add')
    player.Functions.RemoveMoney = function() return false end
    err(adapter:remove(21, 'cash', 1), 'MONEY_OPERATION_FAILED', 'QBCore false removal must fail closed')
end

do
    local balance = 80
    local adapter = NightShift.MoneyAdapters.qbox.new({
        getMoney = function(_, account) return account == 'bank' and balance or 0 end,
        removeMoney = function(_, account, amount) if account ~= 'bank' or balance < amount then return false end; balance = balance - amount; return true end,
        addMoney = function(_, account, amount) if account ~= 'bank' then return false end; balance = balance + amount; return true end
    })
    check(ok(adapter:has(22, 'bank', 80)) == true, 'Qbox money has')
    check(ok(adapter:remove(22, 'bank', 30)).amount == 30 and balance == 50, 'Qbox money remove')
end

do
    local balance = 60
    local xPlayer = {
        getAccount = function(_, name) return name == 'bank' and { money = balance } or nil end,
        removeAccountMoney = function(_, name, amount) if name ~= 'bank' or balance < amount then return false end; balance = balance - amount; return true end,
        addAccountMoney = function(_, name, amount) if name ~= 'bank' then return false end; balance = balance + amount; return true end
    }
    local adapter = NightShift.MoneyAdapters.esx.new({ getPlayerFromId = function(source) return source == 23 and xPlayer or nil end })
    check(ok(adapter:has(23, 'bank', 50)) == true, 'ESX money has')
    check(ok(adapter:remove(23, 'bank', 20)).amount == 20 and balance == 40, 'ESX money remove')
    xPlayer.removeAccountMoney = function() return false end
    err(adapter:remove(23, 'bank', 1), 'MONEY_OPERATION_FAILED', 'ESX false removal must fail closed')
end

do
    local balance = 100
    local adapter = NightShift.MoneyAdapters.standalone.new({ enabled = true, ledger = {
        has = function(_, _, amount) return balance >= amount end,
        remove = function(_, _, amount) balance = balance - amount; return true end,
        add = function(_, _, amount) balance = balance + amount; return true end
    } })
    check(ok(adapter:remove(1, 'cash', 10)).amount == 10 and balance == 90, 'standalone money ledger')
    local disabled = NightShift.MoneyAdapters.standalone.new({ enabled = false })
    err(disabled:has(1, 'cash', 1), 'MONEY_UNAVAILABLE', 'disabled standalone money should fail closed')
end

do
    local phone = NightShift.OptionalProviders.Phone.new()
    check(phone:isAvailable() == false, 'missing phone should be unavailable')
    err(phone:openApp(1, 'browse', {}), 'CAPABILITY_UNAVAILABLE', 'missing phone operation')
    local pushed
    phone = NightShift.OptionalProviders.Phone.new({ available = true, pushNotification = function(source, payload) pushed = { source = source, payload = payload }; return true end })
    check(phone:isAvailable() == true and ok(phone:pushNotification(1, { title = 'NightShift' })).delivered == true, 'phone provider operation')
    check(pushed and pushed.source == 1, 'phone provider receives payload')
end

do
    local housing = NightShift.OptionalProviders.Housing.new()
    err(housing:reserve('room-1', 'booking-1', 30), 'CAPABILITY_UNAVAILABLE', 'missing housing must fail closed')
    local reserved
    housing = NightShift.OptionalProviders.Housing.new({ reserve = function(location, booking, ttl) reserved = { location, booking, ttl }; return true end })
    check(ok(housing:reserve('room-1', 'booking-1', 30)).reserved == true and reserved[2] == 'booking-1', 'housing reserve')
    local motel = NightShift.OptionalProviders.Motel.new({ available = true, validate = function() return true end })
    check(ok(motel:validate(1, 'room-1', {})).valid == true, 'motel validation')
end

do
    local dispatch = NightShift.OptionalProviders.Dispatch.new()
    check(ok(dispatch:emitSafetyAlert({ code = 'test' })).skipped == true, 'dispatch missing should degrade gracefully')
    local appearance = NightShift.OptionalProviders.Appearance.new()
    check(ok(appearance:applyNPCProfile(1, { id = 'npc' })).fallback == true, 'appearance missing should use fallback')
    local evidence = NightShift.OptionalProviders.Evidence.new()
    check(ok(evidence:record({ event = 'test' })).skipped == true, 'evidence missing should degrade gracefully')
    local target = NightShift.OptionalProviders.Target.new()
    check(ok(target:registerZone('nightshift', {})).fallback == true, 'target missing should use fallback')
    local notify = NightShift.OptionalProviders.Notify.new()
    check(ok(notify:send(1, { message = 'test' })).fallback == true, 'notify missing should use fallback')
end

do
    local standalone = NightShift.FrameworkAdapters.standalone.new({ available = true })
    local resolver = NightShift.ProviderResolver.new({
        frameworkAdapters = { standalone = standalone },
        moneyAdapters = { standalone = NightShift.MoneyAdapters.standalone.new({ enabled = false }) },
        resourceState = function(name) return name == 'qb-core' and 'started' or 'missing' end
    })
    local resolved = ok(resolver:resolve({ provider = { mode = 'explicit', name = 'standalone' }, features = {} }), 'explicit provider resolve')
    check(resolved.framework.name == 'standalone' and resolved.money.name == 'standalone', 'resolved adapters')
    check(type(resolved.framework.getPlayer) == 'function' and type(resolved.money.getCapabilities) == 'function', 'resolved adapter methods must survive Result copying')
    check(resolved.framework._core == nil and resolved.framework._functions == nil and resolved.money._ledger == nil, 'resolved adapters must not expose raw provider handles')
    check(resolved.diagnostics.selected == 'standalone', 'resolver diagnostics')
    local bootConfig = NightShift.Validators.copy(NightShift.DefaultConfig)
    local bootOk, bootResult = NightShift.Server.bootstrap({ config = bootConfig, providerResolver = resolver })
    check(bootOk and bootResult.adapters.providers.framework.name == 'standalone', 'bootstrap should expose resolved providers')
    bootConfig.provider = { mode = 'auto' }
    bootOk, bootResult = NightShift.Server.bootstrap({ config = bootConfig, providerResolver = resolver })
    check(bootOk and bootResult.adapters.providers.diagnostics.mode == 'auto', 'bootstrap should use injected resolver for auto mode')

    local auto = NightShift.ProviderResolver.new({
        frameworkAdapters = {
            qbcore = NightShift.FrameworkAdapters.qbcore.new({ core = { Functions = { GetPlayer = function() return nil end } } }),
            qbox = NightShift.FrameworkAdapters.qbox.new({ getPlayer = function() return nil end })
        },
        resourceState = function(name) if name == 'qb-core' or name == 'qbx_core' then return 'started' end; return 'missing' end
    })
    err(auto:resolve({ provider = { mode = 'auto' }, features = {} }), 'PROVIDER_AMBIGUOUS', 'ambiguous auto detection must fail')

    local missing = NightShift.ProviderResolver.new({ frameworkAdapters = {} })
    err(missing:resolve({ provider = { mode = 'explicit', name = 'qbcore' }, features = {} }), 'PROVIDER_UNAVAILABLE', 'missing explicit provider must fail')

    local dependency = NightShift.ProviderResolver.new({
        frameworkAdapters = { qbcore = NightShift.FrameworkAdapters.qbcore.new({ core = { Functions = { GetPlayer = function() return nil end } } }) },
        moneyAdapters = { qbcore = NightShift.MoneyAdapters.qbcore.new({ playerResolver = function() return nil end }) },
        resourceState = function() return 'missing' end
    })
    err(dependency:resolve({ provider = { mode = 'explicit', name = 'qbcore' }, features = {} }), 'PROVIDER_DEPENDENCY_MISSING', 'stopped framework dependency must fail')
end

print('NS-030..NS-037 tests passed: framework, money, optional providers, and resolver contracts')
