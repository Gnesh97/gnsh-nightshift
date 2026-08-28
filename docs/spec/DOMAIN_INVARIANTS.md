# NightShift Domain Invariants

Status: S00 specification freeze (NS-001)

This document defines the v1 domain rules for bookings, participants, settlement, NPC identity, and location reservations. It is normative: an implementation must reject inputs and transitions that violate these rules rather than choosing an interpretation.

## Definitions

- **Booking**: the single domain entity representing one service request and session, regardless of whether it was created in Worker Mode or Client Mode. A booking has a stable identifier, normalized participant roles, a lifecycle state, and (when applicable) one location reservation.
- **Worker Mode**: a player offers or performs the service and an NPC is the customer.
- **Client Mode**: a player requests or receives the service and an NPC is the worker.
- **Participant type**: the normalized identity class `PLAYER` or `NPC`.
- **Participant role**: the normalized booking-side role `worker` or `client`. Role is distinct from participant type.
- **Session**: the bounded, consent-gated interaction represented by the booking. The domain records only abstract package/session data and states; it does not model or store explicit content.
- **Logical NPC profile**: persistent domain data describing an NPC (identity, configuration, availability, and history). It exists independently of any spawned game entity.
- **Physical ped entity**: the runtime game-world ped instance associated with an NPC profile for a period of time. It has a runtime/network identity and can despawn, be replaced, or become invalid without deleting the profile.
- **Reservation lifecycle**: the server-owned sequence for a location reservation: `RESERVED` (exclusive hold), `OCCUPIED` (active use), then `RELEASED` or `RECOVERED` (terminal availability restoration). A failed or abandoned hold may transition to `RECOVERED` through the same lifecycle service.
- **Canonical settlement transition**: the one domain transition into booking state `SETTLED`. No other state or event is a settlement authority.

## Booking lifecycle and common entity

### INV-001 — One booking entity for both modes

Worker Mode and Client Mode MUST use the same Booking entity, identifier space, lifecycle, settlement rules, reservation association, and persistence contract. Mode is data on the booking (or a derived view of its normalized participants), not a separate aggregate type.

**Preconditions**

1. A create request supplies participants and/or a mode claim.
2. The domain normalizes participant types and roles before accepting the booking.
3. The resulting combination is one of the combinations allowed by INV-004.

**Postconditions**

1. Exactly one Booking is created.
2. Its normalized roles and types determine the mode: `PLAYER worker + NPC client` is Worker Mode; `PLAYER client + NPC worker` is Client Mode.
3. Both modes use the same state machine and can only settle through INV-003.

The service MUST reject any mode-specific payload that would require a second booking schema or a mode-specific settlement path. A caller-provided mode is advisory and MUST agree with normalized participants.

### INV-002 — No player-to-player v1 booking

Player-to-player booking is outside the v1 core. It MUST NOT be represented as a supported mode, silently downgraded, or accepted as a generic booking.

**Precondition**: normalized participants have both participant types `PLAYER`.

**Postcondition**: booking creation is rejected with a domain validation error; no Booking, session, reservation, or settlement side effect is created.

## Session, consent, and settlement

### INV-003 — Exactly-once canonical settlement

Settlement MUST happen exactly once and only on the canonical transition into `SETTLED`.

**Preconditions for `... -> SETTLED`**

1. The booking exists and is in a non-terminal state permitted by the lifecycle.
2. The session has satisfied its abstract package requirements and consent boundary.
3. The server-side settlement service owns the transition and supplies an idempotency key tied to the booking and settlement attempt.
4. The booking has not already entered `SETTLED`.

**Postconditions**

1. The booking state changes to `SETTLED` once.
2. The settlement record, rewards/payment effects, and settlement timestamp are created/committed as one idempotent domain operation.
3. Repeating the same request returns the existing settlement result and creates no additional effect.
4. Every other booking transition (creation, acceptance, reservation, occupation, completion, cancellation, expiry, recovery) performs zero settlement effects.

The repository MUST enforce uniqueness of settlement by booking ID (and the idempotency key where stored). Providers may report results, but cannot authorize a second settlement. A partially failed operation MUST be retried/reconciled through the settlement service; callers MUST NOT manually award or reverse settlement outside the defined settlement/reversal contract.

Adult-themed interaction is non-graphic and consent-based at the system boundary. Requests, package definitions, UI messages, logs, and persistence MUST contain only abstract package identifiers, durations/terms, and session states such as `PROPOSED`, `CONSENT_PENDING`, `CONSENTED`, `ACTIVE`, `COMPLETED`, or `DECLINED/CANCELLED`. Explicit sexual content, descriptions, media, or free-form erotic instructions are invalid domain input and MUST be rejected or excluded before domain processing. Consent MUST be explicit, attributable to the relevant participant, current for the session/package, and revocable before completion; a missing, expired, or withdrawn consent prevents activation and settlement.

## Participants

### INV-004 — Normalize and allowlist participant combinations

The domain MUST normalize every booking participant into exactly one participant type (`PLAYER` or `NPC`) and exactly one booking role (`worker` or `client`) before validation. Type and role MUST be persisted/used in normalized form, not inferred from an untrusted display name, ped handle, or client-supplied mode.

The complete v1 allowlist is:

| Mode | Worker participant | Client participant | Result |
| --- | --- | --- | --- |
| Worker Mode | `PLAYER` worker | `NPC` client | Accept |
| Client Mode | `NPC` worker | `PLAYER` client | Accept |

Any other combination MUST be rejected, including `PLAYER` worker + `PLAYER` client (player-player), `NPC` worker + `NPC` client (NPC-NPC), duplicate participants, missing roles, unknown types, or more/less than one worker and one client.

