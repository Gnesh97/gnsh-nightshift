# NightShift Provider Capability Matrix

Status: S00 specification freeze (NS-002)
Normative scope: v1 provider contracts only; this document does not define a FiveM resource implementation.

## Purpose and boundaries

NightShift core decisions are made from a normalized capability registry and the behavior of neutral service ports. A provider adapter may detect an integration and translate its API, but neither the provider name nor a raw provider response is a domain decision. Core, domain, and service code MUST NOT branch on framework, phone, housing, motel, venue, vehicle, dispatch, target, notify, appearance, logging, or evidence product names.

Capabilities are immutable for a running adapter generation. A provider restart or loss invalidates its registered capabilities and triggers the fallback below; it MUST NOT rewrite Booking, Session, settlement, or reservation state. Detection is server-side at startup and on explicit health/reconnect events. Client observations are hints only and never grant authority.

Every adapter contract MUST return a normalized result (`supported`, `unavailable`, or a typed failure), bounded data, and a correlation reference safe for audit. Provider-specific errors, handles, and names stay in the adapter boundary. The core receives only the fields described here.

## Capability status and authority vocabulary

| Status | Meaning |
| --- | --- |
| **Required** | The capability is needed for the named paid/production flow. If absent, that flow is unavailable or must use the stated safe mode; no silent side effect is allowed. |
| **Optional** | The core remains valid without it. The stated fallback is deterministic and user-visible where relevant. |
| **Conditional** | Required only when the corresponding configured feature is enabled; configuration validation MUST fail closed when neither the capability nor its fallback exists. |

| Authority | Permitted responsibility |
| --- | --- |
| **Server/core** | Identity normalization, authorization, lifecycle transitions, assignment, price/package freeze, reservation ownership, settlement/refund/reversal, and audit. |
| **Server/adapter** | Calling an external integration and reporting normalized observations/results; never changing domain state directly. |
| **Client** | Rendering, local interaction, and submitting requests; never authoritative economy, arrival, completion, consent, assignment, or location ownership. |
| **Provider/runtime** | Physical effects such as UI delivery, entity presentation, world targeting, or dispatch transport. A runtime/network owner is not business authority. |

## 1. Framework identity, lifecycle, job, and duty

Framework integration is **Required** for framework mode. A standalone identity adapter is the supported fallback for development or servers without a framework. The core consumes `player.identity`, `player.lifecycle`, `player.job`, and `player.duty` capability behavior, not an integration label.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `framework.identity` | Server can resolve a stable player identifier and character identifier; optional display name is bounded and presentation-only. Identity resolution MUST reject client-supplied identity claims. | Required | Server/core + server adapter | Use the standalone stable identifier contract. If no stable identity exists, reject booking and do not create downstream state. |
| `framework.lifecycle` | Adapter reports loaded, unloaded, reconnect, and resource-reconnect events, keyed by stable identity; duplicate events are idempotent. | Required | Server/core | Poll/reconcile from server state on a bounded scheduler. Until reconciled, pause new authoritative actions and recover transient bookings/reservations by lease. |
| `framework.job` | Adapter returns normalized job name/grade and an immutable observation timestamp. Unknown/malformed values are unavailable, not trusted. | Conditional | Server/core | Treat job as unavailable; deny only features whose configured eligibility requires it, without inventing a job. |
| `framework.duty` | Adapter returns a current, server-observed normalized on-duty/available state (`available=true/false`), health, and timestamp, or explicitly reports unsupported. A stale, unhealthy, or missing observation is unavailable and MUST NOT be treated as available. | Conditional | Server/core | Use an internal server-owned availability toggle only if configured and healthy; otherwise worker assignment/acceptance requiring duty is unavailable. |
| `framework.events` | Adapter can subscribe to lifecycle, job-change, and duty-change events, with unsubscribe/restart safety. | Optional | Server adapter | Bounded reconciliation polling. Never let missed callbacks authorize a transition. |
| `framework.authorize` | Adapter can verify that a server source still maps to the resolved stable identity before a write. | Required | Server/core | Reject the write; do not rely on a stale source or client claim. |

