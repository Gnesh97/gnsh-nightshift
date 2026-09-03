local function check(value, message) assert(value, message) end

local files = {
    '002_profiles.sql',
    '003_bookings.sql',
    '004_booking_events.sql',
    '005_npc_profiles.sql',
    '006_locations.sql',
    '007_payments.sql',
    '008_relationships.sql',
    '009_indexes.sql',
    '010_identity_profiles.sql',
    '011_booking_core.sql',
    '012_pricing_snapshots.sql',
    '013_location_resolver.sql',
    '014_npc_marketplace.sql',
    '015_reputation.sql',
    '016_reputation_compat.sql',
    '017_scheduling.sql',
    '018_blacklist.sql',
    '019_agencies.sql',
    '020_venues.sql',
    '021_settlement_commission_snapshots.sql',
    '022_audit.sql',
    '023_idempotency.sql'
}

local contents, allParts = {}, {}
for _, file in ipairs(files) do
    local handle = assert(io.open('sql/' .. file, 'r'), 'missing SQL migration: ' .. file)
    contents[file] = handle:read('*a')
    allParts[#allParts + 1] = contents[file]
    handle:close()
    check(contents[file]:match('%S') ~= nil, 'SQL migration must not be empty: ' .. file)
end

local all = table.concat(allParts, '\n')
for _, tableName in ipairs({
    'nightshift_worker_profiles', 'nightshift_client_profiles', 'nightshift_bookings',
    'nightshift_booking_events', 'nightshift_npc_profiles', 'nightshift_npc_workers',
    'nightshift_locations', 'nightshift_location_reservations', 'nightshift_room_reservations',
    'nightshift_booking_deposits', 'nightshift_payments', 'nightshift_reviews',
    'nightshift_favorites', 'nightshift_client_worker_relationships', 'nightshift_blacklist',
    'nightshift_agencies', 'nightshift_venues', 'nightshift_venue_slots'
}) do
    check(all:find(tableName, 1, true) ~= nil, 'required aggregate missing: ' .. tableName)
end

check(all:find('idempotency_key', 1, true) ~= nil, 'idempotency key column missing')
check(all:find('UNIQUE KEY', 1, true) ~= nil, 'unique idempotency/index constraint missing')
check(all:find('version INT UNSIGNED NOT NULL', 1, true) ~= nil, 'mutable aggregate version column missing')
check(contents['009_indexes.sql']:find('CREATE INDEX', 1, true) ~= nil, 'initial lookup indexes missing')
check(contents['010_identity_profiles.sql']:find('professionalism', 1, true) ~= nil, 'identity profile fields missing')
check(contents['010_identity_profiles.sql']:find('deposit_risk_score', 1, true) ~= nil, 'client deposit risk fields missing')
check(contents['011_booking_core.sql']:find('client_type', 1, true) ~= nil, 'booking participant columns missing')
check(contents['011_booking_core.sql']:find('old_state', 1, true) ~= nil, 'booking timeline state columns missing')
check(contents['013_location_resolver.sql']:find('location_type', 1, true) ~= nil, 'typed location columns missing')
check(contents['013_location_resolver.sql']:find('active_key', 1, true) ~= nil, 'atomic location reservation key missing')
check(contents['014_npc_marketplace.sql']:find('profile_type', 1, true) ~= nil, 'NPC profile persistence type column missing')
check(contents['014_npc_marketplace.sql']:find('price_class', 1, true) ~= nil, 'NPC marketplace price class column missing')
check(contents['014_npc_marketplace.sql']:find('reservation_key', 1, true) ~= nil, 'NPC worker reservation key column missing')
check(contents['015_reputation.sql']:find('reliability', 1, true) ~= nil, 'S17 client reliability migration must be registered')
check(contents['015_reputation.sql']:find('trust_score', 1, true) ~= nil, 'S17 relationship trust migration must be registered')
check(contents['016_reputation_compat.sql']:find('MODIFY COLUMN last_booking_id', 1, true) ~= nil, 'S17 relationship booking ID compatibility migration must be registered')
check(contents['017_scheduling.sql']:find('idx_nightshift_bookings_scheduled_due', 1, true) ~= nil, 'S18 scheduled booking due index must be registered')
check(contents['017_scheduling.sql']:find('idx_nightshift_bookings_no_show_due', 1, true) ~= nil, 'S18 no-show due index must be registered')
check(contents['018_blacklist.sql']:find('nightshift_blacklist', 1, true) ~= nil, 'S19 blacklist table must be registered')
check(contents['018_blacklist.sql']:find('uq_nightshift_blacklist_scope_worker', 1, true) ~= nil, 'S19 blacklist uniqueness constraint must be registered')
check(contents['019_agencies.sql']:find('commission_rate', 1, true) ~= nil, 'S23 agency commission field must be registered')
check(contents['020_venues.sql']:find('nightshift_venue_slots', 1, true) ~= nil, 'S23 venue slot aggregate must be registered')
check(contents['021_settlement_commission_snapshots.sql']:find('commission_snapshot', 1, true) ~= nil, 'S23 settlement snapshot field must be registered')
check(contents['022_audit.sql']:find('nightshift_audit_log', 1, true) ~= nil, 'S24 audit log table must be registered')
check(contents['023_idempotency.sql']:find('nightshift_idempotency', 1, true) ~= nil, 'S25 idempotency table must be registered')
check(contents['023_idempotency.sql']:find('uq_nightshift_idempotency_scope_key', 1, true) ~= nil, 'S25 idempotency uniqueness must be registered')
check(#NightShift.Migrations.DefinitionFiles == 23, 'S25 idempotency migration must be registered')
