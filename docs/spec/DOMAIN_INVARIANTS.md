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
- **Reservation lifecycle**: the server-owned sequence for a location reservation: `RESERVED` (exclusive hold), `OCCUPIED` (active use), `RELEASE_PENDING` (cleanup requested), optionally `QUARANTINED` (cleanup uncertain and `reassignable=false`), then `RELEASED` (the only reusable terminal state).
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

### Closed state machines

The v1 Booking state enum is closed and exactly matches the product lifecycle:

```text
DRAFT, QUOTED, OFFERED, ACCEPTED, RESERVED, PREPARING, TRAVELLING,
ARRIVED, ACTIVE, COMPLETED, SETTLED, DECLINED, CANCELLED,
CLIENT_NO_SHOW, WORKER_NO_SHOW, EXPIRED, INTERRUPTED, DISPUTED,
FAILED, RECOVERY_REQUIRED
```

The canonical success path is deterministic:

| From | To | Guard | Domain side effect |
| --- | --- | --- | --- |
| `DRAFT` | `QUOTED` | Participants, abstract package, meeting mode, and requested typed location class are allowlisted; server pricing inputs are valid | Persist a server-authored, expiring quote and its line-item snapshot; no assignment or money effect |
| `QUOTED` | `OFFERED` | Quote belongs to this booking/actor, is current, and the server-selected recipient is eligible | Persist the bounded offer and offer expiry; no assignment or money effect |
| `OFFERED` | `ACCEPTED` | The authorized recipient accepts the current offer before expiry | Freeze normalized participants, assignment, package, meeting mode, agreed price, commission/deposit policy snapshots, and schedule |
| `ACCEPTED` | `RESERVED` | The reservation coordinator atomically owns every required worker/location/deposit hold for this booking, or rolls all acquisitions back | Bind stable reservation/hold references to the booking |
| `RESERVED` | `PREPARING` | Server clock reaches the preparation window and all required reservations remain owned, healthy, and current | Start server-owned preparation; no travel or settlement claim |
| `PREPARING` | `TRAVELLING` | A server travel plan is persisted and the required participant/location reservations remain valid | Start logical travel and its bounded ETA/audit timeline |
| `TRAVELLING` | `ARRIVED` | The server validates the meeting-mode-specific arrival barrier from canonical travel state and fresh normalized observations | Record attributable arrival timestamps; no session or settlement effect |
| `ARRIVED` | `ACTIVE` | Required parties satisfy the mode-specific arrival barrier, the location reservation is `OCCUPIED`, and Session is `CONSENTED` | Start the abstract session under server clock |
| `ACTIVE` | `COMPLETED` | Session is `COMPLETED`, package terms are satisfied, and consent remained current through completion | Freeze completion evidence and request independent resource-release workflows |
| `COMPLETED` | `SETTLED` | INV-003 confirms the atomic transfer, or both durable payment legs, succeeded for their stable keys | Commit the sole canonical settlement outcome |

Booking travel state maps to the separate NPC travel aggregate without replacing it: Booking `PREPARING` maps to NPC travel `PREPARING`, Booking `TRAVELLING` maps to NPC travel `EN_ROUTE`, Booking `ARRIVED` requires NPC travel `ARRIVED` where an NPC travels, and Booking `ACTIVE` maps to NPC travel `BOOKED`. NPC `DELAYED`, `RETURNING`, entity generation, and physical spawn/despawn remain travel/entity substates and never create additional Booking states or authority.

Alternate transitions are also closed:

