# ADR-002: Logical NPC Profile and Physical Entity Separation

Status: Accepted (S00 specification freeze)
Date: 2026-08-28

## Context

A logical NPC must remain identifiable across distance, despawn, replacement, reconnect, and provider restart. A physical ped is an ephemeral runtime representation whose handle, network ID, validity, and owner can change. Treating the ped as the NPC would make booking identity and travel progress depend on transient world state. The governing rules are `INV-005` in [NightShift Domain Invariants](../spec/DOMAIN_INVARIANTS.md) and the appearance capabilities in [Provider Capabilities](../spec/PROVIDER_CAPABILITIES.md).

## Decision

The logical NPC profile and logical travel state are domain data separate from an optional physical ped entity. Bookings reference the logical profile ID; a runtime ped may be associated only as a fresh, server-authorized physical representation and is never the NPC's sole identity.

Distant NPC travel is recorded logically under server authority. It does not require a continuously spawned ped or physical world traversal. A physical ped may represent the logical NPC when a valid provider capability and current association are available, but spawning, despawning, replacing, or losing that ped does not create, delete, complete, or reassign the logical journey or booking. Arrival remains a server-authorized conclusion based on canonical logical state and trusted provider observations, not a client ped claim.

## Consequences

- NPC profiles and their booking/history references survive ped loss and replacement.
- Distant NPCs can progress through logical travel without persistent network entities.
- Physical association data must be freshness-aware and may be discarded independently of logical state.
- Appearance or spawning failure degrades to logical-only state or postpones physical interaction without changing participant roles, consent, completion, settlement, or reputation.

## Rejected alternatives

- Using a ped handle or network ID as the NPC identity was rejected because runtime identities are transient and client claims are untrusted.
- Keeping every travelling NPC physically spawned was rejected because physical presence is not required for authoritative distant travel.
- Recreating or completing logical travel from a ped spawn/despawn event was rejected because provider/runtime events are observations, not domain transitions.