Framework-specific normalization belongs only in the adapter. A core rule is therefore expressible as: “if `framework.identity` and `framework.lifecycle` are healthy, and the current `framework.duty` observation is healthy with `available=true` (or a configured healthy internal availability contract says so), permit the configured worker action.” Capability presence alone never means that a player is currently on duty.

## 2. Money, accounts, holds, deposits, refunds, and settlement

Money is **Required** for paid production flows and **Conditional** for any configured deposit or reward. All economic decisions are server-owned under `INV-003` and `INV-007`. Amounts, account selection, quote terms, and settlement outcomes supplied by clients are never authoritative.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `money.balance` | Server can query an allowlisted account and return a non-negative integer minor-unit balance. | Required for paid flow | Server/core requests; adapter observes | Mark paid booking unavailable; optionally allow an explicitly configured no-pay development mode that performs zero money effects and is clearly labeled. |
| `money.debit` / `money.credit` | Server adapter can debit/credit an allowlisted account with a stable operation key and returns `SUCCEEDED`, `DECLINED`, or `UNKNOWN`. | Required for paid settlement | Server settlement service | Keep booking non-settled and record `PENDING`/`UNKNOWN`; reconcile by the same key. Never substitute a client-side transfer or mark success locally. |
| `money.hold` | Adapter can place a temporary hold with `hold_key`, amount, expiry, configured account, and query-by-key. A hold is not a completed debit. | Conditional (deposit) | Server deposit service | Do not accept a deposit-requiring booking; no partial local reservation or implied charge. |
| `money.deposit.capture` | Adapter can capture an existing hold exactly once by the same stable booking/deposit key and configured account, and report an auditable result. | Conditional (deposit) | Server settlement service | Keep deposit `HELD`/`UNKNOWN`, block `SETTLED`, and reconcile; never capture through a new retry key. |
| `money.deposit.release` | Adapter can release an existing hold exactly once, keyed to the original hold and configured account, and report the result. | Conditional (deposit) | Server cancellation/recovery service | Keep `HELD`/`UNKNOWN` and retry/reconcile using the same key; do not claim funds were released. |
| `money.refund` | Adapter supports a refund/reversal operation linked to the original stable settlement key and a unique refund key; replay returns the existing result. | Conditional (refund feature) | Server settlement service | Record refund as unavailable/pending and retain the original audit trail; never silently mint funds or reopen the terminal Booking. |
| `money.settlement.query` | Adapter can query the external operation by stable key after timeout/restart. | Required when debit/credit can return `UNKNOWN` | Server settlement service | Keep durable status `UNKNOWN`; do not transition `COMPLETED -> SETTLED` until success is confirmed. |
| `money.accounts` | Adapter exposes only configured account kinds; account identifiers are mapped to opaque normalized keys. | Required for any account effect | Server/config | Reject unsupported account configuration at startup; never accept arbitrary account names from clients. |
| `money.idempotency` | Every hold, capture, release, debit, credit, and refund accepts a stable key and guarantees replay without duplicate effect, or provides query-by-key. | Required for any economic effect | Server settlement/deposit services | Disable the affected paid flow. A timeout is `UNKNOWN`, not success or permission to retry with a new key. |

The stable key is derived from the booking ID and operation kind (for example, deposit hold, capture, release, settlement, or refund). It is not generated per request or retry. Repeating a command returns the durable operation result with no second effect. Provider adapters cannot authorize the canonical `SETTLED` transition; only the server settlement service may do so after confirmed success.

## 3. Phone app and notification delivery