| From | To | Guard | Domain side effect |
| --- | --- | --- | --- |
| `OFFERED` | `DECLINED` | The authorized recipient declines the current offer | Record reason; release any provisional, non-financial match claim |
| `DRAFT`/`QUOTED`/`OFFERED`/`ACCEPTED`/`RESERVED` | `EXPIRED` | The server clock reaches the persisted state-specific expiry before the next canonical transition | Record expiry; request resource release and eligible deposit-release policy separately |
| `DRAFT`/`QUOTED`/`OFFERED`/`ACCEPTED`/`RESERVED`/`PREPARING`/`TRAVELLING`/`ARRIVED` | `CANCELLED` | A server-authorized cancellation request passes actor, state, version, and policy checks | Record cancellation facts only; after commit, request resource cleanup and the independent cancellation-finance policy |
| `PREPARING`/`TRAVELLING`/`ARRIVED` | `CLIENT_NO_SHOW` | Server grace deadline passed and validated observations prove the client failed the required arrival barrier | Record no-show; request cleanup, reputation, and cancellation-finance policy independently |
| `PREPARING`/`TRAVELLING`/`ARRIVED` | `WORKER_NO_SHOW` | Server grace deadline passed and validated observations prove the worker failed the required arrival barrier | Record no-show; request cleanup, reliability, and cancellation-finance policy independently |
| `PREPARING`/`TRAVELLING`/`ARRIVED`/`ACTIVE` | `INTERRUPTED` | Consent is withdrawn, safety/provider/entity/location failure occurs, or a server-authorized pause is required | Stop progression immediately, persist cause and resumption deadline, and retain/quarantine resources as policy requires |
| `INTERRUPTED` | `ACTIVE` | Interruption is resolved before deadline; arrival/location/session guards are revalidated and consent is freshly attributable | Resume the same frozen booking/session without changing price or assignment |
| `INTERRUPTED` | `COMPLETED` | Durable session evidence proves completion occurred before the interruption was observed | Persist the already-proven completion; do not synthesize completion from the interruption |
| `INTERRUPTED` | `CANCELLED` | Resumption is declined/forbidden or an authorized cancellation is confirmed after the Session is stopped | Record cancellation facts; request cleanup and cancellation-finance policy independently |
| `ARRIVED`/`INTERRUPTED`/`COMPLETED` | `DISPUTED` | A server-authorized dispute suspends activation, completion acceptance, or settlement | Freeze disputed evidence and prohibit settlement while review is open |
| `DISPUTED` | `ACTIVE`/`COMPLETED`/`CANCELLED`/`FAILED` | An authorized, audited resolution selects exactly one target and all target guards are revalidated | Apply the recorded resolution; financial/resource policy remains independent and idempotent |
| Any non-terminal state except `RECOVERY_REQUIRED` | `RECOVERY_REQUIRED` | Restart/provider loss leaves a canonical prerequisite uncertain and normal progression cannot safely continue | Persist the prior state as `recovery_target_state`, block progression, settlement, and reassignment, and schedule reconciliation |
| `RECOVERY_REQUIRED` | recorded `recovery_target_state` | Authoritative reconciliation proves the stored target safe, its ordinary entry guards pass, and optimistic version matches | Restore only that recorded state; never skip ahead or infer success from absence |
| `RECOVERY_REQUIRED` | `FAILED` | Authoritative reconciliation proves recovery impossible and every external economic effect is resolved or safely compensated | Record unrecoverable failure and keep any uncertain allocation quarantined |
| Any non-terminal state except `ACTIVE`/`RECOVERY_REQUIRED` | `FAILED` | The server proves an unrecoverable failure, all economic outcomes are known/compensated, and no safer specific outcome applies | Record failure; request independent cleanup with quarantine on uncertainty |

`SETTLED` is the successful terminal state. `DECLINED`, `CANCELLED`, `CLIENT_NO_SHOW`, `WORKER_NO_SHOW`, `EXPIRED`, and `FAILED` are non-settling terminal Booking outcomes. `INTERRUPTED`, `DISPUTED`, `RECOVERY_REQUIRED`, and `COMPLETED` are non-terminal holding states with only the exits above. `ACTIVE` must enter `INTERRUPTED` before a failure, cancellation, or dispute is classified so the session is stopped first.

