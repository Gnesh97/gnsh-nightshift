local root = (... and ... ~= '') and (...) or '.'
local function load(path) dofile(root .. '/' .. path) end
load('shared/enums.lua'); load('shared/errors.lua'); load('shared/constants.lua'); load('shared/schemas.lua'); load('shared/validators.lua'); load('config/providers.lua'); load('config/features.lua'); load('config/services.lua'); load('config/locations.lua'); load('config/npc_profiles.lua'); load('config/npc_streaming.lua'); load('config/analytics.lua'); load('config/demand.lua'); load('config/pricing.lua'); load('config/cancellation.lua'); load('config/reputation.lua'); load('config/scheduling.lua'); load('config/recovery.lua'); load('config/security.lua'); load('config/heat.lua'); load('config/vice.lua'); load('config/demand_heat_feedback.lua'); load('config/standalone.lua'); load('config/config.lua'); load('server/core/result.lua'); load('server/core/clock.lua'); load('server/core/rate_limit.lua'); load('server/security/action_tokens.lua'); load('server/core/idempotency.lua'); load('server/core/logger.lua'); load('server/core/event_bus.lua'); load('server/core/summary_cache.lua'); load('server/api/dto.lua'); load('server/api/events.lua'); load('server/adapters/database/interface.lua'); load('server/adapters/database/oxmysql.lua'); load('server/core/migrations.lua'); load('server/bootstrap.lua'); load('client/bootstrap.lua')
load('shared/types/framework.lua')
load('server/adapters/framework/interface.lua')
load('server/adapters/framework/qbcore.lua')
load('server/adapters/framework/qbox.lua')
load('server/adapters/framework/esx.lua')
load('server/adapters/framework/standalone.lua')
load('server/adapters/money/interface.lua')
load('server/adapters/money/qbcore.lua')
load('server/adapters/money/qbox.lua')
load('server/adapters/money/esx.lua')
load('server/adapters/money/standalone.lua')
load('server/adapters/money/development.lua')
load('server/adapters/optional_base.lua')
load('server/adapters/phone/interface.lua')
load('server/adapters/phone/registry.lua')
load('server/integrations/phone/common.lua')
load('server/integrations/phone/generic.lua')
load('server/integrations/phone/lb.lua')
load('server/integrations/phone/qs.lua')
load('server/integrations/phone/qb.lua')
load('server/integrations/phone/yseries.lua')
load('server/adapters/housing/interface.lua')
load('server/adapters/housing/registry.lua')
load('server/adapters/motel/interface.lua')
load('server/adapters/motel/registry.lua')
load('server/adapters/motel/config_locations.lua')
load('server/api/location_provider_api.lua')
load('server/adapters/dispatch/interface.lua')
load('server/adapters/appearance/interface.lua')
load('server/adapters/evidence/interface.lua')
load('client/adapters/target/interface.lua')
load('client/adapters/notify/interface.lua')
load('client/core/result.lua')
load('server/adapters/provider_resolver.lua')
load('server/repositories/base_repository.lua')
load('server/repositories/idempotency_repository.lua')
load('server/domain/agency.lua')
load('server/repositories/agency_repository.lua')
load('server/services/identity_service.lua')
load('server/domain/worker_profile.lua')
load('server/repositories/worker_profile_repository.lua')
load('server/services/worker_profile_service.lua')
load('server/domain/client_profile.lua')
load('server/repositories/client_profile_repository.lua')
load('server/services/client_profile_service.lua')
load('config/permissions.lua')
load('server/services/permission_service.lua')
load('server/domain/booking.lua')
load('server/repositories/booking_repository.lua')
load('server/domain/location.lua')
load('server/repositories/location_repository.lua')
load('server/domain/location_reservation.lua')
load('server/repositories/location_reservation_repository.lua')
load('server/domain/venue.lua')
load('server/state/booking_state_machine.lua')
load('server/repositories/booking_event_repository.lua')
load('server/core/reservations.lua')
load('server/services/booking_timeline_service.lua')
load('server/repositories/audit_repository.lua')
load('server/repositories/analytics_repository.lua')
load('server/services/audit_service.lua')
load('server/services/analytics_service.lua')
load('server/services/diagnostics_service.lua')
load('server/domain/incident.lua')
load('server/services/incident_service.lua')
load('server/services/dispute_service.lua')
load('server/services/booking_reservation_service.lua')
load('server/services/location_service.lua')
load('server/services/location_reservation_service.lua')
load('server/services/vehicle_location_service.lua')
load('server/services/pickup_location_service.lua')
load('server/domain/npc_profile.lua')
load('server/repositories/npc_profile_repository.lua')
load('server/domain/relationship.lua')
load('server/repositories/review_repository.lua')
load('server/repositories/favorite_repository.lua')
load('server/repositories/relationship_repository.lua')
load('server/repositories/blacklist_repository.lua')
load('server/services/npc_profile_generator.lua')
load('server/services/npc_worker_service.lua')
load('server/services/marketplace_query_service.lua')
load('server/services/blacklist_service.lua')
load('server/domain/travel_plan.lua')
load('server/services/npc_travel_service.lua')
load('server/services/npc_streaming_budget_service.lua')
load('server/services/entity_ownership_policy.lua')
load('server/services/state_bag_policy.lua')
load('server/services/npc_entity_registry.lua')
load('server/services/npc_spawn_service.lua')
load('server/services/npc_arrival_service.lua')
load('client/npc/entity_registry.lua')
load('client/npc/spawn.lua')
load('client/npc/navigation.lua')
load('client/npc/despawn.lua')
load('client/npc/coordinator.lua')
load('client/worker_mode/customer_candidates.lua')
load('server/domain/district.lua')
load('server/services/district_service.lua')
load('server/domain/heat.lua')
load('server/services/heat_service.lua')
load('server/services/demand_service.lua')
load('server/services/demand_heat_feedback_service.lua')
load('server/services/vice_service.lua')
load('server/services/worker_availability_service.lua')
load('server/services/npc_customer_service.lua')
load('server/domain/price_quote.lua')
load('server/services/service_catalog.lua')
load('server/services/pricing_service.lua')
load('server/services/schedule_conflict_service.lua')
load('server/services/booking_service.lua')
load('server/services/venue_service.lua')
load('server/services/agency_service.lua')
load('server/services/agency_booking_service.lua')
load('server/jobs/scheduled_booking_job.lua')
load('server/jobs/heat_decay_job.lua')
load('server/jobs/no_show_job.lua')
load('server/services/client_booking_query_service.lua')
load('server/services/client_booking_command_service.lua')
load('server/domain/deposit.lua')
load('server/repositories/deposit_repository.lua')
load('server/services/deposit_service.lua')
load('server/repositories/payment_repository.lua')
load('server/services/settlement_service.lua')
load('server/services/refund_service.lua')
load('server/domain/negotiation.lua')
load('server/services/negotiation_service.lua')
load('server/services/appointment_session_service.lua')
load('server/services/worker_mode_service.lua')
load('server/services/client_mode_service.lua')
load('server/services/pickup_vehicle_service.lua')
load('server/services/pickup_mode_service.lua')
load('server/services/dual_travel_service.lua')
load('server/services/recovery_service.lua')
load('server/jobs/startup_recovery_job.lua')
load('server/services/reputation_service.lua')
load('server/services/review_service.lua')
load('server/services/favorite_service.lua')
load('server/services/relationship_service.lua')
load('server/services/book_again_service.lua')
load('server/api/exports.lua')
load('client/client_mode/pickup.lua')
load('server/dev/s13_smoke.lua')
load('server/dev/s14_smoke.lua')
load('server/dev/s15_smoke.lua')
load('client/interaction/session.lua')
load('client/safety/session.lua')
load('tests/s05_booking_contracts.lua')
load('tests/s06_financial_contracts.lua')
load('tests/s07_location_contracts.lua')
load('tests/s08_npc_contracts.lua')
load('tests/s09_npc_travel_contracts.lua')
load('tests/s10_worker_mode_contracts.lua')
load('tests/s10_smoke_contracts.lua')
load('tests/s11_negotiation_contracts.lua')
load('tests/s11_session_contracts.lua')
load('tests/s11_worker_mode_contracts.lua')
load('tests/s11_smoke_contracts.lua')
load('tests/core_contracts.lua')
load('tests/event_bus_contracts.lua')
load('tests/database_contracts.lua')
load('tests/migrations_contracts.lua')
load('tests/schema_contracts.lua')
load('tests/repository_contracts.lua')
load('tests/provider_contracts.lua')
load('tests/s04_profiles_contracts.lua')
load('tests/s12_client_booking_contracts.lua')
load('tests/s12_client_booking_commands.lua')
load('tests/s13_client_mode_contracts.lua')
load('tests/s14_pickup_contracts.lua')
load('tests/s15_dual_travel_contracts.lua')
load('tests/s17_reputation_review_contracts.lua')
load('tests/s18_scheduling_contracts.lua')
load('tests/s19_blacklist_contracts.lua')
load('tests/s19_incident_contracts.lua')
load('server/services/safety_service.lua')
load('tests/s19_safety_contracts.lua')
load('tests/s20_heat_contracts.lua')
load('tests/s20_heat_job_contracts.lua')
load('tests/s20_vice_contracts.lua')
load('tests/s20_demand_heat_contracts.lua')
load('tests/s20_config_contracts.lua')
load('tests/s21_phone_registry_contracts.lua')
load('tests/s21_phone_adapter_contracts.lua')
load('tests/s21_standalone_contracts.lua')
load('tests/nui_visibility_contracts.lua')
load('tests/s22_motel_contracts.lua')
load('tests/s22_housing_contracts.lua')
load('tests/s22_config_location_contracts.lua')
load('tests/s22_location_provider_api_contracts.lua')
load('tests/s22_review_contracts.lua')
load('tests/s23_agency_contracts.lua')
load('tests/s23_venue_contracts.lua')
load('tests/s23_settlement_contracts.lua')
load('tests/s24_audit_contracts.lua')
load('tests/s24_analytics_contracts.lua')
load('tests/s24_diagnostics_contracts.lua')
load('tests/s25_dto_contracts.lua')
load('tests/s25_idempotency_contracts.lua')
load('tests/s25_events_contracts.lua')
load('tests/s25_repository_contracts.lua')
load('tests/s25_api_exports_contracts.lua')
load('tests/s26_recovery_contracts.lua')
load('tests/s27_security_contracts.lua')
load('tests/s28_network_policy_contracts.lua')
load('tests/s28_streaming_budget_contracts.lua')
load('tests/s28_scheduler_cache_contracts.lua')
load('tests/s28_load_matrix_contracts.lua')
load('tests/s29_framework_parity_contracts.lua')

