# S02 Sprint Report — Database & Persistence

**Date:** 2026-08-28

**Status:** PASS

**Scope:** NS-020, NS-021, NS-022, NS-023 only

## Completed tasks

- **NS-020 — Database Adapter:** added provider-neutral `query`, `single`, `scalar`, `insert`, `update`, `transaction`, and health-check contracts with parameter validation, normalized affected-row/insert results, typed failures, and injectable oxmysql/FiveM execution.
- **NS-021 — Migration Runner:** added deterministic ordered migration execution, fresh-install schema bootstrap, repeat-boot no-op behavior, name/checksum drift detection, out-of-order detection, transactional marker writes, and fail-closed production bootstrap integration.
- **NS-022 — Initial Domain Schema:** added nine MySQL/InnoDB migrations covering profiles, bookings/events, NPC workers, locations/reservations, deposits/payments, reviews/favorites/relationships, mutable versions, idempotency keys, and lookup indexes.
- **NS-023 — Repository Base Conventions:** added safe identifier quoting, parameterized reads/inserts, immutable row mapping, conditional expected-version update/delete, and distinct not-found/conflict/state-unknown errors; documented repository boundaries.
- **Direct review hardening:** rejected empty transactions and false health signals, classified missing schema errors, protected migration file loading, and expanded persistence regression coverage.

## Changed files

- `server/adapters/database/interface.lua`
- `server/adapters/database/oxmysql.lua`
- `server/core/migrations.lua`
- `server/repositories/base_repository.lua`
- `sql/001_schema_version.sql`
- `sql/002_profiles.sql`
- `sql/003_bookings.sql`
- `sql/004_booking_events.sql`
- `sql/005_npc_profiles.sql`
- `sql/006_locations.sql`
- `sql/007_payments.sql`
- `sql/008_relationships.sql`
- `sql/009_indexes.sql`
- `docs/spec/REPOSITORY_CONVENTIONS.md`
- `tests/database_contracts.lua`
- `tests/migrations_contracts.lua`
- `tests/schema_contracts.lua`
- `tests/repository_contracts.lua`
- `tests/run.lua`
- `fxmanifest.lua`
- `shared/errors.lua`
- `config/config.lua`
- `config/features.lua`
- `CHANGELOG.md`

## Tests and verification

- `lua tests/run.lua` passed database adapter, migration fresh/repeat/out-of-order/checksum, schema asset, repository mapping, and version-conflict contracts.
- `git diff --check` passed for S02 changes.
- No FiveM server or live MySQL instance is available locally; oxmysql execution and `ensure nightshift` runtime smoke remain environment checks.

## Security / recovery / performance

- SQL values remain parameterized; dynamic identifiers are allowlisted and quoted.
- Migration history fails closed on missing/unknown/out-of-order/name/checksum drift; migration markers are written in the same adapter transaction as schema SQL.
- Repository conditional version predicates reduce lost-update risk; services retain ownership of business invariants and retry policy.
- No credentials, client-triggered network events, or external I/O were added to core logic.
- S02 adds no product loops or entity work; schema indexes target expected booking/event/status lookups.

## Known issues and deferred work

- Live oxmysql/FiveM smoke, production migration execution, foreign-key policy, provider adapters, repositories for individual aggregates, domain services, and jobs remain deferred to later runtime/product tasks.
- `sql/009_indexes.sql` relies on the migration ledger for exactly-once application; recovery from a partially applied DDL batch needs live database verification.

## Exit Gate

- [x] DB adapter.
- [x] Migrations.
- [x] Core schema.
- [x] Repository conventions.
- [x] Version conflict test.

**S02 Exit Gate: PASS. Stop before S03.**
