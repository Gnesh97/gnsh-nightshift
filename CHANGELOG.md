# Changelog

All notable changes to NightShift are documented here.

## [Unreleased]

### S05 — Unified Booking Core

- **NS-050:** Added one validated booking aggregate for player/NPC client and worker combinations, immutable service-package and quote/agreed-price snapshots, participant references, meeting/location data, lifecycle timestamps, idempotency, correlation, and external references.
- **NS-051:** Added a server-side booking state machine with allowlisted transitions, terminal-state protection, version increments, transition guards, and bounded metadata.
- **NS-052:** Added append-only, idempotent booking timeline events with state reconstruction and parameterized persistence.
- **NS-053:** Added an ownership/permission-aware BookingService for draft, quote, offer, accept/decline, reservation, travel, trusted arrival/active/complete, settlement, cancellation, expiration, and interruption flows; catalog and quote authority fail closed when no server resolver is configured.
- **NS-054:** Added ordered, TTL-bound, atomic reservation locks and provider compensation with idempotent retries and booking-scoped release.
- Review hardening now preserves all resources across incremental reservation calls and keeps release idempotent without touching other bookings.
- Added `sql/011_booking_core.sql`, migration/bootstrap wiring, S05 contract coverage, and the S05 sprint report.
- Local S05 exit-gate tests pass; the already-running FiveM instance shows `gnsh-nightshift` loaded and oxmysql connected. A controlled `restart gnsh-nightshift` is still required to apply migration 011 and exercise the new checkout in the live runtime.

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