No other transition is valid. A terminal Booking cannot be edited, reactivated, or transitioned again; duplicate commands return the existing result without repeating effects. A terminal Booking may still have a separate refund, deposit release, location release, reversal, or audit record in `PENDING`/`UNKNOWN`/`QUARANTINED`; those child workflows never reopen or rewrite the Booking outcome.

The v1 Session state enum is closed: `PROPOSED`, `CONSENT_PENDING`, `CONSENTED`, `ACTIVE`, `COMPLETED`, `DECLINED`, `WITHDRAWN`, and `CANCELLED`. The only valid transitions are:

| From | To | Guard | Domain side effect |
| --- | --- | --- | --- |
| `PROPOSED` | `CONSENT_PENDING` | Abstract package is valid and offered | Record consent request; no settlement |
| `CONSENT_PENDING` | `CONSENTED` | Both required participants explicitly consent before consent lease expires | Record attributable consent timestamps |
| `CONSENT_PENDING` | `DECLINED` | A required participant declines or consent lease expires | Block activation/settlement |
| `CONSENTED` | `ACTIVE` | Owning booking passes `ARRIVED -> ACTIVE` and consent remains current | Start abstract session |
| `CONSENTED` | `WITHDRAWN` | Consent is withdrawn before activation | Block activation/settlement |
| `ACTIVE` | `COMPLETED` | Package terms complete while consent remains current | Record completion; permit booking completion |
| `ACTIVE` | `WITHDRAWN` | Consent is withdrawn during session | Stop session; block settlement |
| `PROPOSED`/`CONSENT_PENDING`/`CONSENTED`/`ACTIVE` | `CANCELLED` | Owning booking reaches a non-settling terminal outcome, or enters `INTERRUPTED` and cannot continue | Stop/block session and request the reservation release workflow |

`DECLINED`, `WITHDRAWN`, `COMPLETED`, and `CANCELLED` are terminal. No other Session transition is valid. Booking `ARRIVED -> ACTIVE` requires Session `CONSENTED`; settlement requires Booking `COMPLETED` and Session `COMPLETED`.

### INV-003 — Exactly-once canonical settlement

Settlement MUST happen exactly once and only on the canonical transition into `SETTLED`.

**Preconditions for `COMPLETED -> SETTLED`**

1. The booking is exactly in `COMPLETED`; `COMPLETED -> SETTLED` is the sole settlement transition.
2. The session has satisfied its abstract package requirements and consent boundary.
3. The server-side settlement service owns the transition and durably freezes one payment mode: an idempotent atomic transfer, or the split-leg protocol below.
4. The booking has not already entered `SETTLED` and has no terminal cancellation/expiry outcome.

Before any external call, the repository MUST commit a unique settlement intent keyed by `settlement:{booking_id}` and its frozen amount, accounts, participants, and payment mode. While an operation is in flight, declined with compensation outstanding, or externally uncertain, the settlement record remains `PENDING` or `UNKNOWN` and the Booking remains `COMPLETED`. Those statuses never authorize `SETTLED`.

**Allowed payment protocols**

