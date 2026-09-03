# S12 Sprint Report — Marketplace NUI & Client Booking Read Model

## Scope

S12 adds the player-facing NightShift NUI surface over the server-authoritative marketplace and booking core. The browser receives typed, privacy-safe data; identity scoping, pricing, booking state, and history pagination remain server-side.

## Delivered

- **NS-120:** Added typed NUI request/response maps, request IDs, a safe client-to-server bridge, and a local development mock.
- **NS-121:** Added the Swiss-style marketplace surface with shadcn components, filter controls, pending/error/empty states, and server-owned worker cards.
- **NS-122:** Added the booking composer for package and meeting-mode selection, short-lived quote display, and quote-ID-only confirmation. The server now resolves the player and worker, prices the request, persists the quote binding, and completes confirmation through the existing booking state machine and atomic worker/location reservation service.
- **NS-123:** Added `ClientBookingQueryService` and `BookingRepository:findForClient`. The read model resolves the player identity, optionally binds the persisted client profile, returns current/upcoming/history groups with bounded pagination, and exposes only safe booking fields.
- Added the `client-bookings:list` NUI callback and bootstrap/manifest wiring. No server.cfg change is required for this feature.
- Added the `booking:quote` and `booking:confirm` NUI callbacks, quote lookup by `quote_id`/`agreed_quote_id`, client request timeouts, and regression contracts for identity scoping, SQL predicate validation, pagination, worker-name sanitization, ETA, internal-field privacy, quote expiry, atomic reservation, and idempotent confirmation.
- Hardened the client command path against source-ID reuse: quote idempotency is identity-scoped and input-bound, confirmation checks booking ownership even on idempotent `RESERVED` retries, and ambiguous quote matches fail closed. The client bridge rejects duplicate request IDs and caps pending requests.

## Verification

- `lua tests/run.lua` — pass (S05–S12 plus core, provider, repository, migration, schema, and profile contracts; includes source-reuse and ambiguous-quote guards).
- `npm --prefix web run build` — pass (TypeScript and Vite production build).
- Lua parser checks — pass for the changed server, callback, service, and test files.
- `git diff --check` — pass.

## Runtime Gate

After the resource is restarted by the operator, opening the existing marketplace event displays the NUI. The reservation panel calls `client-bookings:list` for the current player, requests a server-authoritative quote, and confirms using only the quote ID. The server returns `NUI_CALLBACK_UNAVAILABLE` if the required booking/pricing/reservation stage is intentionally deferred.

## Exit Gate

- Typed NUI transport: PASS
- Marketplace and booking composer: PASS
- Client booking read model: PASS
- Identity-scoped, privacy-safe persistence query: PASS
- Production FiveM smoke: operator runtime gate (restart/open the existing UI and verify the reservation list)

**S12 Exit Gate: PASS — local contracts, TypeScript build, parser checks, and NUI wiring are complete. Stop here before starting S13.**
