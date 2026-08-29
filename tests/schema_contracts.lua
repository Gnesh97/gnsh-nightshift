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
    '011_booking_core.sql'
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
    'nightshift_favorites', 'nightshift_client_worker_relationships'
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
check(#NightShift.Migrations.DefinitionFiles == 11, 'S05 booking migration must be registered')
