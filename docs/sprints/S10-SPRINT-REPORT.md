# S10 Sprint Report — Worker Mode Demand & Customer Generation

## Scope

S10 adds bounded, server-authoritative Worker Mode demand and customer
opportunities. District behavior is configuration-driven and logical customer
profiles do not imply a world entity or client-owned coordinates.

## Delivered

- **NS-100:** Added immutable district descriptors and a district service for
  normalized baselines, price/risk/heat modifiers, time/day curves, allowlisted
  discovery-zone labels, availability, and maximum active logical customers.
- **NS-101:** Added an explainable demand service with server-clock time/day
  resolution, district baselines, active-worker supply, oversupply adjustment,
  recent-activity/police/heat hooks, optional event/weather modifiers, and
  bounded scores/bands.
- **NS-102:** Added server-side NPC customer opportunity generation for
  explicitly AVAILABLE workers, district/zone eligibility, cooldown and TTL
  handling, deterministic logical CUSTOMER profile generation, claim/dismiss/
  expiry states, and worker/global capacity limits. Added a client controller
  that accepts only a sanitized logical candidate DTO and maps a physical
  representation only through an explicit callback.
- **NS-103:** Added server-owned AVAILABLE/BUSY/OFFLINE worker availability,
  optional framework duty checks, idempotent opt-in transitions, booking locks,
  profile persistence hooks, and framework logout reset wiring.
- Added demand config/schema validation, shared enums/error codes, bootstrap and
  manifest registration, and S10 contract tests. No migration was needed.

## Verification

- `lua tests/run.lua` — pass (S05–S10 plus core, provider, repository,
  migration, schema, and profile contracts).
- Lua parser check — pass for all Lua files.
- `git diff --check` — pass.

## Runtime Gate

The development config now enables `features.demand` and automatically enables
the development-only command surface for a controlled smoke. Non-development
environments can explicitly opt in before restarting the resource:

Bootstrap also loads the smoke module from the resource filesystem as a
fallback when FXServer has a stale manifest cache.

```text
setr nightshift_s10_smoke_commands true
restart gnsh-nightshift
```

From an in-game player, run `/nightshift_s10_available [district]`, then
`/nightshift_s10_customer [district] [zone]`. Verify the server log reports
successful availability and one logical customer candidate; repeat the
customer command to verify cooldown/capacity rejection. Run
`/nightshift_s10_offline` after the smoke. Commands are not registered unless
the convar is explicitly enabled. Persistence remains independently
controlled by its existing convar. S11 negotiation is not part of this sprint.

Live FiveM smoke completed on the connected player (`source=1`): availability
for `vinewood` returned `AVAILABLE`; customer generation for
`vinewood_hills` returned one logical opportunity (`score=65`, `band=NORMAL`);
an immediate repeat returned `NPC_CUSTOMER_COOLDOWN`; and the offline transition
returned `OFFLINE`. Customer generation while offline returned the expected
`WORKER_AVAILABILITY_DENIED`.

## Exit Gate

- District profiles: PASS
- Demand engine: PASS
- Customer generator: PASS
- Player worker availability: PASS

**S10 Exit Gate: PASS — local contracts and live FiveM smoke complete. STOP.**
