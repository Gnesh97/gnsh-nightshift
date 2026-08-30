# S11 Worker Mode Vertical Slice

This scenario is the exit-gate contract for the Worker Mode negotiation slice.
All authoritative decisions happen on the server; the client only forwards a
booking/session token and a registered location reference.

## Preconditions

- The worker is explicitly `AVAILABLE`.
- Demand is high enough to generate a logical NPC customer in an allowlisted
  district and discovery zone.
- A service package and registered location are available.
- The settlement adapter is enabled with a durable idempotency capability (or a
  deterministic test double is injected).

## Flow

1. Generate and claim one NPC customer opportunity.
2. Create the deterministic customer offer from package price, budget class,
   demand band, and profile traits.
3. Submit a bounded worker counter. The server accepts, counters, or walks away;
   client totals never become authoritative.
4. Bridge an accepted negotiation into the existing BookingService. Freeze the
   accepted negotiated price as the quote/agreed-price snapshot, reserve the
   registered location, and lock worker availability to `BUSY`.
5. Advance the booking through travel and server-verified arrival.
6. Start an appointment session. The one-time token is bound to booking, actor,
   and location; remote actors, wrong bookings, and unverified proximity fail.
7. Complete only after the configured minimum duration. The server performs the
   canonical `COMPLETED -> SETTLED` transition and updates worker counters.
8. Release the location hold and worker `BUSY` lock after settlement.
9. Replay the completion token and repeat settlement after a process restart;
   both operations must be idempotent and must not create a second payment or
   increment the profile counter twice.

## Expected result

- Negotiation ends in `ACCEPTED` with a frozen integer price inside server bounds.
- One booking reaches `SETTLED` with the same frozen amount.
- One settlement idempotency key is used; replay returns the existing payment.
- The worker completed counter increases once and availability returns to
  `AVAILABLE`.
- Invalid actor, location, duration, version, token, and replay requests fail
  with typed errors.

## Local contract coverage

`tests/s11_negotiation_contracts.lua`, `tests/s11_session_contracts.lua`, and
`tests/s11_worker_mode_contracts.lua` cover the deterministic offer/counter,
booking bridge, travel/session completion, one-time settlement, profile counter,
and BUSY release assertions. The FiveM commands are development-only and are
documented in the S11 sprint report.