Phone integration is optional. A phone adapter may provide presentation and delivery, but it does not become a booking API or lifecycle authority.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `phone.app.register` | Adapter registers a versioned app definition and returns supported routes/actions; no provider-specific payload leaks into core. | Optional | Server adapter + client presentation | Use the standalone NUI for marketplace, booking, consent, and history views. |
| `phone.app.open` | Server-authorized request opens a bounded route/context for the owning player; context contains only privacy-minimal identifiers and abstract terms. | Optional | Server authorizes; client renders | Open the equivalent standalone NUI view or show a neutral notification with a manual-open action. |
| `phone.notification.push` | Adapter accepts a typed notification, recipient identity, deduplication key, and expiry; delivery result is `DELIVERED`, `UNAVAILABLE`, or `UNKNOWN`. | Optional | Server chooses recipients/content | Use standalone notification; if that is also unavailable, retain an in-app unread event and do not block the domain transition. |
| `phone.notification.query` | Adapter can report delivery/restart state by deduplication key, if delivery acknowledgement is exposed. | Optional | Server adapter | Treat delivery as best-effort; retry boundedly without duplicating the domain event. |

Phone absence never cancels a valid booking, grants consent, or suppresses safety state. Phone payloads MUST exclude explicit content, full participant history, money secrets, and provider handles.

## 4. Housing, motel/hotel, venue, vehicle, and configured-location capabilities

All location integrations implement the neutral location contract used by `INV-006`. A configured location is an allowlisted logical location record, not an arbitrary coordinate. Housing, motel/hotel, venue, vehicle, and generic configured-location capabilities are separate flags because a server may support one without the others.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `location.resolve` | Server resolves an allowlisted logical location ID to bounded category, eligibility, and a provider-neutral world target reference. Client coordinates are never accepted as identity. | Required for any location flow | Server reservation service | Use configured locations if available; otherwise the location-dependent flow is unavailable. |
| `location.reserve` | Server adapter can observe whether a location is usable; ownership remains a server reservation record bound to one Booking, with lease/version. | Required for activation at a location | Server/core | Reject or defer reservation; never let an adapter or client directly assign a room/spot. |
| `location.occupy` | Adapter reports usable physical target for the owning reservation; server atomically transitions `RESERVED -> OCCUPIED`. | Required for physical activation | Server reservation service | Keep reservation `RESERVED` and retry/reconcile; on lease expiry recover it. |
| `location.release` / `location.recover` | Adapter can clean up its external allocation; server lifecycle service transitions to `RELEASED` or `RECOVERED` idempotently. | Required for externally allocated locations | Server/core | If cleanup is unavailable, server lease/reconciliation clears active ownership only into a quarantined/non-reassignable state while recording cleanup failure for retry; it does not make the allocation available. |
| `location.configured` | Static config provides validated logical locations, capacity/eligibility, and safe world target metadata. | Required fallback; Conditional baseline | Server/config | Hide location-dependent modes if no valid configured locations exist. Never fall back to arbitrary coordinates. |
| `location.housing` | Adapter maps a logical location to an authorized housing/property target and reports availability without granting ownership. | Optional | Server reservation service | Use `location.configured`; if none, hide housing-dependent choices. |
| `location.motel` | Adapter maps a logical location to a motel/hotel room allocation and supports lease/release or authoritative failure reporting. | Optional | Server reservation service | Use configured non-motel locations; never emulate an unverified room allocation. |
| `location.venue` | Adapter reports configured venue availability/access constraints for the owning reservation. | Optional | Server/config + reservation service | Use other eligible configured locations or hide venue-only choices. |
| `location.vehicle` | Adapter resolves an allowlisted vehicle interaction/target and reports usable state; it does not define participant identity or booking ownership. | Optional | Server reservation service | Use a non-vehicle configured location; if the package requires vehicle use, make it unavailable. |
| `location.world_target` | Adapter resolves a current physical target from a logical location and reports generation/freshness. | Optional for non-physical flows | Server adapter observes; server owns logical state | Present the logical location and require an alternate configured target; never trust a stale handle or client-only coordinate. |

Provider outage, restart, or stale target ends only the external association. It does not delete the logical location, Booking, NPC profile, or reservation record. A reservation is released/recovered only through the server lifecycle service, with owner/version/lease checks. If external cleanup is unavailable, the server MUST quarantine the location allocation (or retain a non-overlapping lease) and block reassignment until release succeeds or an authoritative reconciliation proves the allocation is gone. Clearing the local owner alone MUST NOT make a motel, venue, vehicle, or housing allocation reusable.

## 5. Dispatch and safety

