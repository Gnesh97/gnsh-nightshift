# S18 Sprint Report - Scheduling, Conflict Policy, and No-Show Processing

- Sprint: S18
- Completed tasks: NS-180 scheduled booking scheduler, NS-181 schedule conflict policy, and NS-182 no-show job.
- New files: config/scheduling.lua, sql/017_scheduling.sql, server/services/schedule_conflict_service.lua, server/jobs/scheduled_booking_job.lua, server/jobs/no_show_job.lua, server/dev/s18_smoke.lua, and tests/s18_scheduling_contracts.lua.
- Persistence: Migration 017 adds indexed due-work queries for scheduled bookings and ARRIVED no-show candidates. Queries are bounded, ordered, and parameterized.
- Scheduling contract: ACCEPTED bookings can be scheduled with a server-normalized timestamp, optimistic version checks, idempotent replay, and past-time rejection. Scheduled bookings activate through the booking state machine and remain restart-safe.
- Conflict contract: Worker and location overlaps are evaluated against buffered time windows. Package duration and the configured default duration produce deterministic windows; invalid references or timestamps fail closed with typed scheduling errors.
- Scheduler contract: One bounded batch job queries due SCHEDULED rows and promotes them to RESERVED. It uses a system actor, optimistic retries, idempotent recovery, and no per-booking timer threads.
- No-show contract: One bounded batch job queries stale ARRIVED rows and expires them through the booking service. Worker/client no-show reasons are resolved server-side, optional refund/deposit/reputation/event hooks are isolated from the terminal transition, and replay is idempotent.
- Configuration and API changes: Added validated scheduling settings, feature wiring, bootstrap job lifecycle management, and development-only S18 smoke commands. No server.cfg edits are required.
- Automated checks: lua tests/run.lua, syntax loading for all new Lua files, and git diff --check pass. The S18 suite covers configuration bounds, state transitions, parameterized due queries, worker/location conflicts, scheduling idempotency, scheduler batches, no-show hooks, and bootstrap lifecycle.
- Security and recovery: Inputs are allowlisted and bounded at configuration/service boundaries; SQL is repository-controlled; system jobs use explicit actors; optimistic versions, deterministic ordering, and restart-safe idempotency prevent duplicate activation or expiry.
- Live verification: FXServer smoke remains deployment-specific. After the resource is restarted, use the emitted S18 command help/results; no manual configuration injection is part of the implementation.
- Exit Gate result: PASS for S18 scheduling, conflict policy, scheduler activation, and no-show processing contracts. Stop here until the next sprint is explicitly requested.
