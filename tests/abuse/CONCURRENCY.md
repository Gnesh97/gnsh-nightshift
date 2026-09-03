# Concurrency Matrix (S27 / NS-273)

The following races must have one deterministic winner. Services use expected
versions, atomic reservation locks, idempotency keys, or terminal-state guards
so the loser receives a typed error without a second financial effect.

| Race | Winner | Loser outcome |
| --- | --- | --- |
| Two clients reserve one NPC worker | first atomic availability lock | WORKER_BUSY / availability conflict |
| Two bookings reserve one room | first provider reservation | typed location reservation conflict |
| Two settlement requests | first terminal settlement | idempotent replay; no duplicate payment |
| Cancel vs complete | first valid booking transition | version/state conflict |
| Refund vs settlement | settlement terminal state | refund eligibility/terminal conflict |
| Book Again vs normal reserve | first worker/location lock | reservation conflict; quote can be retried |
| Worker logout vs booking accept | logout cleanup or accept lock winner | stale version/worker availability failure |

Run the focused Lua contracts with lua tests/run.lua; the service-level tests
exercise the same expected-version and lock boundaries used by runtime handlers.
