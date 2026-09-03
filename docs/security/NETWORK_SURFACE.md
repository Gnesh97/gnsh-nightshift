# Network Surface (S27 / NS-270)

'gnsh-nightshift:nui:request' is the only client-callable network entry point
owned by this resource. Every request must contain a bounded request id, an
allowlisted method name, and an object payload. The server derives the player
source from the event context; the client cannot select it.

| Method family | Methods | Server checks |
| --- | --- | --- |
| Marketplace | marketplace:list | bounded filters/page, privacy-safe DTO |
| Quote/booking | booking:quote, booking:confirm | server catalog/quote, ownership, quote binding, idempotency |
| Client mode | client-mode:confirm, travel, spawn, spawn-confirm, arrival, client-arrival, npc-arrival, pickup-arrival, vehicle-bind, vehicle-entry, destination-travel, destination-arrival, session-start, session-complete, travel-progress, recover | booking ownership, state preconditions, server location/entity checks |
| Booking history | client-bookings:list | identity scoping and bounded pagination |
| Reputation | review:submit, review:get, favorite:add, favorite:remove, favorite:list, relationship:get, book-again:quote, book-again:confirm | settled-booking eligibility, worker ownership, DTO allowlists |
| Admin | admin:diagnostics | permission-gated health snapshot and redaction |

The gateway applies a per-source/per-method token bucket before dispatch. A
rejected request returns RATE_LIMITED with a bounded retryAfter value and
never reaches a service. Configuration is allowlisted in
config/security.lua; unknown methods and malformed payloads fail closed.

Critical action tokens are available through NightShift.ActionTokenStore.
They bind an opaque nonce to actor, booking, and action, expire quickly, and
can be consumed once. actionTokens.enforce remains false by default so
existing callers continue to work; set it to true only after all callers
have been migrated to issue and present tokens.

Internal transition events and repository rows are never exposed by the NUI
surface. Public exports use the DTO mappers in server/api/dto.lua.
