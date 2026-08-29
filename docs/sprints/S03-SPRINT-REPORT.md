# S03 Sprint Report — Provider / Adapter Layer

**Date:** 2026-08-29

**Status:** PASS

**Scope:** NS-030, NS-031, NS-032, NS-033, NS-034, NS-035, NS-036, NS-037 only

## Completed tasks

- **NS-030 — Framework Interface:** added normalized identity/job DTOs, immutable capability snapshots, loaded/unloaded/job/duty callback contracts, health checks, and provider-neutral Result errors.
- **NS-031 — QBCore Adapter:** added PlayerData identity, character, job/grade/duty normalization, configurable lifecycle event registration, and no raw QBCore object leakage.
- **NS-032 — Qbox Adapter:** added an independent qbx_core lookup/lifecycle implementation with explicit Qbox capability reporting; it is not a QBCore alias.
- **NS-033 — ESX Legacy Adapter:** added xPlayer normalization and configurable lifecycle events with an internal availability/duty fallback when ESX has no native duty field.
- **NS-034 — Standalone Adapter:** added license/server-identifier fallback, no-job identity, lifecycle hooks, and reduced capability reporting.
- **NS-035 — Money Adapter Set:** added validated account/amount/source contracts, typed insufficient/unsupported/unavailable failures, QBCore/Qbox/ESX/Standalone implementations, reason propagation, and non-atomic transfer compensation reporting.
- **NS-036 — Optional Provider Interfaces:** added server phone/housing/motel/dispatch/appearance/evidence contracts plus client target/notify contracts. Missing optional resources do not block startup and expose explicit fallback/capability state.
- **NS-037 — Provider Resolver:** added explicit provider precedence, auto-detection, ambiguous framework rejection, dependency/resource-state validation, capability diagnostics, and bootstrap `adapters` stage integration.
- **Direct review hardening:** preserved dynamic availability callbacks, rejected false money mutations, normalized nested job grades, guarded event source extraction, and kept provider-specific calls inside adapter files.

## Changed files

- `shared/types/framework.lua`
- `docs/spec/PROVIDER_ADAPTERS.md`
- `shared/errors.lua`
- `config/providers.lua`
- `server/bootstrap.lua`
- `server/core/result.lua`
- `server/adapters/framework/interface.lua`
- `server/adapters/framework/qbcore.lua`
- `server/adapters/framework/qbox.lua`
- `server/adapters/framework/esx.lua`
- `server/adapters/framework/standalone.lua`
- `server/adapters/money/interface.lua`
- `server/adapters/money/qbcore.lua`
- `server/adapters/money/qbox.lua`
- `server/adapters/money/esx.lua`
- `server/adapters/money/standalone.lua`
- `server/adapters/optional_base.lua`
- `server/adapters/phone/interface.lua`
- `server/adapters/housing/interface.lua`
- `server/adapters/motel/interface.lua`
- `server/adapters/dispatch/interface.lua`
- `server/adapters/appearance/interface.lua`
- `server/adapters/evidence/interface.lua`
- `server/adapters/provider_resolver.lua`
- `client/adapters/target/interface.lua`
- `client/adapters/notify/interface.lua`
- `fxmanifest.lua`
- `tests/provider_contracts.lua`
- `tests/run.lua`
- `CHANGELOG.md`

## Tests and verification

- `lua tests/run.lua` passed all existing S00–S02 contracts and NS-030..NS-037 provider contracts.
- Lua parse check passed for all 48 Lua files.
- FiveM manifest stub passed metadata and server/client load-order assertions.
- `git diff --check` passed for the tracked S03 changes before commit.
- No local FiveM server, framework runtime, or live oxmysql/database is available; runtime smoke is deferred to the final server/player validation gate.

## Security / recovery / performance

- Framework/provider objects are normalized before reaching core consumers; raw QBCore/Qbox/ESX objects are not returned from the public identity contract.
- Money sources, account names, positive integer amounts, and operation results are validated; false mutation results fail closed. Non-atomic transfers attempt compensation and report the outcome.
- Auto provider detection rejects ambiguity; explicit selection never silently falls back. Missing optional integrations remain visible through capability/health diagnostics.
- Lifecycle hooks support reconnect/load/unload paths; provider event payloads are copied/normalized and malformed sources are ignored.
- S03 adds no per-player loops, entity scans, or database queries; adapter calls are on-demand and capability snapshots are copied.

## Framework / provider notes

- QBCore, Qbox, ESX, and Standalone constructors accept injected runtime seams for deterministic tests and use resource exports/events only inside adapter modules.
- ESX and Standalone availability/duty differences are represented as capabilities; core code must consume capabilities rather than provider names.
- Phone, housing, motel, dispatch, appearance, evidence, target, and notify are optional. Their absence is not a startup blocker; feature services decide whether to hide or degrade a flow.

## Known issues and deferred work

- Actual QBCore/Qbox/ESX lifecycle and money calls still require a live FiveM runtime for smoke verification.
- Transfer atomicity depends on the selected framework capability; compensating fallback is explicit but cannot provide database-level atomicity.
- Provider-specific event names can differ by deployment and are configurable through adapter options; the default names require validation against the target server build.
- Aggregate repositories, identity/profile services, domain services, jobs, and real player scenarios remain deferred to S04+.

## Exit Gate

- [x] QBCore adapter.
- [x] Qbox adapter.
- [x] ESX adapter.
- [x] Standalone fallback.
- [x] Money adapter.
- [x] Optional provider contracts.
- [x] Fail-fast provider resolver.

**S03 Exit Gate: PASS. Stop before S04.**
