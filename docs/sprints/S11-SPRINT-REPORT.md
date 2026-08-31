# S11 Sprint Report — Worker Mode Negotiation & Vertical Slice

## Scope

S11 connects the S10 logical NPC customer opportunity to the existing booking
and settlement core. Negotiation, booking creation, session completion, and
settlement remain server-authoritative; no client-supplied price, coordinates,
or completion state is trusted.

## Delivered

- **NS-110:** Added an immutable negotiation aggregate and deterministic service
  for bounded NPC offers, worker counters, patience/round limits, acceptance,
  decline/walk-away, expiry, ownership checks, idempotency, and frozen accepted
  price snapshots.
- Worker identity references accept the canonical length-prefixed identity keys
  emitted by the FiveM/QBCore identity service.
- Fixed a BookingService permission-service field/method name collision exposed
  by the live S11 accept path; injected permission authorization now reaches the
  service without attempting to call the dependency table as a function.
- Fixed MariaDB DATETIME snapshot serialization and oxmysql zero-date row
  normalization, so negotiated quote expiry values survive persistence and
  booking rows remain mappable. Worker-mode acceptance now resumes safely from
  a partially persisted QUOTED/OFFERED/ACCEPTED booking.
- **NS-111:** Added the WorkerModeService bridge from a claimed NPC customer to
  the canonical BookingService. It selects registered packages/locations,
  applies an authoritative negotiated quote, creates the normal booking
  lifecycle, reserves the location, and locks worker availability to `BUSY`.
- **NS-112:** Added an appointment session verifier with actor/booking/location
  binding, server-side proximity verification hooks, minimum duration, one
  active session per actor, optimistic booking versions, and one-time completion
  tokens. Added a thin client transport that never decides completion.
- **NS-113:** Added the worker-mode vertical-slice contract scenario, development
  smoke commands, bootstrap/manifest wiring, and regression tests for settlement
  once, profile counter updates, availability release, replay, and restart-safe
  settlement semantics.
- Added an explicitly development-only settlement dry-run fallback. It uses a
  virtual, idempotent adapter with a synthetic NPC payer, never touches QBCore
  balances, and lets the full session-completion path be exercised without a
  second player source. Production/live payment adapters remain capability-gated.

## Verification

- `lua tests/run.lua` — pass (S05–S11 plus core, provider, repository,
  migration, schema, and profile contracts).
- The booking contract suite now covers an injected permission service on the
  draft-creation path that previously failed during live S11 acceptance.
- Booking contracts cover SQL DATETIME/zero-date row normalization and UTC epoch
  serialization; worker-mode contracts cover partial booking resumption.
- Lua parser check — pass for all Lua files.
- `git diff --check` — pass.

## Runtime Gate

The S11 commands are development-only and are automatically available in the
development environment. The existing `nightshift_s10_smoke_commands=true`
opt-in also enables S11 for backward-compatible sprint progression, including
hosts that report an unset S11 convar as `false`. The command sequence is:

```text
/nightshift_s11_begin [district] [zone] [package]
/nightshift_s11_counter [negotiationId] [amount]
/nightshift_s11_accept [negotiationId]
/nightshift_s11_travel [bookingId]
/nightshift_s11_arrive [bookingId]
/nightshift_s11_session_start [bookingId] [locationRef]
/nightshift_s11_session_complete [token] [bookingId] [locationRef] [payerSource]
```

The session verifier requires either the configured proximity callback or the
server's native player/location check. In development, the default
`developmentSettlement` feature supplies a labeled virtual dry-run settlement
when real payments are disabled; it has no money effect and resolves the NPC
payer without a source ID. Live settlement still requires an enabled money
adapter with safe atomic/idempotent capabilities and a real payer resolver;
otherwise it fails closed with `SETTLEMENT_NOT_READY` and does not mint payment.

## Exit Gate

- Negotiation domain: PASS
- Unified booking bridge: PASS
- Appointment session verifier: PASS
- One-time settlement/profile update: PASS (local injected vertical slice and
  development dry-run runtime path; no real money effect)
- Restart-safe settlement contract: PASS via existing durable settlement
  idempotency and the S11 replay assertions

**S11 Exit Gate: PASS — local contracts and parser checks complete. Development
FiveM player/session smoke can now complete through a clearly labeled dry-run;
live financial settlement remains the operator runtime gate until a real
idempotent/atomic money adapter is supplied.**