Dispatch is optional and is a transport for safety signals, not an incident or booking authority. Safety state and audit remain server-owned even when no dispatch exists.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `safety.alert` | Server adapter emits a typed alert with incident ID, urgency, coarse location reference, and minimal actor context; it returns delivery status. | Optional | Server safety service | Persist the incident and safety state; use in-app/standalone notification and configured staff/admin fallback. |
| `safety.alert.update` | Adapter can update/close an alert by stable incident ID without creating a duplicate. | Optional | Server safety service | Keep server incident open/closed according to the safety state and retry delivery; never alter domain state based on dispatch acknowledgement. |
| `safety.incident.audit` | Internal audit repository records check-in, panic, cancellation, and recovery events with minimal data. | Required for safety features | Server/core | If audit persistence is unavailable, fail closed for new safety-sensitive actions and surface an operational error; do not silently drop the incident. |
| `safety.coarse_location` | Server can produce a configured district/logical location reference without exposing exact private coordinates to non-participants. | Conditional | Server safety service | Emit an alert without location or use the configured district only; never send arbitrary player coordinates. |

Dispatch absence MUST NOT disable consent withdrawal, cancellation, server recovery, or incident recording. It only degrades external notification delivery.

## 6. Appearance and NPC presentation

Appearance is optional presentation. Logical NPC profile identity and history remain authoritative under `INV-005`; a ped handle or model is never an identity or booking credential.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `appearance.npc.apply` | Server-authorized presentation adapter applies an allowlisted profile/model preset to a spawned ped and reports generation/failure. | Optional | Provider/runtime presentation; server owns profile | Spawn/use a configured default adult NPC preset, or keep the NPC logical-only if no safe preset exists. |
| `appearance.npc.spawn` | Adapter reports a physical ped entity association for a known logical NPC profile, with runtime ID and freshness/generation. | Conditional for physical interaction | Server association service authorizes; provider owns mechanics | Keep logical NPC state and postpone physical interaction; never create a booking from a client-only ped. |
| `appearance.npc.despawn` | Adapter reports invalidation/despawn; association removal is idempotent and does not mutate/delete profile history. | Conditional for physical interaction | Server association service | Mark physical entity unavailable and recover/retry; preserve profile and booking authority. |
| `appearance.presentation.metadata` | Replicated metadata is bounded and non-sensitive (for example profile reference/generation), never full profile or session content. | Optional | Server writes; clients read | Render generic presentation with no replicated private data. |

Appearance failures never alter participant type, role, consent, completion, settlement, or reputation.

## 7. Target interaction

Target integration is an optional interaction convenience. It is distinct from phone delivery, basic notification, and server authorization.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `interaction.target` | Adapter registers/removes a bounded target action for a server-known logical entity/location and returns registration status. | Optional | Server validates action; client invokes request | Use a key/zone interaction with the same server validation, or a manual NUI action. |
| `interaction.target.entity_generation` | Target action includes logical reference plus entity generation and rejects stale entity bindings. | Conditional when entity targets are used | Server association service | Use logical location/zone interaction; never act on a stale handle. |

## 8. Notification interaction

Basic notification is an optional presentation convenience. Notification delivery is never a lifecycle or safety authority, and it is distinct from phone app delivery.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `notification.basic` | Adapter displays typed, localized, privacy-minimal notification and returns delivery status where possible. | Optional | Server selects message; client displays | Use standalone NUI toast/inbox. If no display exists, retain an unread server event and continue non-blocking workflows. |
| `notification.action` | Adapter supports a bounded action token/route with expiry; it does not accept arbitrary event names or state mutations. | Optional | Server validates token and booking/actor binding | Show an informational message and require reopening the standalone UI. |

Target callbacks, key presses, notification buttons, and NUI messages are all untrusted requests. They must pass the same server authorization, state-machine, lease, consent, and idempotency checks as any other transport.

## Cross-cutting audit and evidence contracts

Logging and evidence are adapter capabilities, not domain authorities. The internal audit repository is the source of truth for security and lifecycle records; an external logging/evidence integration is best-effort and must not be required to authorize a booking or economic transition.

