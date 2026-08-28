# ADR-005: OneSync Ownership Is Not Business Authority

Status: Accepted (S00 specification freeze)
Date: 2026-08-28

## Context

OneSync network ownership is a runtime concern used to simulate and replicate entities. Ownership may migrate as players move, disconnect, or streaming conditions change. Business decisions tied to the current network owner would therefore be unstable and could give a client control over booking, identity, arrival, completion, or economic state. This boundary follows the server authority and logical NPC rules in [NightShift Domain Invariants](../spec/DOMAIN_INVARIANTS.md) and the provider/runtime authority vocabulary in [Provider Capabilities](../spec/PROVIDER_CAPABILITIES.md).

## Decision

OneSync network ownership may migrate and is never business authority. The current network owner may perform permitted runtime simulation, but cannot authorize or determine lifecycle transitions, NPC identity, assignment, arrival, completion, consent, reservation ownership, payment, refund, reputation, or audit outcomes.

State bags are metadata only. They may replicate bounded, non-sensitive presentation or association metadata written under server policy, but they are not canonical storage, proof of authority, or a transition command. Client-written or observed state-bag values are untrusted.

Canonical business state is server/DB-owned. Server services validate client and runtime observations against that state and the applicable domain guards. Entity ownership migration, entity loss, or state-bag loss cannot directly mutate canonical Booking, Session, NPC profile, Reservation, settlement, or audit state. Such a loss may trigger guarded server reconciliation, which may remove a stale physical association, recover a reservation under `INV-006`, and record the required internal audit event while preserving server/DB authority.

## Consequences

- Ownership migration does not transfer business permissions or corrupt canonical state.
- Runtime entities and replicated metadata can be recreated without reconstructing domain state from clients.
- Network-owner and state-bag observations require the same server validation as other client input.
- Sensitive or authoritative domain data remains outside replicated metadata.

## Rejected alternatives

- Treating the current network owner as authoritative for arrival or completion was rejected because ownership is transient and client-controlled simulation is not trusted.
- Using state bags as the source of truth was rejected because replicated metadata is not a durable, authoritative transaction store.
- Rebuilding canonical booking or NPC state from an entity after server restart was rejected because runtime representation cannot replace server/DB records.
