# NightShift server API

S25 exposes a deliberately small, read-only surface for other server resources. Every
successful response uses the existing NightShift.Result envelope and public DTOs omit
private profile, payment, token, and credential fields.

## Exports

The resource registers these exports after the server bootstrap:

- GetBooking(bookingId) — returns the safe booking DTO.
- ListAvailableNPCWorkers(options) — returns bounded marketplace worker cards.
- GetClientProfileSummary(playerSource) — returns a safe client profile summary.
- ListLocationProviders() — lists provider IDs and capabilities.
- GetHealth(options) — returns an admin-gated, redacted diagnostics snapshot.
- GetSecurityStatus() — returns bounded rate-limit and action-token counters.
- CreateExternalBookingRequest(...) — intentionally returns API_FORBIDDEN until an
  authenticated caller contract is installed.

Exported writes are not enabled by default. Provider registration remains available only
through the existing server-owned LocationProviderApi, so an untrusted resource cannot
mutate the provider registry through the public read surface.

## Domain events

Committed booking state changes are mirrored to the internal event bus and native server
events with these stable names:

nightshift:bookingCreated, nightshift:bookingAccepted,
nightshift:npcWorkerEnRoute, nightshift:bookingArrived,
nightshift:bookingCompleted, nightshift:bookingSettled,
nightshift:bookingCancelled, nightshift:safetyAlert, and
nightshift:reputationChanged.

Consumers should treat payloads as public DTOs and use correlationId from the event
metadata for tracing.

The NUI gateway applies a source/method rate limit before dispatch. Critical action
tokens are available to server-owned callers through NightShift.ActionTokenStore;
enforcement is opt-in until every caller has migrated.

## Idempotency

NightShift.IdempotencyStore provides bounded claim/complete/replay semantics. A caller
must claim a (scope, key, payload) before completing it. Reusing a key with a different
payload returns IDEMPOTENCY_CONFLICT; a concurrent pending call returns
IDEMPOTENCY_IN_PROGRESS. Entries expire through the configured TTL and are purged by
store:purge(now, limit).

## NUI methods

The embedded client bridge sends a request ID, method, and object payload to the
server. Supported method families include marketplace:list, booking:quote,
booking:confirm, client-mode:*, client-bookings:list, favorite:*,
relationship:get, review:*, and book-again:*. Responses retain the request ID
and use the Result envelope. Unknown methods and malformed payloads fail closed.

## Calling conventions

Read exports only from trusted server resources. Exported DTOs are public and
redacted; they are not a replacement for an authenticated booking command. A
caller must use IDs and tokens returned by the server and handle typed
unavailable, expired, conflict, and rate-limit errors.
