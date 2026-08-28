# ADR-003: Server Authority for Business State

Status: Accepted (S00 specification freeze)
Date: 2026-08-28

## Context

NightShift receives requests and observations from clients and external providers, but those sources can be stale, replayed, unavailable, or manipulated. Split authority would permit invalid lifecycle transitions, duplicate economic effects, conflicting reservations, or unaudited outcomes. Authority assignments are defined by [NightShift Domain Invariants](../spec/DOMAIN_INVARIANTS.md) and [Provider Capabilities](../spec/PROVIDER_CAPABILITIES.md).

## Decision

The server domain/service layer is the sole business authority for booking and session lifecycle, package and price freeze, location reservations, payments and canonical settlement, refunds and reversals, reputation, worker assignment, arrival, completion, and audit records.

Client claims and callbacks are untrusted requests or observations. A client cannot set or rewrite price, acquire or release reservation ownership, choose an unauthorized assignment, assert arrival or completion, cause payment/refund/reputation effects, or create an authoritative audit outcome. Every request must be resolved against server-known identity, authorization, canonical state, consent, reservation ownership, stable idempotency keys, and the relevant transition guards.

Providers report normalized capabilities and bounded observations/results through server adapters. They do not transition business state directly. Canonical state and durable internal audit records remain server/repository-owned; provider acknowledgements and external logs are supporting evidence only.

## Consequences

- All authoritative transitions and side effects have one validation and audit boundary.
- Client retries and duplicate callbacks can be handled idempotently without creating a second business effect.
- Provider failure or an `UNKNOWN` result blocks or defers the affected transition until server reconciliation; it is never interpreted as success.
- Presentation and interaction transports may vary without changing domain authority.

## Rejected alternatives

- Client-authoritative arrival, completion, price, or payment events were rejected because client state is not trusted.
- Provider-authoritative lifecycle or settlement was rejected because adapters expose capability and results, not domain authority.
- Shared client/server authority was rejected because concurrent claims would create ambiguous ownership and audit history.
