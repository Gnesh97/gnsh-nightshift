# Changelog

All notable changes to NightShift are documented here.

## [Unreleased]

### S11 — Worker Mode Negotiation & Vertical Slice

- **NS-110:** Added immutable, server-authoritative NPC offer/counter negotiation
  with deterministic budget/demand pricing, bounded floors/ceilings, patience
  and round limits, ownership/idempotency checks, expiry, walk-away, and frozen
  accepted-price snapshots.
- **NS-111:** Added the Worker Mode bridge from a claimed S10 customer opportunity
  into the canonical BookingService, including registered package/location
  selection, authoritative negotiated quote application, location reservation,
  and worker `BUSY` locking.
- **NS-112:** Added actor/booking/location-bound appointment session tokens,
  server proximity hooks, minimum duration enforcement, one active session per
  actor, one-time completion, and a thin client transport with no settlement
  authority.
- **NS-113:** Added the end-to-end worker vertical-slice scenario and development
  smoke commands (`/nightshift_s11_begin`, `/nightshift_s11_counter`,
  `/nightshift_s11_accept`, `/nightshift_s11_travel`, `/nightshift_s11_arrive`,
  `/nightshift_s11_session_start`, `/nightshift_s11_session_complete`).
- Added S11 shared enums/error codes, config, bootstrap/manifest wiring, and
  contract coverage for negotiation, booking bridge, travel/session completion,
  one-time settlement, profile counters, BUSY release, token replay, and
  idempotent settlement behavior. No database migration is required.
- Smoke registration now reuses the existing S10 development opt-in for S11,
  including hosts that report an unset S11 convar as `false`, so moving between
  sprint smoke suites does not require another `server.cfg` setting.
- Fixed negotiation worker-reference validation for the canonical QBCore/FiveM
  identity key format (`length:identifier|length:character`).
- Fixed the BookingService permission-service field/method name collision that
  caused S11 acceptance to throw while creating the negotiated booking; added
  a regression contract for injected permission authorization.
- Fixed MariaDB DATETIME boundary handling for negotiated booking snapshots:
  numeric epoch expiries are serialized as UTC DATETIME values, SQL timestamps
  are normalized back to the domain UTC shape, and zero-date oxmysql values no
  longer break booking row mapping. Partial QUOTED/OFFERED/ACCEPTED bookings
  now resume idempotently after a failed acceptance attempt.
- Local full Lua contracts, parser checks, and `git diff --check` pass. Live
  FiveM player/session/proximity/settlement smoke remains the operator runtime
  gate; restart commands are intentionally left to the server operator.

### S10 — Worker Mode Demand & Customer Generation

- **NS-100:** Added configuration-driven district profiles with time/day demand curves, price and risk/heat placeholders, allowlisted discovery-zone labels, availability, and bounded logical-customer capacity; no map coordinates are embedded in district behavior.
- **NS-101:** Added a server-authoritative, explainable demand engine using district baselines, time/day curves, active-worker supply, recent-activity/police/heat hooks, optional event/weather modifiers, oversupply adjustment, and safe score clamping.
- **NS-102:** Added bounded NPC customer opportunity generation for explicitly AVAILABLE workers, district/zone eligibility, generation cooldowns, logical CUSTOMER profiles, claim/dismiss/expiry lifecycle, and per-worker/global capacity limits. Client candidates remain minimal logical DTOs; physical mapping is opt-in and on demand.
- **NS-103:** Added server-owned AVAILABLE/BUSY/OFFLINE worker availability with optional framework duty checks, booking locks, idempotent transitions, profile persistence hook, and logout reset handling.
- Added S10 shared enums/error/schema validation, bootstrap/manifest wiring, client candidate sanitization, and regression coverage for no-worker, oversupply, Friday high-demand, duty, cooldown, capacity, claim, and privacy boundaries. No database migration is required.
- Local S10/full Lua contracts, parser checks, and `git diff --check` pass. The development config now enables demand for the controlled FiveM worker opt-in/customer candidate smoke; S11 negotiation is intentionally not started.
- Added development-only FiveM smoke commands: `/nightshift_s10_available`, `/nightshift_s10_customer`, and `/nightshift_s10_offline`. They enable automatically for the development environment; non-development environments require `nightshift_s10_smoke_commands=true`. Commands require an in-game player source and print only bounded result fields to the server log.