1. **Atomic transfer:** invoke one adapter operation with stable key `settlement:{booking_id}:transfer`. The adapter contract guarantees all-or-nothing debit plus credit and idempotent replay of the same operation/result. Only confirmed `SUCCEEDED` authorizes `SETTLED`; `DECLINED` has zero money effect, and `UNKNOWN` is reconciled with the same key.
2. **Durable split legs:** create both leg records before executing either call. The payer debit key is `settlement:{booking_id}:debit`; the recipient credit key is `settlement:{booking_id}:credit`; a possible debit compensation key is `settlement:{booking_id}:debit:reverse`. Each leg has a closed status: `NOT_STARTED`, `PENDING`, `SUCCEEDED`, `DECLINED`, or `UNKNOWN`; the compensation additionally permits `REVERSAL_PENDING`, `REVERSED`, and `REVERSAL_UNKNOWN`. Repository uniqueness is enforced per booking, leg kind, and stable key.
3. In split-leg mode, debit executes first. Credit may execute only after debit is durably `SUCCEEDED`. A retry always uses the same leg key and payload fingerprint.
4. If debit is `DECLINED`, credit remains `NOT_STARTED`; the settlement safely becomes failed with zero transfer. If debit is `UNKNOWN`, no credit starts until query-by-key or guaranteed same-key replay resolves the debit.
5. If debit is `SUCCEEDED` and credit is `DECLINED`, the service MUST start idempotent compensation with the stable reversal key. The settlement remains `PENDING` until reversal is `REVERSED`; it may then become a safely compensated failure but never `SETTLED`.
6. If debit is `SUCCEEDED` and credit is `UNKNOWN`, the service records compensation as required but MUST first resolve the credit with query-by-key or guaranteed same-key replay. It MUST NOT blindly reverse a debit while the credit may have succeeded. If the credit is authoritatively absent/declined, execute the stable reversal; if it succeeded, do not reverse. Until the credit and any required reversal are both safely resolved, the settlement stays `UNKNOWN` and cannot produce `SETTLED`, terminal failure, a new attempt key, or reputation effects.
7. Provider restart, timeout, and process restart resume from the durable intent and per-leg rows. They never reconstruct progress from a client acknowledgement or start a replacement settlement.

**Postconditions**

1. The booking state changes to `SETTLED` once.
2. The durable settlement record is `SUCCEEDED`, keyed uniquely by Booking ID and `settlement:{booking_id}`. For atomic mode, the transfer is confirmed `SUCCEEDED`; for split-leg mode, both debit and credit are durably `SUCCEEDED` and compensation is `NOT_STARTED`.
3. `PENDING`, `UNKNOWN`, a declined leg, or any pending/unknown/succeeded debit reversal MUST NOT accompany or produce `SETTLED`.
4. Repeating the command returns the existing settlement result and creates no additional debit, credit, transfer, reversal, reputation, or Booking transition.
5. Every Booking transition other than `COMPLETED -> SETTLED` performs zero direct settlement effects. Later server-authorized refunds or reversals are separate financial records linked to the original operation; they are auditable and idempotent and never reopen the terminal Booking.

External adapters report normalized operation results but cannot authorize Booking state. If an operation can return `UNKNOWN`, the adapter contract MUST provide either auditable query-by-key or guaranteed idempotent same-key replay that returns the durable outcome. Query capability is therefore conditional, not universally required when atomic/idempotent replay already resolves uncertainty.

### INV-007 — Server-owned economic and assignment side effects

The server domain/service layer is authoritative for package/price freeze, worker assignment, reputation changes, settlement, refunds, and reversals. Client input is a request only; it cannot set price, award reputation, select an unauthorized worker, mark completion, issue a refund, or invoke a reversal. The repository durably records the server-approved terms and immutable audit references. External capabilities are accessed through neutral service ports; adapter-specific behavior remains outside the core and cannot change domain state directly.

Price and assignment MUST be frozen at `OFFERED -> ACCEPTED`; later client or external observations cannot rewrite them. Reputation changes occur only after the applicable authoritative terminal outcome and are idempotently keyed to that Booking outcome; successful-completion rewards require `SETTLED`.

A Booking cancellation, expiry, or no-show transition has no direct settlement, refund, capture, or release side effect. After that transition commits, a separate server-authorized cancellation-finance policy MUST evaluate the frozen policy snapshot, server timestamps, prior payment/hold records, and terminal reason. For eligible held deposits or prepaid amounts, it may request an idempotent full/partial refund or deposit release using stable keys linked to the original hold/debit/prepayment. The server computes the amount; client input cannot. Policy is configuration-driven (for example `OFFERED`, `RESERVED`, `TRAVELLING`, `ARRIVED`, or `ACTIVE`), may legitimately yield no automatic refund for an active session, and never reopens the terminal Booking. `PENDING`/`UNKNOWN` refunds or releases remain separate durable financial records and are reconciled with the same keys.

