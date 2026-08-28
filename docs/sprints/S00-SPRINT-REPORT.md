# S00 Sprint Report — Specification Freeze

**Date:** 2026-08-28
**Status:** PASS
**Scope:** NS-001, NS-002, NS-003 only

## Completed tasks

- **NS-001 — Domain Invariants:** froze one Booking entity for Worker Mode and Client Mode, the complete canonical `DRAFT -> ... -> SETTLED` lifecycle and all plan-required alternate states, participant combinations, non-graphic consent boundary, atomic/split-leg settlement, logical NPC identity, cancellation-finance policy, and server-owned location reservations.
- **NS-002 — Capability Matrix:** defined framework, healthy/fresh internal availability, money, phone, location, dispatch, appearance, target/notify, logging/audit, and evidence contracts plus deterministic fallbacks. Paid-settlement predicates support atomic transfer or compensatable split legs and require query-by-key only when guaranteed replay cannot resolve uncertainty.
- **NS-003 — Architecture Decision Records:** accepted the exact five ADRs covering unified booking, logical NPC state, server authority, location providers, and OneSync ownership; ADR-004 now locks uncertain external cleanup in durable non-reassignable quarantine.

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
- `.superpowers/sdd/NightShift_IMPLEMENTATION_PLAN/final-fix-report.md`

## Migrations / config / public API / adapters

- Migrations: none; S00 is specification-only.
- Config changes: none.
- Public API changes: none.
- Adapter changes: none; contracts are documented for later S03 work.

## Tests and verification

- Lifecycle validation passed for all 20 closed Booking states, every canonical success state in order, terminal/holding semantics, travel mapping, and sole `COMPLETED -> SETTLED` authority.
- Reservation validation passed for `RELEASE_PENDING`/`QUARANTINED`, `reassignable=false`, lease-expiry safety, and authoritative release/reconciliation before reuse across invariants, capabilities, and ADR-004.
- Payment validation passed for atomic transfer, stable debit/credit/reversal keys, partial-failure compensation, `PENDING`/`UNKNOWN` safety, and a paid-settlement predicate where query is conditional on replay support.
- Cancellation and availability validation passed for separate configuration-driven refunds/deposit release and healthy, fresh, server-owned `internal_availability` with `available=true`.
- ADR validation passed for the exact five required filenames and all four required sections in each file.
- `git diff --check 560e30a..HEAD` passed with no output after the final S00 hardening commit.
- No automated project test runner exists yet; no production resource or runtime code was created in S00.

## Security / recovery / networking / performance

- Security: server authority, untrusted client claims, stable idempotency, privacy-minimal DTOs, and non-graphic consent boundaries are normative.
- Recovery: pending/unknown per-leg settlement, idempotent debit compensation, non-reassignable location quarantine, disconnect/entity-loss reconciliation, and provider loss are specified before implementation.
- Networking: OneSync network ownership is explicitly non-authoritative; state bags are metadata only.
- Performance: logical NPC profiles/travel are separated from bounded physical entities; no runtime workload was introduced.

## Framework notes

QBCore, Qbox, ESX Legacy, and standalone are represented as capabilities. No framework-specific implementation exists until the planned provider sprint.

## Known issues

- GitHub CLI authentication for account `Gnesh97` is currently invalid, so private remote creation and push remain pending outside this local S00 phase.
- Production resource implementation, automated runtime tests, and framework matrices remain intentionally deferred to S01+.

## Deferred items

- S01 Resource Foundation, all FiveM/runtime code, and all later sprints.
- Remote GitHub repository creation after the user re-authenticates `gh`.

## Exit Gate

- [x] Domain invariants complete.
- [x] Capability matrix complete.
- [x] ADR set complete.
- [x] No major domain decision left to an implementation agent.

**S00 Exit Gate: PASS. Stop before S01.**