| Capability | Detection and normalized contract | Status | Authority | Safe fallback when unavailable |
| --- | --- | --- | --- | --- |
| `audit.external` | Adapter accepts redacted, typed audit events with stable internal event ID and correlation reference; replay is deduplicated. | Optional | Server/core creates event; adapter transports it | Persist to the internal audit repository and bounded server log with redaction. Never drop a required audit event. |
| `evidence.capture` | Adapter stores or references an allowlisted evidence artifact for a server-created incident/event ID, with retention and access result; raw provider handles stay in the adapter. | Optional | Server safety/audit service | Store a minimal internal evidence record (event ID, type, timestamp, status) without media; mark capture unavailable and continue only where policy permits. |
| `audit.internal` | Repository durably records sensitive lifecycle, safety, economic, and recovery events with minimal fields and idempotent event IDs. | Required | Server/core + repository | Fail closed for new safety/economic actions if durable audit is unavailable; report an operational error rather than silently continuing. |

External logging or evidence acknowledgement can be `UNKNOWN` and reconciled, but it never directly transitions Booking, Session, Reservation, or settlement state.

## Capability composition and degradation rules

The registry exposes capability presence and contract version/health, for example:

```text
capabilities = {
  framework = { identity = true, lifecycle = { healthy = true }, job = false,
    duty = { healthy = true, available = true } },
  money = { accounts = true, balance = true, debit = true, credit = true,
    settlement = { query = true }, hold = false, refund = true, idempotency = true },
  phone = { app_register = false, notification_push = false },
  location = { resolve = true, reserve = true, configured = true, motel = false },
  safety = { incident_audit = true, alert = false },
  appearance = { npc_apply = false, npc_spawn = true },
  interaction = { target = false },
  notification = { basic = true }
}
```

This is illustrative vocabulary, not a provider selection API. A core decision is written as a contract predicate, such as:

```text
allow_paid_settlement := money.accounts && money.debit && money.credit && money.settlement.query && money.idempotency
allow_deposit_booking := money.accounts && money.hold && money.deposit.capture && money.deposit.release && money.idempotency
allow_location_activation := location.resolve && location.reserve && location.occupy
allow_worker_action := framework.identity && framework.lifecycle.healthy && ((framework.duty.healthy && framework.duty.available) || (internal_availability.healthy && internal_availability.available))
```

The implementation MUST evaluate capability behavior and configured policy, not provider names. Missing capabilities produce one of three deterministic outcomes: (1) use the documented equivalent fallback, (2) hide/disable the affected optional feature, or (3) fail closed with a typed unavailable error before any side effect. It MUST NOT silently switch accounts, invent a location, bypass consent, settle locally, or broaden participant eligibility.

## Privacy, data minimization, and adapter boundary

- Capability checks return booleans, versions, bounded limits, and typed status; they do not expose provider internals to core.
- UI/public DTOs contain only the actor-authorized booking ID, abstract package/terms, lifecycle state, coarse location reference where needed, and minimal display fields.
- Exact coordinates, account details, provider handles, raw job objects, phone payloads, dispatch identifiers, evidence artifacts, and full NPC profiles remain server/adapter data and are never used as domain identity.
- Logs and audit records use stable internal IDs and redacted provider correlation references. Explicit adult content is invalid at the boundary.
- Adapter failures are observable operational events, but external acknowledgements cannot directly transition Booking, Session, Reservation, or settlement state.

## Verification checklist

- [ ] All eight capability areas are represented: framework; money; phone; housing/motel/venue/vehicle/configured locations; dispatch/safety; appearance/NPC; target; notification.
- [ ] Every capability row states detection/contract semantics, status, authority, and deterministic fallback.
- [ ] Holds/deposits, refund, settlement, and stable-key idempotency are explicit.
- [ ] Required/optional/conditional behavior fails closed where no safe fallback exists.
- [ ] Core examples use capability predicates and contain no provider-name checks.
- [ ] Provider calls (including appearance, logging, and evidence integrations) are confined to adapter boundaries; server remains authoritative.
- [ ] Privacy-minimal data and logical NPC versus physical ped separation are preserved.
