# S28 load / resmon / profiler matrix

This matrix is the production-scale baseline for the resource. It separates
logical records from physical entities and keeps every database operation
bounded.

| Scenario | Fixture | Required observation | Budget / gate |
| --- | --- | --- | --- |
| 50 concurrent active players | 50 player sources, marketplace open | no global player broadcast; only request-scoped summaries | one bounded page per request |
| 100 logical NPC profiles | 100 profile records, no bookings | profile list remains logical; no ped is created | physical peds stay at the streaming lease limit |
| 20 concurrent bookings | 20 active booking rows | booking reads use bounded pages and indexed status/time filters | no per-booking thread |
| 10 travelling NPCs | 10 travel plans, near-player only | navigation ticks only active nearby bindings | at most configured per-source/district leases |
| Large booking history | 1,000+ rows | pagination returns a bounded page and a continuation cursor | never load the complete history |
| Phone / standalone UI closed | no NUI focus or callbacks | idle client emits no polling/broadcast work | zero open-panel ticks |
| Demand / no-show scheduler | due rows above batch size | one due query per tick, then bounded activation/expiry batch | batchSize is the hard query limit |

## Automated gates

- tests/s28_streaming_budget_contracts.lua proves that logical workers are
  capped before physical spawn leases are issued.
- tests/s28_scheduler_cache_contracts.lua proves one bounded scheduler query,
  cache reuse, and domain-event invalidation.
- Existing S12/NUI visibility contracts prove closed UI has no active panel.

Run all deterministic gates with the command: lua tests/run.lua

## FXServer measurement pass

On a staging server, repeat the fixtures above while recording resmon 1 and
the profiler for at least 60 seconds per row. Record the p95 resource time,
peak memory, active leases, database query count, and NUI focus state. A
release is blocked if a closed client produces polling work, a query omits its
limit/index predicate, or physical NPCs exceed the configured budget.