local function check(value, message) assert(value, message) end

do
    local order = {}
    local stages = {}
    for _, name in ipairs(NightShift.Constants.STAGES) do
        stages[name] = function() order[#order + 1] = name; return { ok = true } end
    end
    local instance = NightShift.ServerBootstrap.new({ stages = stages })
    check(instance:boot(), 'ordered boot should succeed')
    check(table.concat(order, ',') == 'config,db,adapters,repositories,services,jobs', 'stage order mismatch')
    check(instance.readiness == 'READY', 'boot should be ready')
end

do
    local called = {}
    local stages = { config = function() return { ok = false, code = 'INVALID_CONFIG', message = 'invalid config' } end }
    for _, name in ipairs(NightShift.Constants.STAGES) do
        stages[name] = stages[name] or function() called[#called + 1] = name; return { ok = true } end
    end
    local instance = NightShift.ServerBootstrap.new({ stages = stages })
    local ok, err = instance:boot()
    check(not ok and instance.readiness == 'FAILED', 'invalid stage must fail')
    check(err.code == 'INVALID_CONFIG' and #called == 0, 'later stages must not run')
end

do
    local instance = NightShift.ServerBootstrap.new()
    local cleaned, survived = false, false
    instance:onCleanup(function() cleaned = true; error('expected cleanup failure') end)
    instance:onCleanup(function() survived = true end)
    instance:stop('gnsh-nightshift')
    instance:stop('gnsh-nightshift')
    check(cleaned and survived and instance.readiness == 'STOPPED', 'cleanup should be once and stop')
    check(instance.error and instance.error.code == 'CLEANUP_FAILED', 'cleanup failure should be structured')
end

do
    local ok, err = NightShift.Server.bootstrap({ config = false })
    check(not ok and NightShift.Server.readiness == 'FAILED', 'explicitly invalid config must prevent READY')
    check(err and err.code == 'INVALID_CONFIG', 'invalid config failure must remain structured')
end

do
    local instance = NightShift.ServerBootstrap.new({
        stages = { config = function() return { ok = false, success = true, code = 'CONTRADICTORY' } end }
    })
    local ok = instance:boot()
    check(not ok and instance.readiness == 'FAILED', 'contradictory stage result must fail closed')
end

do
    local handler
    AddEventHandler = function(_, callback) handler = callback end
    GetCurrentResourceName = function() return 'gnsh-nightshift' end
    local instance = NightShift.ServerBootstrap.new()
    local cleaned = false
    instance:onCleanup(function() cleaned = true end)
    handler('other-resource')
    check(instance.readiness == 'STARTING' and not cleaned, 'foreign stop must be ignored')
    handler('gnsh-nightshift')
    check(instance.readiness == 'STOPPED' and cleaned, 'own stop hook must clean up')
    AddEventHandler = nil
    GetCurrentResourceName = nil
end

check(NightShift.Client.readiness == 'READY', 'client lifecycle should initialize ready')
load('tests/rem_001_readiness_contracts.lua')
load('tests/rem_002_npc_contracts.lua')

local function validConfig(overrides)
    local value = NightShift.Validators.copy(NightShift.DefaultConfig)
    if overrides then for key, item in pairs(overrides) do value[key] = item end end
    return value
end

do
    local normalized, err = NightShift.Validators.validateConfig(validConfig({ provider = { mode = 'explicit', name = 'missing' } }))
    check(not normalized and err.code == 'UNKNOWN_PROVIDER' and err.field == 'provider.name', 'unknown provider must fail with field')
end
do
    local value = validConfig(); value.servicePackages[2] = NightShift.Validators.copy(value.servicePackages[1])
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'DUPLICATE_ID', 'duplicate service ID must fail')
end
do
    local value = validConfig(); value.servicePackages[1].price = 0
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_PRICE', 'invalid price must fail')
end
do
    local value = validConfig(); value.servicePackages[1].locationIds = { 'not-allowlisted' }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_LOCATION_REFERENCE', 'invalid location reference must fail')
end
do
    local value = validConfig(); value.features.physicalNpc = true
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(normalized and not err and normalized ~= value and normalized.features.physicalNpc, 'valid config should normalize a copy')
end
do
    local value = validConfig({ provider = { mode = 'auto' } })
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'auto detection must not silently fall back')
end
do
    local value = validConfig({ provider = { mode = 'auto' } })
    local normalized, err = NightShift.Validators.validateConfig(value, { resolveProvider = function() return false end })
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'malformed resolver result must be typed unavailable')
    normalized, err = NightShift.Validators.validateConfig(value, { resolveProvider = function() return { name = 'standalone', supported = true, available = true, capabilities = {} } end })
    check(not normalized and err.code == 'PROVIDER_UNAVAILABLE', 'empty capabilities must be unavailable')
