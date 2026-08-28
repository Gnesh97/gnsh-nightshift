# Changelog

All notable changes to NightShift are documented here.

## [Unreleased]

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
