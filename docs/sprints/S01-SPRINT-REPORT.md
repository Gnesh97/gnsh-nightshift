# S01 Sprint Report — Resource Foundation

**Date:** 2026-08-28
**Status:** PASS
**Scope:** NS-010, NS-011, NS-012, NS-013 only

## Completed tasks

- **NS-010 — Resource Skeleton:** added the Lua 5.4/GTA V manifest, ordered `config -> db -> adapters -> repositories -> services -> jobs -> READY` bootstrap seam, server/client readiness states, fatal stage handling, and guarded resource-stop cleanup.
- **NS-011 — Config Model & Validation:** added provider mode/registry, feature defaults, abstract service-package/location/NPC schemas, demand/heat placeholders, normalized copies, cross-reference checks, and fail-closed actionable errors.
- **NS-012 — Core Result / Logger / Clock:** added structured Result values, stable provider-neutral error codes, injectable UTC clock, correlation IDs, debug category filtering, sink isolation, recursive redaction, and caller-context copying.
- **NS-013 — Internal Event Bus:** added deterministic subscribe/unsubscribe, post-commit event envelopes, listener snapshotting, correlation propagation, isolated handler failures, aggregate delivery results, and no network-event surface.
- **Direct review hardening:** made resource load auto-start the server bootstrap, rejected explicitly invalid stage/config outcomes, copied successful Result values, handled non-finite clock input safely, and expanded sensitive-key redaction aliases.

## Changed files

- `fxmanifest.lua`
- `server/bootstrap.lua`
- `client/bootstrap.lua`
- `shared/enums.lua`
- `shared/errors.lua`
- `shared/constants.lua`
- `shared/schemas.lua`
- `shared/validators.lua`
- `config/config.lua`
- `config/features.lua`
- `config/providers.lua`
- `server/core/result.lua`
- `server/core/clock.lua`
- `server/core/logger.lua`
- `server/core/event_bus.lua`
- `tests/run.lua`
- `tests/core_contracts.lua`
- `tests/event_bus_contracts.lua`
- `CHANGELOG.md`
- `docs/sprints/S01-SPRINT-REPORT.md`

## Migrations / config / public API / adapters

- Migrations: none; database persistence is deferred to S02.
- Config: development defaults use an explicitly allowlisted standalone provider with no external effects; invalid production config fails closed.
- Public API: `NightShift.Server.bootstrap`, `NightShift.ServerBootstrap`, `NightShift.Result`, `NightShift.Clock`, `NightShift.Logger`, and `NightShift.EventBus` foundation seams are available for later services.
- Adapters: none implemented; stage initializers remain injectable for provider/repository work.

## Tests and verification

- TDD RED/GREEN completed for NS-013 event-bus behavior.
- `lua tests/run.lua` passed lifecycle auto-start/invalid-config checks, config validation, Result/Logger/Clock contracts, event-bus isolation, correlation, and no-network-surface checks.
- `git diff --check a668ec5..HEAD` passed with no whitespace errors.
- No FiveM server/test runner is available locally; `ensure nightshift` smoke execution remains a runtime-environment check.

## Security / recovery / networking / performance

- Security: config validation is fail-closed; provider names do not drive core decisions; no client-triggered internal events or credentials were added; logger redacts sensitive fields recursively without mutating input context.
- Recovery: bootstrap stops after the first failed required stage; cleanup callbacks are isolated and idempotent; event handler failure cannot roll back or abort later handlers.
- Networking: no `RegisterNetEvent`, `TriggerClientEvent`, or state-bag authority was introduced.
- Performance: foundation adds no product loops, entity spawning, database calls, or external I/O.

## Framework notes

QBCore, Qbox, ESX Legacy, and standalone remain capability/provider concerns. S01 contains no framework-specific API calls; provider capability implementations are deferred.

## Known issues

- FiveM runtime smoke validation, database persistence, provider adapters, repositories, services, jobs, and all product workflows remain deferred to S02+.
- The generated `.codebase-memory` artifact is maintained separately from task-owned runtime commits and is not staged by S01 bookkeeping.

## Deferred items

- S02 Database & Persistence and all later sprints.
- Framework/phone/money/location provider implementations.
- Runtime integration tests that require a FiveM server.

## Exit Gate

- [x] Bootstrap.
- [x] Config validation.
- [x] Result/logger/clock.
- [x] Internal event bus.

**S01 Exit Gate: PASS. Stop before S02.**
