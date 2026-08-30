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

## Verification

- `lua tests/run.lua` — pass (S05–S11 plus core, provider, repository,
  migration, schema, and profile contracts).
- Lua parser check — pass for all Lua files.
- `git diff --check` — pass.

## Runtime Gate

The S11 commands are development-only and are automatically available in the
development environment. The existing `nightshift_s10_smoke_commands=true`
opt-in also enables S11 for backward-compatible sprint progression; an
explicit `nightshift_s11_smoke_commands` value takes precedence. The command
sequence is:

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
server's native player/location check. Settlement also requires an enabled
money adapter and a payer source/resolver; otherwise it fails closed with
`SETTLEMENT_NOT_READY` and does not mint payment.

## Exit Gate

- Negotiation domain: PASS
- Unified booking bridge: PASS
- Appointment session verifier: PASS
- One-time settlement/profile update: PASS (local injected vertical slice)
- Restart-safe settlement contract: PASS via existing durable settlement
  idempotency and the S11 replay assertions

**S11 Exit Gate: PASS — local contracts and parser checks complete. Live FiveM
player/session/settlement smoke remains the operator runtime gate.**