**Preconditions**

1. The request contains exactly two participant references.
2. Identity resolution maps each reference to a server-known participant type.
3. Role assignment produces one worker and one client.

**Postconditions**

1. Accepted bookings contain exactly one worker and one client with one allowlisted type pair.
2. The resulting mode is deterministic from the normalized pair.
3. Rejection has no booking or downstream side effect.

Domain validation owns the allowlist; the repository persists only normalized values; providers may resolve identity but MUST NOT expand the allowlist.

## NPC profile and physical entity

### INV-005 — Logical profile and physical ped are separate objects

A logical NPC profile and its physical ped entity MUST be modeled as different objects with different authorities and lifecycles.

The profile is the authoritative domain identity and may persist across sessions, despawns, reconnects, and ped replacement. The ped is an ephemeral provider/runtime entity identified by its runtime handle/network ID and is valid only while spawned and controlled by the relevant server-authorized provider.

**Preconditions for association**

1. The server resolves an existing logical profile.
2. A provider reports a spawned ped entity for that profile.
3. The association includes profile ID, ped entity ID, and an association/version timestamp or equivalent freshness marker.

**Postconditions**

1. A booking stores the logical NPC profile ID, never a ped handle as the NPC's sole identity.
2. A ped despawn, invalid handle, or provider restart ends/removes the association without deleting or mutating the profile's identity/history.
3. A replacement ped may be associated only through a new server-authorized association operation.

The domain/service layer owns profile and booking identity. The ped provider owns spawn/despawn mechanics and reports capability/state; it cannot create a profile, change booking roles, settle, or bypass consent. A stale or client-only ped handle MUST be rejected for booking authorization.

## Location reservations

### INV-006 — Server-authoritative, booking-bound, exclusive reservation

Location reservation ownership is server-authoritative and MUST be bound to exactly one Booking. A location is exclusive while its reservation is `RESERVED` or `OCCUPIED`; no other booking may acquire, occupy, or be assigned that location during that interval.

**Acquire preconditions**

1. The server reservation service receives the request and resolves the canonical location ID.
2. The Booking exists, is eligible for reservation, and has no different active reservation.
3. The location is available and has no active `RESERVED` or `OCCUPIED` owner.
4. The request satisfies any configured capacity/eligibility rules.

**Acquire postconditions**

1. Exactly one reservation record is created or idempotently returned.
2. The record names the booking ID, location ID, lifecycle state `RESERVED`, owner/lease data, and version/expiry data needed for recovery.
3. A concurrent or replayed request cannot create a second owner.

**Occupy preconditions/postconditions**

Occupation is allowed only for the reservation's owning booking after the provider confirms the location is usable. The server atomically changes that reservation from `RESERVED` to `OCCUPIED`; it does not transfer ownership or permit another booking to occupy it.

**Release/recovery rules**

1. A reservation may become available only through the reservation lifecycle service, by `RELEASED` after normal completion/cancellation or `RECOVERED` after expiry, disconnect, provider failure, or reconciliation.
2. Release/recovery MUST verify the booking owner and reservation version/lease where applicable, be idempotent, and clear the active owner atomically.
3. Client messages, ped providers, payment providers, and repositories MUST NOT directly free, transfer, or overwrite an active reservation. The repository enforces uniqueness of active ownership; the provider reports physical availability but does not grant domain ownership.
4. A booking cancellation/expiry that has an active reservation MUST trigger the lifecycle service; a lost provider callback is handled by expiry/reconciliation, never by ad hoc deletion.

## Enforcement ownership summary

| Rule | Domain | Service | Repository | Provider/runtime |
| --- | --- | --- | --- | --- |
| INV-001 common Booking | Defines one entity and mode derivation | Routes both modes to same workflow | Stores one schema/ID space | Supplies external observations only |
| INV-002/004 participants | Normalizes and allowlists | Resolves server identities and rejects before side effects | Persists normalized pair and constraints | Cannot assert unsupported type |
| INV-003 settlement | Defines canonical transition and zero side effects elsewhere | Executes idempotent settlement | Enforces uniqueness/atomicity | Reports payment/reward capability only |
| Consent/session boundary | Defines abstract states and consent predicates | Gates activation/settlement | Stores abstract states only | Cannot provide explicit content |
| INV-005 NPC identity | Owns profile identity/lifecycle distinction | Authorizes association | Persists profile ID, not sole ped handle | Owns ephemeral ped lifecycle |
| INV-006 reservation | Defines lifecycle and ownership predicates | Acquires/occupies/releases/recovers | Enforces active-owner uniqueness | Reports physical availability/failure |

## Invalid examples (all rejected)

- A request with `PLAYER` worker and `PLAYER` client.
- A request with two NPCs, even if both have valid profiles/peds.
- A request with one participant, three participants, duplicate participant IDs, or a role missing/duplicated.
- A client-supplied `NPC` claim for a player identity, or a ped handle used without a server-resolved profile.
- A mode claim of Client Mode paired with `PLAYER` worker + `NPC` client.
- A second settlement call after the booking is already `SETTLED`, or a reward issued from `COMPLETED`/`CANCELLED` directly.
- Activation or settlement with `CONSENT_PENDING`, `DECLINED`, expired consent, or withdrawn consent.
- An attempt to reserve a location already `RESERVED`/`OCCUPIED`, or to reserve it for a second booking.
- A client/provider request that deletes an active reservation or marks a different booking's reservation `RELEASED`.
- A payload, log, package, or provider response containing explicit adult content instead of abstract package/session data.

These invariants are the minimum v1 contract. Later features may add capabilities only through a separately versioned specification change; they MUST NOT reinterpret or weaken these rules.
