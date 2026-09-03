local function s19Check(condition, message)
    if not condition then error('S19 blacklist contract failed: ' .. message) end
end

local entries = {}
local nextId = 0
local fake = {}
function fake:findByScopeWorker(scopeType, scopeRef, workerId)
    for _, value in pairs(entries) do
        if value.scopeType == scopeType and value.scopeRef == scopeRef and value.workerProfileId == workerId and value.active then
            return NightShift.Result.ok(value)
        end
    end
    return NightShift.Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'not found')
end
function fake:listByScope(scopeType, scopeRef)
    local out = {}
    for _, value in pairs(entries) do if value.scopeType == scopeType and value.scopeRef == scopeRef and value.active then out[#out + 1] = value end end
    return NightShift.Result.ok(out)
end
function fake:create(value)
    nextId = nextId + 1
    local item = { id = nextId, scopeType = value.scopeType, scopeRef = value.scopeRef, workerProfileId = value.workerProfileId, reason = value.reason, active = true, version = 1 }
    entries[nextId] = item
    return NightShift.Result.ok(item)
end
function fake:deleteExpectedVersion(id, version)
    local value = entries[id]
    if not value or value.version ~= version then return NightShift.Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'version') end
    value.active = false; value.version = value.version + 1
    return NightShift.Result.ok({ removed = true })
end

if NightShift.BlacklistService then
    local service = assert(NightShift.BlacklistService.new({ repository = fake }))
    local added = service:add({ ref = 'player:1' }, 7, 'SAFETY')
    s19Check(added.ok, 'personal blacklist entry should be created')
    s19Check(service:isBlocked({ ref = 'player:1' }, 7).value == true, 'blacklisted worker should be excluded')
    s19Check(service:isBlocked({ ref = 'player:2' }, 7).value == false, 'blacklist must be scoped to actor')
    local filtered = service:filterWorkers({ ref = 'player:1' }, {{ profile = { id = 7 } }, { profile = { id = 8 } }})
    s19Check(filtered.ok and #filtered.value == 1 and filtered.value[1].profile.id == 8, 'filter must remove only blocked worker')
    s19Check(service:add({ ref = 'player:1' }, 7, 'SAFETY').metadata.idempotent == true, 'duplicate add should be idempotent')
    s19Check(service:remove({ ref = 'player:1' }, 7).ok, 'blacklist removal should be optimistic')
    print('NS-191 blacklist contracts passed: scoped exclusion, idempotency, and privacy filtering')
end