end
do
    local value = validConfig(); value.servicePackages = { [2] = value.servicePackages[1] }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'sparse service arrays must fail')
    value = validConfig(); value.servicePackages[1].locationIds = { 'configured_default', 'configured_default' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_LOCATION_REFERENCE', 'duplicate location references must fail')
    value = validConfig(); value.servicePackages = { value.servicePackages[1], [3] = NightShift.Validators.copy(value.servicePackages[1]) }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'holes with trailing entries must fail')
    value = validConfig(); value.servicePackages[1].locationIds = false; value.servicePackages[1].locations = { 'configured_default' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'invalid primary location alias must not fall back')
end
do
    local value = validConfig(); value.features = false
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'malformed features must fail')
    value = validConfig(); value.locations[1].category = 'arbitrary'
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'invalid location category must fail')
end
do
    local value = validConfig(); value.demand = { window = math.huge }
    local normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'unsafe demand placeholder must fail')
    value = validConfig(); value.npcProfiles[1].description = 'graphic content'
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'free-form NPC profile content must fail')
    value = validConfig(); value.npcProfiles[1].traits = { model = 'graphic' }
    normalized, err = NightShift.Validators.validateConfig(value)
    check(not normalized and err.code == 'INVALID_CONFIG', 'nested NPC profile fields must fail')
end

do
    local ok = NightShift.Server.bootstrap()
    check(ok and NightShift.Server.readiness == NightShift.Enums.Readiness.DEGRADED,
        'default development config without runtime dependencies should boot degraded')
end

print('NS-010/NS-011 tests passed: lifecycle, config validation, normalization, and fail-closed provider selection')