- Added bootstrap filesystem fallback and duplicate-load guard so a resource restart picks up the smoke module even when FXServer cached the manifest before the module was created.
- Fixed smoke command registration to resolve FiveM natives through direct global lookup (with an embedded-host fallback); the previous raw `_G` lookup could silently skip every command in a live FXServer.
- Completed the live S10 FiveM smoke gate: availability, customer generation, cooldown rejection, offline transition, and offline customer denial all matched the expected server-authoritative results.

### S09 — NPC Travel, Streaming & Entity Control

- **NS-090:** Added immutable, server-owned logical travel plans with typed endpoints, deterministic ETA, monotonic progress, spawn thresholds, explicit recovery states, arrival, and return transitions; travel does not require a physical ped.
- **NS-091:** Added server/client entity registries with generation-bound profile mappings, network/entity handles, ownership migration tolerance, deleted-ped detection, and replacement generations; client mappings contain no booking business state.
- **NS-092:** Added controlled NPC spawn authorization with server-resolved safe candidates, model allowlists, minimal replicated metadata, generation tokens, and optional server-created entities; client model/coordinate injection is rejected.
- **NS-093:** Added near-player navigation stuck/player-away/timeout/deletion recovery and radius-gated arrival callbacks, plus server-side travel/entity/owner/plausibility validation before the canonical booking arrival transition.
- **NS-094:** Added safe fade/delete despawn cleanup and an optional generation-bound worker return hook so physical entities cannot leak while logical state remains authoritative.
- Added streaming policy configuration, shared S09 enums/error codes/schemas, manifest/bootstrap wiring, replacement and spoof regression coverage, and \`docs/sprints/S09-SPRINT-REPORT.md\`.
- Local full Lua contracts, parser checks, and \`git diff --check\` pass. Live model/candidate integration and player navigation/entity smoke remain the next FiveM runtime gate.

### S08 — NPC Profile & Marketplace Core

- **NS-080:** Added logical CUSTOMER/WORKER NPC profiles with persistent/semi-persistent lifetimes, sanitized aliases, appearance references, budget/price classes, bounded traits, district/travel availability, immutable copies, and versioned repository persistence.
- **NS-081:** Added config-driven deterministic NPC profile generation with weighted archetypes, bounded trait ranges, seed reproducibility, appearance references, duplicate-alias suffixing, and completed-booking promotion to persistent profiles.
- **NS-082:** Added logical worker pool availability with AVAILABLE/RESERVED/OCCUPIED/EXPIRED states, district/price/rating/travel filters, lock-then-database atomic reservation, booking ownership checks, release, and semi-persistent expiry.
- **NS-083:** Added a privacy-safe, bounded marketplace read model with stable worker public IDs, pagination, filter validation, price-class/ETA preview fields, and no internal trait, appearance, or generation-seed leakage.
- Added \`sql/014_npc_marketplace.sql\`, migration 014 registration, bootstrap/manifest wiring, and S08 contract coverage. Existing S07 migration history remains unchanged.
- Local S08/full Lua contract suite, parser checks, and \`git diff --check\` pass. After push, restart \`gnsh-nightshift\` on the FiveM server and verify \`NightShift server ready (persistence=true database=true migration=14)\`; player marketplace UI/entity smoke remains the next runtime gate.

### S07 — Typed Locations, Atomic Location Holds & Vehicle Resolution

- **NS-070:** Added server-owned typed location descriptors for motel/hotel rooms, properties, venue rooms, vehicles, configured locations, safe roadside points, and custom providers. Definitions normalize immutable world targets, access requirements, meeting modes, travel limits, blocked tags, availability, and reservability.
- **NS-071:** Added a capability-aware location resolver that accepts only registered typed references, validates provider registration/access/blocked zones/safe targets/route feasibility, and ignores arbitrary client coordinates.
- **NS-072:** Added location-scoped atomic reservation holds with deterministic booking idempotency keys, TTL expiry, occupy/release owner checks, provider mirror compensation, and a database unique active key for cross-process races.
- **NS-073:** Added server-bound vehicle location resolution with visibility, access, stationary/private vehicle, allowed-zone, safe-position, and optional booking-binding checks; client vehicle coordinates are ignored.
- Added migration sql/013_location_resolver.sql, location/reservation repositories, bootstrap wiring, BookingService location binding, and S07 contract coverage.
- Local full contract suite, Lua parser, and diff checks pass. Live location/provider/vehicle player smoke remains the next FiveM gate after the resource restart.

### S06 — Pricing, Settlement, Deposit & Refund

- **NS-060:** Added a configurable server-owned service catalog for SHORT/STANDARD/PREMIUM/PRIVATE/VIP packages, base price/duration/reputation requirements, meeting/location compatibility, feature gating, and fail-closed BookingService package resolution.
- **NS-061:** Added a deterministic server-authoritative pricing engine with package/NPC/district/time/demand/reputation modifiers, travel/location fees, safe min/max clamping, explainable line items, and expiring quote IDs; client-supplied totals are ignored.
- **NS-062:** Added immutable price-quote binding/acceptance snapshots and BookingService integration; quote IDs, expiry, and agreed quote IDs persist through `sql/012_pricing_snapshots.sql`, so settlement uses the accepted price even when later demand inputs change.
- **NS-063:** Added HELD deposit domain/repository/service lifecycle with server-derived amounts, stable idempotency keys, capability-gated money effects, release/refund/retain transitions, and compensation on persistence/race failures.
- **NS-064:** Added payment intent repository and settlement service with durable `settlement:{booking_id}` keys, frozen-price fingerprint checks, capability-gated atomic transfer, optional commission hook, deposit finalization, and canonical COMPLETED → SETTLED transition only after a committed financial result.
- Settlement retries now resume committed payment intents through deposit/commission finalization before the canonical booking transition, without issuing a second transfer.
- **NS-065:** Added state-aware cancellation/refund policy (including scheduled/assigned/en-route aliases), server-clock calculation, deposit retention/refund integration, and idempotent server-computed refunds.
- Extended the normalized money adapter boundary to forward stable operation keys to provider callbacks (including compensatable split-leg suffixes), while existing providers remain fail-closed until they advertise durable idempotency.
- Added S06 contract coverage for catalog compatibility, deterministic/clamped quotes, quote immutability, persisted snapshots, deposit replay/compensation, settlement replay/failure markers, canonical transition requirements, commission hooks, and refund idempotency.
- Bootstrap startup failures now log bounded message/path/cause context, making `INVALID_CONFIG` diagnosis actionable without dumping the full error payload.
- Local S06 exit-gate contracts, migration/schema contracts, full Lua parsing, and `git diff --check` pass. The live persistence gate also passed after a controlled restart (`persistence=true database=true migration=12`); live provider money tests remain intentionally deferred until adapters expose durable idempotency and atomic-transfer capabilities.

### S05 — Unified Booking Core

- **NS-050:** Added one validated booking aggregate for player/NPC client and worker combinations, immutable service-package and quote/agreed-price snapshots, participant references, meeting/location data, lifecycle timestamps, idempotency, correlation, and external references.
- **NS-051:** Added a server-side booking state machine with allowlisted transitions, terminal-state protection, version increments, transition guards, and bounded metadata.
- **NS-052:** Added append-only, idempotent booking timeline events with state reconstruction and parameterized persistence.
- **NS-053:** Added an ownership/permission-aware BookingService for draft, quote, offer, accept/decline, reservation, travel, trusted arrival/active/complete, settlement, cancellation, expiration, and interruption flows; catalog and quote authority fail closed when no server resolver is configured.
- **NS-054:** Added ordered, TTL-bound, atomic reservation locks and provider compensation with idempotent retries and booking-scoped release.
- Review hardening now preserves all resources across incremental reservation calls and keeps release idempotent without touching other bookings.
- Added `sql/011_booking_core.sql`, migration/bootstrap wiring, S05 contract coverage, and the S05 sprint report.
- Local S05 exit-gate tests pass; the running FiveM client completed `Stopping → Creating script environments → Started resource gnsh-nightshift` with no resource-specific client errors, and the local player endpoint is healthy. The development config still defaults to `persistence=false`; the persistence-enabled runtime gate is recorded below.
- Added a runtime-only `nightshift_persistence` convar opt-in that applies an immutable config copy and auto-wraps the oxmysql adapter when FiveM exposes it; the development default remains deferred and missing runtime database wiring still fails closed.
- Added regression coverage for the runtime convar, oxmysql adapter normalization, and default bootstrap-to-migration wiring.
- Added secret-free FiveM bootstrap diagnostics so resource logs identify `ready` versus typed startup failure, persistence status, database presence, and migration version.
- Bootstrap diagnostics now include persistence/database/migration status directly in the console message, including an explicit `deferred` marker when the development DB gate is intentionally skipped.
- Fixed FiveM runtime native lookup to call `GetConvar` and resolve `MySQL`/`exports` directly; replicated convars are now visible inside the resource sandbox instead of being mistaken for the development default.
- Fixed the migration runner to resolve `LoadResourceFile`/`GetCurrentResourceName` through direct FiveM native lookup; SQL assets can now be loaded during the persistence bootstrap.
- Fixed multi-statement SQL migrations by splitting quoted-safe statements before the final schema marker; oxmysql transactions no longer send adjacent `CREATE`/`ALTER` statements as one query.
- Live persistence gate passed: after `setr nightshift_persistence true` and a controlled `restart gnsh-nightshift`, FXServer logged the migration applications and `NightShift server ready (persistence=true database=true migration=11)`. The connected `Gnesh` player endpoint remained healthy, and the latest FiveM client log contained no `gnsh-nightshift` script errors.

### S04 — Identity & Profiles

- **NS-040:** Added server-side stable identity mapping from persistent player identifier plus character ID; reconnects refresh only ephemeral source mappings, while character switches/source reuse produce distinct keys and safe display aliases.
- **NS-041/042:** Added immutable worker/client profile domain models, identity-scoped repositories, versioned create/read/update services, and character-isolated persistence fields.
- **NS-043:** Added allowlisted centralized permissions with framework job/grade mappings, ACE/custom trusted hooks, lifecycle cache invalidation, and fail-closed unknown/malformed decisions.
- Added `sql/010_identity_profiles.sql` to extend the existing profile tables without changing applied S02 migration checksums, and wired profile/permission services into the bootstrap stage.
- Added S04 identity/profile/permission contract coverage; live FiveM/character and production MySQL smoke remain deferred to the final runtime gate.

### S01 — Resource Foundation

- Added the Lua 5.4 FiveM resource manifest and deterministic server/client bootstrap lifecycle.
- Added fail-fast provider/config schemas, feature flags, abstract service packages, location/NPC profile validation, and safe demand/heat placeholders.
- Added runtime-neutral Result, UTC Clock, correlation-aware Logger, recursive sensitive-field redaction, and isolated committed internal Event Bus contracts.
- Added pure-Lua lifecycle, configuration, core-contract, and event-bus regression coverage; database, providers, repositories, product services, and jobs remain deferred to S02+.
- Hardened S01 after direct review: server bootstrap now starts on resource load, explicitly invalid stage/config results fail closed, Result values are caller-copied, non-finite clock input is safe, and token/webhook aliases are redacted.

### S02 — Database & Persistence

- **NS-020:** Added a provider-neutral database contract with query/single/scalar/insert/update/transaction operations, normalized affected-row/insert results, typed health failures, and an injectable oxmysql adapter; no service code depends on driver globals.
- **NS-021:** Added ordered, checksum-verified migration execution with fresh-install/repeat-boot handling, out-of-order/name drift detection, transactional migration markers, and production fail-closed database bootstrap integration; development defaults remain safely deferred without an adapter.
- **NS-021 review hardening:** Classified missing schema errors, guarded malformed adapter/runner results, used positional migration marker parameters, and kept database/migration failures typed and fail-closed.
- **NS-022:** Added versioned InnoDB schema migrations for worker/client profiles, bookings/events, NPC workers, locations/reservations, deposits/payments, reviews, favorites, relationships, mutable versions, and lookup/idempotency indexes.
- **NS-023:** Added a provider-neutral base repository with safe identifier quoting, immutable row mapping, parameterized CRUD reads/inserts, conditional expected-version updates, and distinct not-found/version-conflict/state-unknown errors; documented repository boundaries and conventions.
- **S02 review hardening:** rejected empty transactions and false health signals, protected migration file loading, added conditional versioned deletes, and expanded regression coverage for fail-closed persistence behavior.
- Added the S02 sprint report; provider-specific adapters, aggregate repositories, domain services, jobs, and live database/FiveM smoke remain deferred to later sprints.

### S03 — Provider / Adapter Layer

- **NS-030:** Added a framework-neutral normalized identity/job/lifecycle contract with immutable DTOs, capability declarations, and isolated callback registration.
- **NS-031/032/033/034:** Added independently injectable QBCore, Qbox, ESX Legacy, and Standalone adapters; provider objects never cross the normalized boundary, and ESX/Standalone expose explicit internal availability fallbacks.
- **NS-035:** Added fail-closed money contracts and QBCore/Qbox/ESX/Standalone adapters for account validation, balance checks, add/remove, transfer compensation, reason propagation, and atomicity capability reporting.
- **NS-036:** Added optional phone, housing, motel, dispatch, appearance, evidence, client target, and client notify interfaces with capability/health reporting and safe no-op/fallback behavior when integrations are absent.
- **NS-037:** Added explicit/auto provider resolution, ambiguity detection, dependency validation, resolved capability diagnostics, and bootstrap adapter-stage integration.
- Hardened provider callbacks and money operations against malformed payloads, nested job grades, false operation results, and dynamic availability errors.
- Preserved adapter metatables when Result envelopes carry runtime provider instances, so resolved adapters retain their callable contracts without exposing native handles.
- Added pure-Lua provider contract coverage and manifest/load-order verification; live FiveM/framework smoke remains deferred until a runtime is available.
- Added the S03 sprint report; S04 identity/profile work is intentionally deferred.

### S00 — Specification Freeze

- Initialized repository with `dev` as the development branch and `main` as the release branch.
- Added normative domain invariants for unified Worker/Client booking, participant validation, settlement, NPC identity, and location reservations.
- Added provider capability matrix with server-authoritative contracts and safe fallbacks.
- Added five architecture decision records for booking, NPC entities, authority, locations, and OneSync ownership.
- Hardened the final S00 contracts with the complete canonical Booking lifecycle, deterministic alternate/recovery transitions, and explicit travel-state mapping.
- Defined durable non-reassignable location quarantine until confirmed release/reconciliation, plus atomic or compensatable split-leg settlement with conditional query/replay capability gates.
- Clarified configuration-driven cancellation refunds/deposit releases and the healthy, fresh server-owned internal availability fallback.
- Added the S00 Sprint Report; production resource implementation remains intentionally deferred until S01.
- Kept S01 Resource Foundation and all runtime/FiveM implementation deferred.
- Refreshed the codebase-memory index after final S00 contract hardening; S01 remains deferred.