Adult-themed interaction is non-graphic and consent-based at the system boundary. Requests, package definitions, UI messages, logs, and persistence MUST contain only abstract package identifiers, durations/terms, and the closed session states above. Explicit sexual content, descriptions, media, or free-form erotic instructions are invalid domain input and MUST be rejected or excluded before domain processing. Consent MUST be explicit, attributable to the relevant participant, current for the session/package, and revocable before completion; a missing, expired, or withdrawn consent prevents activation and settlement.

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

Location reservation ownership is server-authoritative and MUST be bound to exactly one Booking. A location is not reusable while its reservation is `RESERVED`, `OCCUPIED`, `RELEASE_PENDING`, or `QUARANTINED`; each of those states has `reassignable=false`, and no other Booking may acquire, occupy, or be assigned that location.

The closed reservation state enum is `RESERVED`, `OCCUPIED`, `RELEASE_PENDING`, `QUARANTINED`, and `RELEASED`. `RELEASED` is the only terminal and reassignable state. The only transitions are:

| From | To | Guard | Domain side effect |
| --- | --- | --- | --- |
| `RESERVED` | `OCCUPIED` | Owning Booking is entering `ACTIVE`; provider-backed allocation and target observations are healthy/current | Mark occupied by the same Booking; retain exclusive owner |
| `RESERVED`/`OCCUPIED` | `RELEASE_PENDING` | The owning Booking completed or reached a non-settling outcome, the lease expired, or server reconciliation requires cleanup | Persist a stable release key and cleanup intent; retain owner lock and `reassignable=false` |
| `RELEASE_PENDING` | `RELEASED` | External release is confirmed `SUCCEEDED`, or an authoritative reconciliation proves the allocation absent; for server-only configured capacity, the server repository is the authoritative allocator | Atomically clear the active owner and set `reassignable=true` |
| `RELEASE_PENDING` | `QUARANTINED` | External cleanup is `UNKNOWN`, unavailable, timed out, failed without proof of absence, or provider state is stale | Persist failure/correlation/retry metadata; retain the allocation lock and `reassignable=false` |
| `QUARANTINED` | `RELEASE_PENDING` | A server recovery worker begins a same-key cleanup/reconciliation attempt under expected version | Record retry attempt without changing owner or reassignability |
| `QUARANTINED` | `RELEASED` | Authoritative provider query/reconciliation proves the allocation absent, or a same-key release is confirmed `SUCCEEDED` | Atomically clear owner and set `reassignable=true` |

The lease guard is server-clock based: `now >= lease_expires_at`, using the persisted version; client clocks cannot expire a reservation. Lease expiry starts release/reconciliation but is not proof that an external motel, housing, venue, or vehicle allocation disappeared. No reservation is reopened or transferred; after `RELEASED`, a new Booking receives a new reservation record/key. Duplicate lifecycle commands are idempotent.

**Acquire preconditions**

1. The server reservation service receives the request and resolves the canonical location ID.
2. The Booking exists, is eligible for reservation, and has no different active reservation.
3. The location is available and has no `RESERVED`, `OCCUPIED`, `RELEASE_PENDING`, or `QUARANTINED` record with `reassignable=false`.
4. The request satisfies any configured capacity/eligibility rules.

**Acquire postconditions**

1. Exactly one reservation record is created or idempotently returned.
2. The record names the Booking ID, location ID, lifecycle state `RESERVED`, `reassignable=false`, owner/lease data, provider allocation correlation, and version/expiry data needed for recovery.
3. A concurrent or replayed request cannot create a second owner.

**Occupy preconditions/postconditions**

