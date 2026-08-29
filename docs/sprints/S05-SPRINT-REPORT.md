# S05 Sprint Report — Unified Booking Core

**Date:** 2026-08-29

**Status:** PASS (local contract gate); live resource reload pending

**Scope:** NS-050, NS-051, NS-052, NS-053, NS-054 only

## Completed tasks

- **NS-050 — Unified Booking Entity:** added a validated immutable booking aggregate for player/NPC client and worker combinations, participant references, service-package snapshots, meeting/location data, quote/agreed-price snapshots, lifecycle timestamps, versioning, idempotency, correlation, and external references.
- **NS-051 — Booking State Machine:** added allowlisted lifecycle transitions, terminal-state protection, immutable version increments, bounded transition metadata, and trusted guards.
- **NS-052 — Booking Timeline:** added append-only state-change events, idempotent event keys, parameterized event persistence, history reads, and state reconstruction.
- **NS-053 — BookingService:** added server-side draft, quote, offer, accept/decline, reservation, travel, trusted arrival/active/complete, settlement, cancellation, expiration, and interruption operations with ownership checks, expected-version concurrency, timeline recording, and fail-closed catalog/quote authority.
- **NS-054 — Coordinated Reservations:** added ordered NPC/worker → location/room/vehicle → deposit locks, TTL expiry, atomic rollback, provider compensation, retry idempotence, and booking-scoped release.
- **Schema/bootstrap integration:** registered migration `011_booking_core.sql`, extended booking/event repositories, and wired timeline, reservation, and booking services into the server bootstrap.
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
- `tests/s04_profiles_contracts.lua`
- `tests/migrations_contracts.lua`
- `tests/schema_contracts.lua`
- `tests/run.lua`
- `CHANGELOG.md`

## Tests and verification

- `C:\Users\Gnesh\AppData\Local\Programs\Lua\5.5.1\lua.exe tests/run.lua` passed NS-010/011, NS-020/023, NS-030..037, NS-040..043, and NS-050..054 contracts.
- Lua parse check passed for all 67 Lua files.
- FiveM manifest S05 load-order assertions passed.
- `git diff --check` passed.
- Contract coverage includes both player-worker/NPC-client and player-client/NPC-worker shapes, quote authority, state guards, stale versions, terminal/double completion, timeline idempotence, reservation conflict rollback, booking-scoped release, numeric IDs, provider retry behavior, and ownership denial.

## Live FiveM smoke

- FXServer is running locally on `0.0.0.0:30120`; txAdmin is running on `0.0.0.0:40120`.
- `info.json` lists `gnsh-nightshift`; the current FXServer log contains the resource environment/start lines and oxmysql’s MariaDB connection-success line.
- `players.json` is currently empty because the earlier connected client disconnected; endpoint reachability remains healthy.
- The process was not restarted during this phase. Therefore the live evidence confirms server/resource health, not S05 migration/application behavior. After the commit is pushed, type `restart gnsh-nightshift` in the already-open server console; the resulting `fxserver.log` lines and migration result are the runtime gate. No browser is required.

## Security / recovery / performance

- Client-facing booking creation cannot supply authoritative package or quote prices without a server resolver; resolver failures fail closed.
- Participant, state, resource, timestamp, currency, metadata, identifier, and pagination inputs are bounded/allowlisted; SQL values are parameterized and dynamic table names are validated.
- Expected-version updates prevent stale writes and double completion; reservation conflicts roll back newly acquired resources, and release is restricted to the owning booking.
- Timeline events are idempotent by booking/state-transition key and include correlation/actor metadata for replay and reconciliation.
- No polling loops or entity work were added; in-memory reservation scans are bounded by the active lock set and purge expired entries.

## Known issues and deferred work

- Migration `011_booking_core.sql` must be applied by the normal runner during the controlled live resource restart before production booking writes.
- The current service reports a typed failure if timeline persistence fails after the booking update (`statePersisted=true`); a DB transaction wrapper can make this cross-table transition atomic in a later persistence hardening task.
- Public network handlers, client UI, provider-specific reservation/location adapters, payments, settlement, and live player-flow tests remain deferred to the planned later sprints.

## Exit Gate

- [x] One unified booking entity and participant model.
- [x] Server-side booking state machine with guarded transitions.
- [x] Timeline history and reconstruction.
- [x] BookingService with ownership, authority, and optimistic concurrency.
- [x] Coordinated atomic reservations with rollback/idempotent release.
- [x] Local contract, parse, manifest, and diff verification.
- [ ] Controlled live restart and migration/runtime smoke.

**S05 local Exit Gate: PASS. Stop before S06 until the live restart gate is confirmed.**
- Implementation and review remain root-owned per the user's explicit no-subagent override; no child task was dispatched.
- `dev` is the active development branch; `main` remains the release branch and is not modified.
