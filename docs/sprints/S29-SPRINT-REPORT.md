# S29 Sprint Report — Framework Parity

- Sprint: S29 — QBCore / Qbox / ESX Legacy full parity
- Completed tasks: NS-290 QBCore matrix; NS-291 independent Qbox lifecycle/money contract; NS-292 ESX Legacy lifecycle/duty fallback contract; NS-293 provider-minimal matrix.
- Changed files: framework adapter interface, QBCore adapter, Qbox adapter, ESX adapter, test runner, and S29 parity contracts.
- New files: tests/s29_framework_parity_contracts.lua, four files under tests/framework/, and this report.
- Migrations: none. Framework parity uses existing normalized identity, booking, and provider contracts.
- Public API changes: lifecycle callbacks now accept FiveM's implicit server source where applicable; Qbox defaults to QBCore:Server:PlayerLoaded, QBCore:Server:OnPlayerUnload, qbx_core:server:playerLoggedOut, and playerDropped, with QBCore:Server:SetDuty for duty changes; logout callbacks receive a safe normalized loaded=false snapshot and release it after all registered subscribers finish. Multi-event registration rolls back earlier tokens when a later registration fails, false/nil registration results remain failures, and duplicate Qbox logout paths are delivered once per subscriber.
- Security checks: raw framework player objects remain outside DTOs; source IDs are validated; identity snapshots contain only normalized fields and are bounded to currently active lifecycle callbacks; provider absence remains typed or fallback-only.
- Framework checks: QBCore, Qbox, and ESX fixtures cover load, job, duty, unload-after-player-removal, and normalized capability behavior. Qbox is independently registered and does not use a QBCore adapter alias.
- Provider-minimal checks: missing target/notify/dispatch/appearance/phone providers degrade through typed fallback or unavailable results without blocking the core.
- Tests run: lua tests/run.lua; S29-changed Lua syntax sweep; npm run build from web; git diff --check.
- Test results: PASS — all existing contracts plus NS-290..NS-293 framework parity contracts passed.
- Live verification: the four matrix files document the FXServer evidence steps. The target server still needs one operator run for each QBCore, Qbox, ESX, and provider-minimal matrix; no server.cfg edit or resource restart was performed by this turn.
- Exit gate result: CODE CONTRACT PASS; LIVE FRAMEWORK GATE OPEN. S30 release packaging/CI was not started.
