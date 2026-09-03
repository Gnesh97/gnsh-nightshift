local check = function(value, message) assert(value, message) end
local Codes = NightShift.Errors.Codes

do
    local policy, err = NightShift.EntityOwnershipPolicy.new()
    check(policy and not err, 'entity ownership policy must initialize')
    local normalized = policy:normalize({
        profileKey = 'npc:one', travelKey = 'travel:one', bookingId = 'booking:one',
        generation = 1, generationToken = 'npc:npc:one:1', entity = 701,
        networkId = 9001, networkOwner = 42, state = 'BOUND', serverOwned = true
    })
    check(normalized.ok and normalized.value.logicalAuthority == 'SERVER_DB',
        'logical authority must remain server-owned')
    local changed = policy:classify(normalized.value, { entityPresent = true, networkOwner = 43, generationToken = 'npc:npc:one:1' })
    check(changed.ok and changed.value.status == 'BOUND' and changed.value.networkOwnerChanged,
        'network owner migration must not invalidate logical binding')
    local orphan = policy:reconcile(normalized.value, { entityPresent = false, generationToken = 'npc:npc:one:1' })
    check(orphan.ok and orphan.value.decision == 'PRESERVE_LOGICAL_RETRY_PHYSICAL',
        'missing physical entity must preserve logical state')
    local stale = policy:classify(normalized.value, { entityPresent = true, generationToken = 'npc:stale:2' })
    check(not stale.ok and stale.error.code == Codes.ENTITY_GENERATION_MISMATCH,
        'stale generation must be rejected')
    local forged = policy:normalize({ profileKey = 'npc:one', price = 100 })
    check(not forged.ok and forged.error.code == Codes.ENTITY_OWNERSHIP_INVALID,
        'ownership context must reject untrusted fields')
end

do
    local registry = assert(NightShift.NpcEntityRegistry.new({
        ownershipPolicy = assert(NightShift.EntityOwnershipPolicy.new())
    }))
    local created = assert(registry:register('npc:sync', {
        travelKey = 'travel:sync', bookingId = 'booking:sync', owner = 42, entity = 701, networkId = 88
    })).value
    local migrated = registry:validate('npc:sync', created.generationToken, { owner = 43 })
    check(migrated.ok, 'registry validation must tolerate OneSync network owner migration')
end

do
    local writes = {}
    local policy, err = NightShift.StateBagPolicy.new({
        setState = function(entity, key, value, replicated)
            writes[#writes + 1] = { entity = entity, key = key, value = value, replicated = replicated }
            return true
        end,
        getState = function(entity, key)
            for _, write in ipairs(writes) do if write.entity == entity and write.key == key then return write.value end end
            return nil
        end
    })
    check(policy and not err, 'state bag policy must initialize')
    check(not NightShift.StateBagPolicy.new({ config = { maxKeys = 0 } }),
        'state bag key bound must fail closed')
    local metadata = policy:fromLogical({ profileKey = 'npc:one', bookingId = 'booking:one', generation = 2,
        generationToken = 'npc:npc:one:2', state = 'BOUND' })
    check(metadata.ok, 'logical binding must map to granular state bag keys')
    local written = policy:write(701, metadata.value)
    check(written.ok and #written.value.keys == 5, 'state bag writer must write bounded scalar metadata')
    local read = policy:read(701)
    check(read.ok and read.value.metadata['nightshift:bookingId'] == 'booking:one',
        'state bag metadata must be recreateable')
    local smallPolicy = assert(NightShift.StateBagPolicy.new({ config = { maxBytes = 128 } }))
    local giant = smallPolicy:normalize({ ['nightshift:npcId'] = 'npc:one', ['nightshift:bookingId'] = 'booking:one',
        ['nightshift:generationToken'] = string.rep('x', 240), ['nightshift:entityState'] = 'BOUND', ['nightshift:generation'] = 2 })
    check(not giant.ok, 'state bag byte budget must reject oversized metadata')
    local secret = policy:normalize({ price = 500 })
    check(not secret.ok and secret.error.code == Codes.STATE_BAG_INVALID,
        'state bag policy must reject financial source-of-truth fields')
end

print('NS-280..NS-281 tests passed: logical authority, owner migration, generation, and recreateable state bags')
