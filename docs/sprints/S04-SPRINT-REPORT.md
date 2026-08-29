# S04 Sprint Report — Identity, Profiles & Permissions

**Date:** 2026-08-29

**Status:** PASS

**Scope:** NS-040, NS-041, NS-042, NS-043 only

## Completed tasks

- **NS-040 — Identity Service:** added stable persistent-identifier plus character-ID mapping, reconnect/source refresh, character-switch/source-reuse isolation, safe aliases, and unload cleanup of ephemeral source state.
- **NS-041 — Worker Profile:** added validated immutable worker domain values, identity-scoped repository queries, versioned updates, availability/alias/trait/counter fields, and create/read/update service operations.
- **NS-042 — Client Profile:** added validated immutable client domain values, per-character repository isolation, versioned updates, completion/cancellation/no-show/rating/tier/deposit-risk fields, and create/read/update service operations.
- **NS-043 — RBAC / Permission Service:** added allowlisted permission policy, normalized job/grade rules, server-side ACE and trusted custom hooks, fail-closed decisions, and job/unload cache invalidation.
- **Schema/bootstrap integration:** added migration `010_identity_profiles.sql`, profile repositories and services to the server manifest, and repository/service construction after database/provider stages.
- **Direct review hardening:** rejected unloaded identities, preserved snake_case row mapping, omitted nil SQL parameters, avoided stale denial caching, propagated post-create read failures, and kept source IDs out of persistence keys.

## Changed files

- `server/services/identity_service.lua`
- `server/domain/worker_profile.lua`
- `server/repositories/worker_profile_repository.lua`
- `server/services/worker_profile_service.lua`
- `server/domain/client_profile.lua`
- `server/repositories/client_profile_repository.lua`
- `server/services/client_profile_service.lua`
- `server/services/permission_service.lua`
- `config/permissions.lua`
- `sql/010_identity_profiles.sql`
- `server/core/migrations.lua`
- `server/bootstrap.lua`
- `shared/errors.lua`
- `fxmanifest.lua`
- `tests/s04_profiles_contracts.lua`
- `tests/migrations_contracts.lua`
- `tests/schema_contracts.lua`
- `tests/run.lua`
- `docs/spec/IDENTITY_PROFILES.md`
- `CHANGELOG.md`

## Tests and verification

- `lua tests/run.lua` passed all S00–S03 contracts plus NS-040..NS-043 identity/profile/permission and bootstrap contracts.
- Lua parse check passed for all 58 Lua files.
- FiveM manifest S04 load-order assertions passed.
- `git diff --cached --check` passed; no live FiveM framework/player or production MySQL instance is available locally.

## Security / recovery / performance

- Persistent profile ownership uses the framework identifier/character composite; source IDs are runtime-only and cannot select another player's row.
- Profile SQL remains parameterized and uses the base repository's expected-version predicate; identity columns retain a unique constraint.
- Permission keys are server allowlisted; client-supplied flags are ignored, unknown keys deny, and malformed ACE/custom results fail closed.
- Only successful authorization decisions are cached; job/unload events invalidate stable-identity entries. No per-player polling loops or entity work were added.

## Known issues and deferred work

- Live QBCore/Qbox/ESX reconnect, character-switch, job-event, ACE, and MySQL migration smoke require the target FiveM server.
- Profile outcome counters and reputation deltas are placeholders; booking/payment services own authoritative increments in later sprints.
- `sql/010_identity_profiles.sql` must be applied by the normal migration runner before production profile reads.

## Exit Gate

- [x] Identity mapping.
- [x] Worker profile.
- [x] Client profile.
- [x] Central permissions.

**S04 Exit Gate: PASS. Stop before S05.**
