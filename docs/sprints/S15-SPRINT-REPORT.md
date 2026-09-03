# S15 Sprint Report — Client Mode MEET_THERE

- Sprint: S15
- Completed tasks: NS-150 dual-side travel coordination, NS-151 grace/no-show outcomes, and NS-152 unified appointment/session/settlement flow.
- Changed files: \`fxmanifest.lua\`, \`server/bootstrap.lua\`, \`server/api/nui_callbacks.lua\`, \`server/services/client_mode_service.lua\`, \`shared/errors.lua\`, and \`tests/run.lua\`.
- New files: \`server/services/dual_travel_service.lua\`, \`server/dev/s15_smoke.lua\`, and \`tests/s15_dual_travel_contracts.lua\`.
- Migrations: None. MEET_THERE reuses the unified booking, location, worker, travel, NPC generation, appointment, refund, and settlement contracts.
- Public API changes: Added server-owned MEET_THERE client/NPC arrival routes, dual-travel smoke commands, token-only completion routing, and a single client-mode coordinator that routes MEET_THERE bookings without changing COME_TO_ME or PICKUP behavior.
- State contract: A booking remains \`TRAVELLING\` until both the client and the NPC worker pass their server-side arrival barriers. Only then may the canonical booking transition to \`ARRIVED\` and start an appointment session.
- No-show policy: The grace timer records \`CLIENT_NO_SHOW\` or \`WORKER_NO_SHOW\`, cancels the booking, cancels active travel, releases location/worker resources, attempts the configured refund path, and emits reliability hooks. Failed cleanup/refund returns \`DUAL_TRAVEL_RECOVERY_REQUIRED\` for retry instead of claiming a clean outcome.
- Tests run: \`lua tests/run.lua\`; \`luac -p\` on all S15-changed Lua files; \`npm --prefix web run build\`; \`git diff --check\`.
- Test results: PASS. NS-150/NS-151/NS-152 contracts cover the two-party arrival barrier, early-session rejection, server-owned NPC spawn/arrival binding, grace expiry outcomes (including both late), fail-closed proximity verification, cleanup recovery, token-only completion, restart rehydration, exactly-once session completion, and settlement.
- Security checks: Arrival payloads are allowlisted; booking ownership, MEET_THERE mode, typed destination, worker identity, travel key, generation token, and NPC entity binding are revalidated server-side. Client proximity fails closed when no server verifier is configured. NUI output includes only bounded privacy-safe DTO fields.
- Recovery checks: Travel recovery remains explicit; spawn failure maps to worker no-show; client/worker disconnect or interruption releases reservations and cancels travel; reserved bookings rehydrate worker/location/travel context after restart; settled completion is replay-safe; repeated arrival/session calls are idempotent or return a typed conflict.
- Known issues: A live server proximity verifier and deployment-specific NPC spawn/arrival providers remain required for physical FXServer smoke verification. The default appointment verifier is used when available and otherwise fails closed. Active sessions whose one-time token was only held in memory require an explicit recovery path after restart.
- Deferred items: Client Mode relationship/reputation flows (S16+), live FXServer smoke verification, and production provider wiring.
- Exit Gate result: PASS for contracts and integration wiring; live FXServer smoke remains the deployment verification step.
