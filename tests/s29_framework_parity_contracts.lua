local function check(value, message) assert(value, message) end

local function expectOk(result, message)
    check(type(result) == 'table' and result.ok == true, message or 'expected successful result')
    return result.value
end

local function expectError(result, code, message)
    check(type(result) == 'table' and result.ok == false, message or 'expected failed result')
    check(result.error and result.error.code == code, (message or 'unexpected error') .. ': ' .. tostring(result.error and result.error.code))
end

local function qbPlayer(source, provider)
    return {
        PlayerData = {
            source = source,
            license = 'license:' .. provider,
            citizenid = 'CID-' .. provider,
            charinfo = { firstname = provider, lastname = 'Player' },
            job = { name = 'nightshift', grade = { level = 2 }, onduty = true }
        },
        Functions = {}
    }
end

do
    local source = 31
    local active = qbPlayer(source, 'qbcore')
    local registrations = {}
    local core = { Functions = { GetPlayer = function(id) return id == source and active or nil end } }
    local adapter = NightShift.FrameworkAdapters.qbcore.new({
        core = core,
        eventRegistrar = function(name, callback) registrations[name] = callback; return name end
    })
    local seen = {}

    check(adapter:onPlayerLoaded(function(value) seen.loaded = value end) == 'QBCore:Server:PlayerLoaded', 'QBCore loaded event')
    check(adapter:onPlayerUnloaded(function(value) seen.unloaded = value end) == 'QBCore:Server:PlayerUnload', 'QBCore unload event')
    check(adapter:onJobChanged(function(value) seen.job = value end) == 'QBCore:Server:OnJobUpdate', 'QBCore job event')
    check(adapter:onDutyChanged(function(value) seen.duty = value end) == 'QBCore:Server:SetDuty', 'QBCore duty event')

    registrations['QBCore:Server:PlayerLoaded'](active)
    check(seen.loaded and seen.loaded.source == source and seen.loaded.provider == 'qbcore', 'QBCore loaded payload normalization')
    registrations['QBCore:Server:OnJobUpdate'](source, { name = 'nightshift', grade = { level = 4 }, onduty = false })
    check(seen.job and seen.job.job.grade == 4 and seen.job.job.onDuty == false, 'QBCore job payload normalization')
    registrations['QBCore:Server:SetDuty'](source, false)
    check(seen.duty and seen.duty.job.onDuty == false, 'QBCore duty boolean normalization')

    active = nil
    registrations['QBCore:Server:PlayerUnload'](source)
    check(seen.unloaded and seen.unloaded.source == source and seen.unloaded.loaded == false, 'QBCore unload must use the last normalized identity')
    check(seen.unloaded.job.onDuty == false, 'QBCore unload snapshot must include the latest duty state')
    check(adapter:getLastIdentity(source) == nil, 'QBCore logout must release the identity snapshot')
end

