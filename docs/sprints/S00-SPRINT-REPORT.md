# S00 Sprint Report — Specification Freeze

**Date:** 2026-08-28  
**Status:** PASS  
**Scope:** NS-001, NS-002, NS-003 only

## Completed tasks

- **NS-001 — Domain Invariants:** froze one Booking entity for Worker Mode and Client Mode, valid participant combinations, non-graphic consent boundary, canonical settlement, logical NPC identity, and server-owned location reservations.
- **NS-002 — Capability Matrix:** defined framework, money, phone, location, dispatch, appearance, target/notify, logging/audit, and evidence capability contracts plus deterministic fallbacks. Core decisions remain provider-name independent.
- **NS-003 — Architecture Decision Records:** accepted five ADRs covering unified booking, logical NPC state, server authority, location providers, and OneSync ownership.

## Changed files

- `CHANGELOG.md`
- `docs/spec/DOMAIN_INVARIANTS.md`
- `docs/spec/PROVIDER_CAPABILITIES.md`
- `docs/adr/ADR-001-unified-booking-core.md`
- `docs/adr/ADR-002-logical-npc-physical-entity.md`
- `docs/adr/ADR-003-server-authority.md`
- `docs/adr/ADR-004-location-provider.md`
- `docs/adr/ADR-005-onesync-ownership.md`
- `.codebase-memory/artifact.json`
- `.codebase-memory/graph.db.zst`

## Migrations / config / public API / adapters

- Migrations: none; S00 is specification-only.
- Config changes: none.
- Public API changes: none.
- Adapter changes: none; contracts are documented for later S03 work.

## Tests and verification

- NS-001 focused validation: each `INV-001`–`INV-007`, all seven required topics, participant pairs, settlement, and authority checks passed.
- NS-002 focused validation: all capability areas and safety predicates passed, including current availability, economic debit/credit/account requirements, deposit recovery, quarantine, normalized settlement keys, and adapter boundaries.
- NS-003 focused validation: exact five ADRs, required sections, and required decisions passed.
- `git diff --check` passed for implementation and review fixes.
- No automated project test runner exists yet; no production resource or runtime code was created in S00.

## Security / recovery / networking / performance

- Security: server authority, untrusted client claims, stable idempotency, privacy-minimal DTOs, and non-graphic consent boundaries are normative.
- Recovery: pending/unknown settlement, reservation expiry/recovery, disconnect/entity-loss reconciliation, and provider loss are specified before implementation.
- Networking: OneSync network ownership is explicitly non-authoritative; state bags are metadata only.
- Performance: logical NPC profiles/travel are separated from bounded physical entities; no runtime workload was introduced.

## Framework notes

QBCore, Qbox, ESX Legacy, and standalone are represented as capabilities. No framework-specific implementation exists until the planned provider sprint.

## Known issues

- GitHub CLI authentication for account `Gnesh97` is currently invalid, so private remote creation and push remain pending outside this local S00 phase.
- Production resource implementation, automated runtime tests, and framework matrices are intentionally deferred to S01+.

## Deferred items

- S01 Resource Foundation and all later sprints.
- Remote GitHub repository creation after the user re-authenticates `gh`.

## Exit Gate

- [x] Domain invariants complete.
- [x] Capability matrix complete.
- [x] ADR set complete.
- [x] No major domain decision left to an implementation agent.

**S00 Exit Gate: PASS. Stop before S01.**
