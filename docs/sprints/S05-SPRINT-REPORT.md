# S05 Sprint Report — Unified Booking Core

**Date:** 2026-08-29

**Status:** PASS (local contract gate, live resource reload, and runtime persistence wiring); DB-backed runtime gate pending controlled convar restart

**Scope:** NS-050, NS-051, NS-052, NS-053, NS-054 only

## Completed tasks

- **NS-050 — Unified Booking Entity:** added a validated immutable booking aggregate for player/NPC client and worker combinations, participant references, service-package snapshots, meeting/location data, quote/agreed-price snapshots, lifecycle timestamps, versioning, idempotency, correlation, and external references.
- **NS-051 — Booking State Machine:** added allowlisted lifecycle transitions, terminal-state protection, immutable version increments, bounded transition metadata, and trusted guards.
- **NS-052 — Booking Timeline:** added append-only state-change events, idempotent event keys, parameterized event persistence, history reads, and state reconstruction.
- **NS-053 — BookingService:** added server-side draft, quote, offer, accept/decline, reservation, travel, trusted arrival/active/complete, settlement, cancellation, expiration, and interruption operations with ownership checks, expected-version concurrency, timeline recording, and fail-closed catalog/quote authority.
- **NS-054 — Coordinated Reservations:** added ordered NPC/worker → location/room/vehicle → deposit locks, TTL expiry, atomic rollback, provider compensation, retry idempotence, and booking-scoped release.
- **Schema/bootstrap integration:** registered migration `011_booking_core.sql`, extended booking/event repositories, and wired timeline, reservation, and booking services into the server bootstrap.
- **Runtime persistence gate:** added the `nightshift_persistence` FiveM convar opt-in. When enabled, bootstrap clones the config immutably and wraps oxmysql only when the FiveM runtime exposes a usable driver; development defaults remain deferred and missing wiring fails closed.
- **Runtime observability:** added secret-free `ready`/typed-failure bootstrap log entries with persistence, database, and migration-version context so a console restart is an auditable gate.
- **Runtime lookup fix:** direct FiveM native/global resolution is used for `GetConvar`, `MySQL`, and `exports`; replicated convars are no longer hidden by `_G` raw-table lookup behavior.
- **Direct review hardening:** fixed numeric booking-ID release normalization, prevented one booking from scanning/releasing another booking’s locks, preserved all resources across incremental reservation calls, persisted quote/agreed timestamps, required a server catalog resolver, closed stale quote/accept races with expected versions, and rejected explicit trusted-verifier denials.

## Changed files

- `server/domain/booking.lua`
- `server/repositories/booking_repository.lua`
- `server/state/booking_state_machine.lua`
- `server/repositories/booking_event_repository.lua`
- `server/core/reservations.lua`
- `server/services/booking_timeline_service.lua`
- `server/services/booking_reservation_service.lua`
- `server/services/booking_service.lua`
- `sql/011_booking_core.sql`
- `server/core/migrations.lua`
- `server/bootstrap.lua`
- `shared/errors.lua`
- `fxmanifest.lua`
- `tests/s05_booking_contracts.lua`
- `tests/migrations_contracts.lua`
- `tests/s04_profiles_contracts.lua`
- `tests/migrations_contracts.lua`
- `tests/schema_contracts.lua`
- `tests/run.lua`
- `CHANGELOG.md`

## Tests and verification

- `C:\Users\Gnesh\AppData\Local\Programs\Lua\5.5.1\lua.exe tests/run.lua` passed NS-010/011, NS-020/023, NS-030..037, NS-040..043, and NS-050..054 contracts.
- Runtime convar, oxmysql adapter normalization, and default bootstrap-to-migration wiring contracts pass with isolated FiveM/oxmysql doubles.
- Runtime bootstrap diagnostics remain gated to FiveM (`GetCurrentResourceName`) and do not print credentials or raw provider payloads.
- Lua parse check passed for all 67 Lua files.
- FiveM manifest S05 load-order assertions passed.
- `git diff --check` passed.
- Contract coverage includes both player-worker/NPC-client and player-client/NPC-worker shapes, quote authority, state guards, stale versions, terminal/double completion, timeline idempotence, reservation conflict rollback, booking-scoped release, numeric IDs, provider retry behavior, and ownership denial.

## Live FiveM smoke

- FXServer is running locally on `0.0.0.0:30120`; txAdmin is running on `0.0.0.0:40120`.
- `info.json` lists `gnsh-nightshift`; the current FXServer log contains the resource environment/start lines and oxmysql’s MariaDB connection-success line.
- `players.json` reports the connected local player `Gnesh`; endpoint reachability remains healthy.
- The controlled console command `restart gnsh-nightshift` completed successfully (`Stopping resource` → `Creating script environments` → `Started resource`). The connected FiveM client log records the same reload and currently reports no gnsh-nightshift-specific script errors; `players.json` reports the connected local player.
- The default development configuration has `features.persistence=false`, and bootstrap therefore defers the database/repository/service stages without an injected adapter. The restart proves resource reload health, but it intentionally does not apply migration 011 or exercise DB-backed booking operations. Enable persistence and wire the oxmysql adapter in a later runtime/config step before that gate.
- The next controlled runtime gate is run from the open FXServer console with `setr nightshift_persistence true` followed by `restart gnsh-nightshift`; this is intentionally not marked complete until the server log confirms migration/DB bootstrap and the live client remains clean.

## Security / recovery / performance

- Client-facing booking creation cannot supply authoritative package or quote prices without a server resolver; resolver failures fail closed.
- Participant, state, resource, timestamp, currency, metadata, identifier, and pagination inputs are bounded/allowlisted; SQL values are parameterized and dynamic table names are validated.
- Expected-version updates prevent stale writes and double completion; reservation conflicts roll back newly acquired resources, and release is restricted to the owning booking.
- Timeline events are idempotent by booking/state-transition key and include correlation/actor metadata for replay and reconciliation.
- No polling loops or entity work were added; in-memory reservation scans are bounded by the active lock set and purge expired entries.

## Known issues and deferred work

- Migration `011_booking_core.sql` is applied by the normal runner after the `nightshift_persistence` opt-in; the current development-safe `persistence=false` setting defers it.
- The current service reports a typed failure if timeline persistence fails after the booking update (`statePersisted=true`); a DB transaction wrapper can make this cross-table transition atomic in a later persistence hardening task.
- Public network handlers, client UI, provider-specific reservation/location adapters, payments, settlement, and live player-flow tests remain deferred to the planned later sprints.

## Exit Gate

- [x] One unified booking entity and participant model.
- [x] Server-side booking state machine with guarded transitions.
- [x] Timeline history and reconstruction.
- [x] BookingService with ownership, authority, and optimistic concurrency.
- [x] Coordinated atomic reservations with rollback/idempotent release.
- [x] Local contract, parse, manifest, and diff verification.
- [x] Controlled live resource restart and client reload smoke.
- [x] Runtime persistence opt-in and oxmysql bootstrap wiring contracts.
- [ ] Persistence-enabled migration and DB-backed booking runtime smoke.

**S05 Exit Gate: PASS for local contracts, resource reload, and runtime wiring. Stop before S06 until persistence-enabled migration/runtime smoke is confirmed.**
- Implementation and review remain root-owned per the user's explicit no-subagent override; no child task was dispatched.
- `dev` is the active development branch; `main` remains the release branch and is not modified.
