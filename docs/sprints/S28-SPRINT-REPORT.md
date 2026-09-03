# S28 Sprint Report

- Sprint: S28 — OneSync / Performance
- Completed tasks: NS-280 entity ownership policy; NS-281 granular state bags; NS-282 bounded NPC streaming leases; NS-283 bounded analytics cache and scheduler integration; NS-284 load/profiler matrix.
- Changed files: network policy services, NPC entity/spawn services, streaming budget service, bootstrap wiring, analytics repository/cache, shared error/config/manifest, and S28 contract tests.
- New files: `server/services/entity_ownership_policy.lua`, `server/services/state_bag_policy.lua`, `server/services/npc_streaming_budget_service.lua`, `server/core/summary_cache.lua`, `config/analytics.lua`, S28 tests, performance/network docs.
- Migrations: none; S28 adds no persistent schema.
- Config changes: bounded NPC budget defaults (64 global, 8 per source, 32 per district, 512 tracked, 120-second lease) and analytics cache bounds (64 entries, 30-second TTL).
- Public API changes: spawn responses expose bounded `streamingLease`/granular `stateBag` metadata; server-owned confirmations are observational and cannot rebind physical handles.
- Tests run: `lua tests/run.lua`; changed-file Lua syntax sweep; `npm run build`; `git diff --check`.
- Test results: PASS — all existing contracts plus NS-280..NS-284.
- Security checks: logical/server authority remains canonical; OneSync owner migration is tolerated without granting business authority; forged entity/network IDs are rejected; state-bag keys and sizes are allowlisted/bounded; analytics table names are validated.
- Recovery checks: lease expiry and explicit release reclaim capacity; registry deletion/unregister releases through the bounded lifecycle; cache subscriptions roll back on partial failure and close cleanly.
- Networking notes: state bags are replicated hints only; registry generation/context and server bindings remain the source of truth.
- Performance notes: physical NPC admission is bounded and renewed by a single runtime loop; analytics summaries use bounded TTL cache; scheduled work remains one bounded due batch.
- Framework notes: core changes are framework-blind; no QBCore/Qbox/ESX-specific code added.
- Known issues: the FXServer `resmon`/profiler pass in `tests/scenarios/LOAD_MATRIX.md` remains an operator-side runtime measurement.
- Deferred items: S29 framework parity matrices and S30 release packaging are not started.
- Exit Gate result: PASS
