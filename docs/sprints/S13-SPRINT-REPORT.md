# S13 Sprint Report — Client Mode COME_TO_ME

- Sprint: S13
- Completed tasks: NS-130 atomic COME_TO_ME reservation, NS-131 logical travel/spawn/arrival orchestration, NS-132 unified appointment and settlement retry flow.
- Changed files: `server/bootstrap.lua`, `server/api/nui_callbacks.lua`, `server/dev/s13_smoke.lua`, `server/services/appointment_session_service.lua`, `server/services/npc_arrival_service.lua`, `server/services/npc_travel_service.lua`, `server/services/client_booking_command_service.lua`, `shared/errors.lua`, `tests/run.lua`, `web/src/lib/nui.ts`, `web/src/types/api.ts`, `fxmanifest.lua`.
- New files: `server/services/client_mode_service.lua`, `server/dev/s13_smoke.lua`, `tests/s13_client_mode_contracts.lua`.
- Migrations: None.
- Config changes: None. Existing server-safe location, spawn, and settlement adapters remain the source of truth.
- Public API changes: Added allowlisted `client-mode:*` NUI actions for confirmation, travel, spawn binding, arrival, session, progress, and recovery. Responses pass through a privacy-safe DTO projection and the web request/response map is typed. Added development smoke commands for the same sequence.
- Adapter changes: Development settlement now supplies a deterministic synthetic NPC payee; arrival can resolve the booking actor through the identity service.
- Tests run: `lua tests/run.lua`; `luac -p` on all changed Lua files; `npm --prefix web run build`; `git diff --check`.
- Test results: PASS. NS-130..NS-132 contract tests cover reservation races, rollback, travel/spawn/arrival, travel compensation, NUI DTO privacy, settlement outage retry, strict token retry, and double-completion protection.
- Security checks: Server rechecks ownership, COME_TO_ME mode, quote freshness, worker/location availability, generation-bound spawn context, and arrival context. Client payloads cannot provide model, destination coordinates, price, or settlement values; NUI responses expose only allowlisted identifiers, server-validated spawn model/candidate data, and state.
- Recovery checks: Worker/location/deposit rollback is attempted on every pre-booking failure; a failed booking travel transition cancels its newly-created travel plan; settlement remains retryable after an outage and rejects mismatched tokens; player disconnect interrupts active/travelling client bookings and releases transient resources.
- Networking notes: NPC spawn remains server-authorized and entity generation-bound; network ownership is not treated as business authority.
- Known issues: A live physical spawn still requires the configured server-safe model allowlist and spawn resolver already required by the S09 streaming contract.
- Deferred items: PICKUP (S14), MEET_THERE (S15), and Client Mode relationship/reputation (S16+).
- Exit Gate result: PASS (contract and integration wiring; live FXServer smoke remains the deployment verification step).
