# S14 Sprint Report — Client Mode PICKUP

- Sprint: S14
- Completed tasks: NS-140 server-owned pickup location resolution, NS-141 NPC waiting/no-show controller, NS-142 owner-only vehicle binding/entry, and NS-143 two-leg pickup progression through destination/session/settlement.
- Changed files: `config/config.lua`, `config/locations.lua`, `fxmanifest.lua`, `server/bootstrap.lua`, `server/api/nui_callbacks.lua`, `server/services/client_mode_service.lua`, `server/services/npc_arrival_service.lua`, `server/services/npc_entity_registry.lua`, `server/state/booking_state_machine.lua`, `shared/errors.lua`, `tests/run.lua`.
- New files: `server/services/pickup_location_service.lua`, `server/services/pickup_vehicle_service.lua`, `server/services/pickup_mode_service.lua`, `client/client_mode/pickup.lua`, `server/dev/s14_smoke.lua`, `tests/s14_pickup_contracts.lua`.
- Migrations: None. PICKUP reuses the unified booking, travel, NPC entity, appointment, and settlement contracts.
- Config changes: Added server-owned SAFE_ROADSIDE pickup candidates for Vinewood and Los Santos plus district/priority/suitability metadata. Client coordinates are never accepted as a selector.
- Public API changes: Added typed server routes for pickup arrival, vehicle binding/entry, destination travel/arrival, and development smoke commands. Existing `client-mode:*` calls route PICKUP bookings to the dedicated coordinator while COME_TO_ME remains unchanged.
- Tests run: `lua tests/run.lua`; `luac -p` on all changed Lua files; `npm --prefix web run build`.
- Test results: PASS. NS-140..NS-143 tests cover server-generated safe points, blocked/suitable candidate selection, reservation idempotence/conflict, wrong-owner claims, waiting timeout/no-show, vehicle access/seat/destroyed checks, first and second travel legs, and unified session settlement.
- Security checks: Pickup requests reject arbitrary coordinates; location/vehicle identity, booking owner, worker mode, seat, proximity, entity generation, travel context, and destination are revalidated server-side. NUI output is projected through the existing privacy-safe DTO layer.
- Recovery checks: Waiting controller reports entity deletion and no-show; destroyed vehicles require recovery; interrupted pickup releases vehicle/location/destination/worker resources and cancels active travel plans; second-leg entity rebinding is generation- and booking-bound.
- Known issues: A live physical vehicle resolver and server NPC proximity/seat callbacks remain deployment-provided integrations, just like the existing S07 vehicle contract. Without those providers, the service fails closed with an explicit `PICKUP_*` error.
- Deferred items: MEET_THERE (S15), Client Mode vertical slice/relationship flows (S16+), and live FXServer smoke verification.
- Exit Gate result: PASS (contract and integration wiring; live FXServer smoke remains the deployment verification step).