Occupation is allowed only for the reservation's owning Booking after a neutral location capability port reports the required healthy, fresh, usable observation. The server atomically changes that reservation from `RESERVED` to `OCCUPIED`; it does not transfer ownership or permit another Booking to occupy it. Adapter-specific checks cannot grant domain ownership.

**Release/recovery rules**

1. Booking completion, cancellation, no-show, expiry, interruption classification, disconnect, or provider loss requests `RELEASE_PENDING`; it does not directly free the location.
2. Release/recovery MUST verify Booking owner, reservation version, stable release key, and provider allocation correlation. It is idempotent and clears the active owner only in the same atomic update that establishes `RELEASED` and `reassignable=true`.
3. `UNKNOWN`, timeout, missing callback, provider restart, stale target, or local lease expiry MUST enter/remain `QUARANTINED`; clearing a local owner field, deleting a row, or waiting out a TTL is never authoritative external cleanup.
4. Client messages, runtime adapters, payment adapters, and repositories MUST NOT directly free, transfer, overwrite, or mark an allocation reusable. Neutral capability ports report release/query results; the server lifecycle service owns the state transition.
5. Reassignment requires either confirmed same-key release success or authoritative reconciliation proving absence. If neither is available, quarantine persists indefinitely and the server selects a different allowlisted location or fails the affected flow closed.

## Enforcement ownership summary

| Rule | Domain | Service | Repository | Provider/runtime |
| --- | --- | --- | --- | --- |
| INV-001 common Booking | Defines one entity and mode derivation | Routes both modes to same workflow | Stores one schema/ID space | Supplies external observations only |
| INV-002/004 participants | Normalizes and allowlists | Resolves server identities and rejects before side effects | Persists normalized pair and constraints | Cannot assert unsupported type |
| INV-003 settlement | Defines canonical transition plus atomic/split-leg outcomes | Executes stable-key transfer/legs and safe compensation | Enforces intent/leg/reversal uniqueness | Reports normalized payment results only |
| Consent/session boundary | Defines abstract states and consent predicates | Gates activation/settlement | Stores abstract states only | Cannot provide explicit content |
| INV-005 NPC identity | Owns profile identity/lifecycle distinction | Authorizes association | Persists profile ID, not sole ped handle | Owns ephemeral ped lifecycle |
| INV-006 reservation | Defines lifecycle, quarantine, and reassignability predicates | Acquires/occupies/releases/reconciles | Enforces active-owner and quarantine locks | Reports physical allocation/release observations |

## Invalid examples (all rejected)

- A request with `PLAYER` worker and `PLAYER` client.
- A request with two NPCs, even if both have valid profiles/peds.
- A request with one participant, three participants, duplicate participant IDs, or a role missing/duplicated.
- A client-supplied `NPC` claim for a player identity, or a ped handle used without a server-resolved profile.
- A mode claim of Client Mode paired with `PLAYER` worker + `NPC` client.
- A second settlement call after the Booking is already `SETTLED`, a new retry key after an `UNKNOWN` result, or split-leg credit before debit success.
- A debit reversal while credit is still `UNKNOWN` and may already have succeeded, unless the provider offers an atomic conditional compensation contract.
- Activation or settlement with `CONSENT_PENDING`, `DECLINED`, expired consent, or withdrawn consent.
- An attempt to reserve a location already `RESERVED`/`OCCUPIED`/`RELEASE_PENDING`/`QUARANTINED`, or to reserve it for a second Booking.
- A client/provider request that deletes an active reservation or marks a different booking's reservation `RELEASED`.
- Treating lease expiry, a missing release callback, or provider outage as proof that an external allocation is reusable.
- A client-supplied cancellation refund amount, or a cancellation transition that directly moves money instead of invoking the separate idempotent policy after commit.
- A payload, log, package, or provider response containing explicit adult content instead of abstract package/session data.

These invariants are the minimum v1 contract. Later features may add capabilities only through a separately versioned specification change; they MUST NOT reinterpret or weaken these rules.
