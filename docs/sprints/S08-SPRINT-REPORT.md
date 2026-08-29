# S08 Sprint Report — NPC Profile & Marketplace Core

## Scope

S08 implements the logical NPC profile and marketplace foundation without coupling business state to a world ped or client-owned entity.

## Delivered

- NS-080: CUSTOMER/WORKER profile domain, persistent/semi-persistent lifetime, sanitized aliases, appearance references, bounded profile traits, districts, travel mode, availability, versioning, and repository mapping.
- NS-081: deterministic, seed-driven profile generator with weighted templates, bounded trait ranges, appearance references, duplicate alias avoidance, and completed-booking persistence promotion.
- NS-082: server-owned logical worker pool with availability state transitions, filterable reads, atomic reservation/release/occupancy, booking ownership checks, reservation TTL, and semi-persistent expiry.
- NS-083: bounded marketplace DTOs with stable public worker IDs, pagination, filter validation, price class and ETA preview inputs, and a privacy boundary that excludes internal traits and generation metadata.
- Migration \`014_npc_marketplace.sql\`, manifest load order, bootstrap wiring, and migration/schema contract updates.

## Verification

- \`lua tests/run.lua\` — pass (S05, S06, S07, S08, core, provider, repository, migration, schema, and profile contracts).
- \`luac -p\` — pass for all S08 Lua files and bootstrap.
- \`git diff --check\` — pass.

## Runtime Gate

The code path is ready for the next controlled FiveM restart. With persistence enabled, migration 014 should apply and the console should report \`NightShift server ready (persistence=true database=true migration=14)\`. Player marketplace/UI and physical NPC entity smoke remain intentionally outside S08 and are covered by later runtime phases.
