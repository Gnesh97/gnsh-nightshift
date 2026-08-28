# ADR-004: Capability-Driven Location Provider Boundary

Status: Accepted (S00 specification freeze)
Date: 2026-08-28

## Context

NightShift may use configured, housing, motel/hotel, venue, or vehicle locations, and any of those integrations may be absent or unhealthy. Provider-specific branching in the core would make ownership and fallback behavior inconsistent. Arbitrary coordinates do not prove identity, eligibility, availability, or exclusive ownership. The normative reservation lifecycle is `INV-006` in [NightShift Domain Invariants](../spec/DOMAIN_INVARIANTS.md); neutral location capabilities and fallbacks are defined in [Provider Capabilities](../spec/PROVIDER_CAPABILITIES.md).

## Decision

Location resolution and physical availability use provider-backed, capability-driven ports. The server resolves an allowlisted logical location ID and evaluates the required capability behavior; provider names and raw provider payloads are not core decisions. Arbitrary client coordinates are never authoritative location identity or reservation evidence.

Reservation ownership is an atomic, server-owned record bound to exactly one Booking. Provider observations may establish that a target is usable or that external cleanup has occurred, but they cannot grant, transfer, release, or recover ownership. Occupation, release, and recovery remain guarded server lifecycle transitions with owner, version, stable operation key, external allocation correlation, and lease checks.

The durable reservation lifecycle is `RESERVED -> OCCUPIED -> RELEASE_PENDING -> RELEASED`, with `RELEASE_PENDING -> QUARANTINED` whenever cleanup is declined, unavailable, timed out, stale, or `UNKNOWN`. `RESERVED`, `OCCUPIED`, `RELEASE_PENDING`, and `QUARANTINED` all retain the location lock and `reassignable=false`; only `RELEASED` is reusable. Lease expiry requests cleanup but is not evidence that an external allocation disappeared. The server may transition to `RELEASED` only after a same-key external release is confirmed or authoritative reconciliation proves the allocation absent (or, for a purely server-owned configured slot, after the repository atomically releases it).

When a preferred capability is unavailable, the system uses only the documented safe fallback: another eligible allowlisted configured location when supported. If no safe configured option exists, the location-dependent flow is hidden, rejected, or deferred with a typed unavailable outcome before side effects. It never invents a location or falls back to arbitrary coordinates. An uncertain external cleanup remains durably `QUARANTINED`; clearing the local owner, deleting the row, a missing callback, or waiting out the TTL cannot make it reusable. A server recovery worker retries release/reconciliation with the same key, and quarantine persists if no authoritative answer is available.

## Consequences

- Core behavior depends on neutral capability contracts rather than integration product names.
- Concurrent bookings cannot acquire the same active location ownership.
- Provider outage or stale world targets do not delete logical locations, bookings, or reservation records.
- Booking completion, cancellation, no-show, or expiry can finish while location cleanup remains independently locked in `RELEASE_PENDING`/`QUARANTINED`; that does not permit reassignment.
- Degradation is deterministic and fail-closed when no allowlisted safe fallback exists.

## Rejected alternatives

- Trusting client-selected coordinates as a location was rejected because coordinates do not establish authorization or ownership.
- Allowing a provider to own the reservation lifecycle was rejected because physical allocation and business ownership are distinct.
- Treating lease expiry, provider outage, or an uncertain release as successful cleanup was rejected because it can assign one external room/slot to two bookings.
- Silent fallback to any nearby point or unverified room was rejected because it bypasses allowlisting, eligibility, exclusivity, and auditability.
