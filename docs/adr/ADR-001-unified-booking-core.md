# ADR-001: Unified Booking Core

Status: Accepted (S00 specification freeze)
Date: 2026-08-28

## Context

NightShift supports Worker Mode, where a player is the worker and an NPC is the client, and Client Mode, where an NPC is the worker and a player is the client. Separate mode-specific aggregates or workflows would allow lifecycle, reservation, consent, and settlement rules to diverge. The normative booking and participant rules are defined in [NightShift Domain Invariants](../spec/DOMAIN_INVARIANTS.md), especially `INV-001`, `INV-003`, and `INV-004`.

## Decision

Worker Mode and Client Mode use one Unified Booking Core: the same Booking entity, identifier space, closed state machine, reservation association, settlement rules, and persistence contract. Participant roles and normalized participant types determine the mode; mode does not select a separate aggregate or lifecycle.

All booking requests enter the same domain validation and transition rules. A caller-provided mode is an untrusted claim and must agree with the server-normalized participant pair. Mode-specific presentation may differ, but it cannot create a second booking schema, transition path, or settlement authority.

## Consequences

- Lifecycle and settlement invariants apply identically to both modes.
- Persistence, audit, reservation, and recovery logic operate on one stable booking identity.
- New mode-specific behavior must remain a view or policy over the common core and cannot bypass participant, consent, or settlement rules.
- Unsupported participant combinations remain rejected rather than being routed to an alternate mode implementation.

## Rejected alternatives

- Separate Worker Booking and Client Booking aggregates were rejected because their state machines and settlement behavior could drift.
- A generic mode flag that lets clients choose the workflow was rejected because participant identity and role normalization are server-owned.
- Shared storage with separate lifecycle services was rejected because it still creates multiple authorities for one domain concept.