do
    local source = 32
    local active = qbPlayer(source, 'qbox')
    local registrations = {}
    local adapter = NightShift.FrameworkAdapters.qbox.new({
        getPlayer = function(id) return id == source and active or nil end,
        eventRegistrar = function(name, callback) registrations[name] = callback; return name end
    })
    local seen = {}

    check(adapter:onPlayerLoaded(function(value) seen.loaded = value end) == 'QBCore:Server:PlayerLoaded', 'Qbox loaded event')
    local unloadEvents = adapter:onPlayerUnloaded(function(value) seen.unloaded = value end)
    check(type(unloadEvents) == 'table' and #unloadEvents == 3, 'Qbox must register logout and disconnect cleanup events')
    check(registrations['QBCore:Server:OnPlayerUnload'] ~= nil and registrations['qbx_core:server:playerLoggedOut'] ~= nil and registrations['playerDropped'] ~= nil, 'Qbox logout event registrations')
    check(adapter:onJobChanged(function(value) seen.job = value end) == 'QBCore:Server:OnJobUpdate', 'Qbox job event')
    check(adapter:onDutyChanged(function(value) seen.duty = value end) == 'QBCore:Server:SetDuty', 'Qbox duty event')

    registrations['QBCore:Server:PlayerLoaded'](active)
    check(seen.loaded and seen.loaded.source == source and seen.loaded.provider == 'qbox', 'Qbox loaded event normalization')
    registrations['QBCore:Server:OnJobUpdate'](source, { name = 'nightshift', grade = 3, onduty = true })
    check(seen.job and seen.job.job.grade == 3 and seen.job.job.onDuty == true, 'Qbox job payload normalization')
    registrations['QBCore:Server:SetDuty'](source, false)
    check(seen.duty and seen.duty.job.onDuty == false, 'Qbox duty boolean normalization')

    active = nil
    local previousSource = _G.source
    _G.source = source
    registrations['playerDropped']('quit')
    _G.source = previousSource
    check(seen.unloaded and seen.unloaded.source == source and seen.unloaded.loaded == false, 'Qbox disconnect must use the last normalized identity')
    check(seen.unloaded.job.onDuty == false, 'Qbox disconnect snapshot must include the latest duty state')
    check(adapter:getLastIdentity(source) == nil, 'Qbox disconnect must release the identity snapshot')

    active = qbPlayer(source, 'qbox-reconnect')
    registrations['QBCore:Server:PlayerLoaded'](active)
    active = nil
    registrations['qbx_core:server:playerLoggedOut'](source)
    check(seen.unloaded and seen.unloaded.source == source and seen.unloaded.loaded == false, 'Qbox explicit logout must use the last normalized identity')
end

do
    local source = 33
    local active = {
        identifier = 'license:esx',
        getIdentifier = function(self) return self.identifier end,
        getName = function() return 'ESX Player' end,
        getJob = function() return { name = 'nightshift', grade = 2 } end
    }
    local registrations = {}
    local adapter = NightShift.FrameworkAdapters.esx.new({
        getPlayerFromId = function(id) return id == source and active or nil end,
        eventRegistrar = function(name, callback) registrations[name] = callback; return name end
    })
    local seen = {}

    check(adapter:onPlayerLoaded(function(value) seen.loaded = value end) == 'esx:playerLoaded', 'ESX loaded event')
    check(adapter:onPlayerUnloaded(function(value) seen.unloaded = value end) == 'playerDropped', 'ESX unload event')
    check(adapter:onJobChanged(function(value) seen.job = value end) == 'esx:setJob', 'ESX job event')
    check(adapter:onDutyChanged(function(value) seen.duty = value end) == 'nightshift:esx:dutyChanged', 'ESX internal duty event')

    registrations['esx:playerLoaded'](source, active)
    check(seen.loaded and seen.loaded.source == source and seen.loaded.provider == 'esx', 'ESX loaded payload normalization')
    registrations['esx:setJob'](source, { name = 'nightshift', grade = 5 })
    check(seen.job and seen.job.job.grade == 5, 'ESX job payload normalization')
    registrations['nightshift:esx:dutyChanged'](source, { onDuty = false })
    check(seen.duty and seen.duty.job.onDuty == false, 'ESX internal duty payload normalization')

    active = nil
    registrations['playerDropped'](source, 'quit')
    check(seen.unloaded and seen.unloaded.source == source and seen.unloaded.loaded == false, 'ESX unload must use the last normalized identity')
    check(seen.unloaded.job.onDuty == false, 'ESX unload snapshot must include the latest duty state')
    check(adapter:getLastIdentity(source) == nil, 'ESX logout must release the identity snapshot')
end

do
    local player = qbPlayer(34, 'qbox-core')
    local core = {}
    function core:GetPlayer(id) return id == 34 and player or nil end
    local previousExports = _G.exports
    _G.exports = { qbx_core = core }
    local adapter = NightShift.FrameworkAdapters.qbox.new()
    _G.exports = previousExports
    local identity = expectOk(adapter:getPlayer(34), 'Qbox core proxy should normalize player')
    check(identity.provider == 'qbox' and identity.characterId == 'CID-qbox-core', 'Qbox core proxy identity')
    check(adapter:getCapabilities().qboxNative == true, 'Qbox core proxy capability')
end

do
    local removed = {}
    local adapter = NightShift.FrameworkAdapters.qbox.new({
        getPlayer = function() return nil end,
        eventRegistrar = function(name)
            if name == 'qbx_core:server:playerLoggedOut' then error('event registration unavailable') end
            return name
        end,
        eventUnregistrar = function(token) removed[#removed + 1] = token end
    })
    local token, registrationError = adapter:onPlayerUnloaded(function() end)
    check(token == nil and registrationError and registrationError.error
        and registrationError.error.code == 'PROVIDER_UNAVAILABLE', 'Qbox partial event registration must fail closed')
    check(#removed == 1 and removed[1] == 'QBCore:Server:OnPlayerUnload', 'Qbox partial event registration must rollback prior tokens')
end

do
    local source = 36
    local active = qbPlayer(source, 'qbox-multi')
    local registrations = {}
    local function emit(name, ...)
        for _, callback in ipairs(registrations[name] or {}) do callback(...) end
    end
    local adapter = NightShift.FrameworkAdapters.qbox.new({
        getPlayer = function(id) return id == source and active or nil end,
        eventRegistrar = function(name, callback)
            registrations[name] = registrations[name] or {}
            registrations[name][#registrations[name] + 1] = callback
            return name .. ':' .. tostring(#registrations[name])
        end
    })
    local firstCalls, secondCalls = 0, 0
    adapter:onPlayerLoaded(function() end)
    adapter:onPlayerUnloaded(function(value)
        firstCalls = firstCalls + 1
        check(value.source == source and value.loaded == false, 'Qbox first unload subscriber normalization')
    end)
    adapter:onPlayerUnloaded(function(value)
        secondCalls = secondCalls + 1
        check(value.source == source and value.loaded == false, 'Qbox second unload subscriber normalization')
    end)

    emit('QBCore:Server:PlayerLoaded', active)
    active = nil
    local previousSource = _G.source
    _G.source = source
    emit('playerDropped', 'quit')
    _G.source = previousSource
    check(firstCalls == 1 and secondCalls == 1, 'Qbox unload snapshot must reach every subscriber')

    active = qbPlayer(source, 'qbox-multi-reconnect')
    emit('QBCore:Server:PlayerLoaded', active)
    active = nil
    _G.source = source
    emit('qbx_core:server:playerLoggedOut', source)
    _G.source = previousSource
    check(firstCalls == 2 and secondCalls == 2, 'Qbox duplicate logout paths must deliver once per subscriber')
end

do
    for _, case in ipairs({ { label = 'false', value = false }, { label = 'nil', value = nil } }) do
        local removed = {}
        local calls = 0
        local adapter = NightShift.FrameworkAdapters.qbox.new({
            getPlayer = function() return nil end,
            eventRegistrar = function(name)
                calls = calls + 1
                if calls == 2 then return case.value end
                return name
            end,
            eventUnregistrar = function(token) removed[#removed + 1] = token end
        })
        local token, registrationError = adapter:onPlayerUnloaded(function() end)
        check(token == false and registrationError == nil, 'Qbox ' .. case.label .. ' registration must not become success')
        check(#removed == 1 and removed[1] == 'QBCore:Server:OnPlayerUnload', 'Qbox ' .. case.label .. ' registration must rollback prior tokens')
    end
end

do
    local balance = 90
    local core = {
        GetMoney = function(source, account)
            return source == 35 and account == 'bank' and balance or nil
        end,
        RemoveMoney = function(source, account, amount)
            if source ~= 35 or account ~= 'bank' or balance < amount then return false end
            balance = balance - amount
            return true
        end,
        AddMoney = function(source, account, amount)
            if source ~= 35 or account ~= 'bank' then return false end
            balance = balance + amount
            return true
        end
    }
    local previousExports = _G.exports
    _G.exports = { qbx_core = core }
    local adapter = NightShift.MoneyAdapters.qbox.new()
    _G.exports = previousExports
    check(expectOk(adapter:has(35, 'bank', 90)) == true, 'Qbox core money proxy should read balance')
    check(expectOk(adapter:remove(35, 'bank', 25)).amount == 25 and balance == 65, 'Qbox core money proxy should remove')
    check(expectOk(adapter:add(35, 'bank', 10)).amount == 10 and balance == 75, 'Qbox core money proxy should add')
end

do
    local target = NightShift.OptionalProviders.Target.new()
    local notify = NightShift.OptionalProviders.Notify.new()
    local dispatch = NightShift.OptionalProviders.Dispatch.new()
    local appearance = NightShift.OptionalProviders.Appearance.new()
    check(expectOk(target:registerZone('nightshift', {}), 'provider-minimal target fallback').fallback == true, 'target absence must use interaction fallback')
    check(expectOk(notify:send(1, { message = 'provider-minimal' }), 'provider-minimal notification fallback').fallback == true, 'notify absence must use fallback')
    check(expectOk(dispatch:emitSafetyAlert({ code = 'provider-minimal' }), 'provider-minimal dispatch skip').skipped == true, 'dispatch absence must not block core')
    check(expectOk(appearance:applyNPCProfile(1, { id = 'provider-minimal' }), 'provider-minimal appearance fallback').fallback == true, 'appearance absence must use fallback')
    expectError(NightShift.OptionalProviders.Phone.new():openApp(1, 'browse', {}), 'CAPABILITY_UNAVAILABLE', 'phone absence must fail closed')
end

print('NS-290..NS-293 framework parity contracts passed')
