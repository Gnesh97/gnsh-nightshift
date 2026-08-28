# Task NS-001 Report

## Status

Complete. Implemented the S00 domain-invariant specification only; no production FiveM resource or S01 work was added.

## Deliverables

- `docs/spec/DOMAIN_INVARIANTS.md`

The document covers all seven required topics, with definitions, invariant IDs, preconditions, postconditions, invalid examples, and enforcement ownership. It explicitly freezes the two participant combinations, server authority/idempotency boundaries, abstract consent/session states, and canonical single settlement transition.

## Validation

Focused document check passed:

```powershell
$p = Get-Content -Raw docs/spec/DOMAIN_INVARIANTS.md
foreach ($id in @('INV-001','INV-002','INV-003','INV-004','INV-005','INV-006','INV-007')) { if ($p -notmatch [regex]::Escape($id)) { throw "Missing $id" } }
foreach ($topic in @('Worker Mode','player-player','Adult-themed','exactly once','Logical NPC profile','allowlist','Location reservation')) { if ($p -notmatch [regex]::Escape($topic)) { throw "Missing topic: $topic" } }
if ($p -notmatch 'PLAYER` worker.*NPC` client' -or $p -notmatch 'NPC` worker.*PLAYER` client') { throw 'Missing allowlisted combinations' }
if ($p -notmatch 'exactly once' -or $p -notmatch 'canonical transition') { throw 'Missing single-settlement rule' }
if ($p -notmatch 'server-authoritative') { throw 'Missing server authority' }
```

The command completed successfully. No automated test framework exists yet.

## Self-review and concerns

Self-review found no implementation code, product expansion, player-player allowance, NPC-NPC allowance, or alternate settlement path. The source development-plan file referenced by the brief is outside this repository; the document therefore uses only the exact requirements in the task brief and existing S00 ledger context. Later tasks should treat the vocabulary and transitions here as stable contracts.

## Review-fix append

Expanded `docs/spec/DOMAIN_INVARIANTS.md` to define closed Booking, Session, and Reservation enums with explicit transition tables, terminal semantics, cancellation/expiry behavior, stable per-booking settlement keys, durable `PENDING`/`UNKNOWN` recovery, neutral capability ports, and server-owned price/assignment/reputation/refund/reversal effects. Updated the validation to check each invariant ID independently and anchor all seven required topics.

Focused validation command:

```powershell
$p = Get-Content -Raw docs/spec/DOMAIN_INVARIANTS.md
foreach ($id in @('INV-001','INV-002','INV-003','INV-004','INV-005','INV-006','INV-007')) { if ($p -notmatch [regex]::Escape($id)) { throw "Missing $id" } }
foreach ($topic in @('Worker Mode','player-player','Adult-themed','exactly once','Logical NPC profile','allowlist','Location reservation')) { if ($p -notmatch [regex]::Escape($topic)) { throw "Missing topic: $topic" } }
if ($p -notmatch 'PLAYER.*worker.*NPC.*client' -or $p -notmatch 'NPC.*worker.*PLAYER.*client') { throw 'Missing allowlisted combinations' }
if ($p -notmatch 'canonical transition' -or $p -notmatch 'server-authoritative') { throw 'Missing settlement/authority boundary' }
Write-Output 'PASS: each invariant ID, all seven topics, participant pairs, settlement, and authority validated'
```

Output: `PASS: each invariant ID, all seven topics, participant pairs, settlement, and authority validated`.

## Final lifecycle and recovery hardening

The final S00 review restored the development plan's complete closed Booking enum and canonical path (`DRAFT`, `QUOTED`, `OFFERED`, `ACCEPTED`, `RESERVED`, `PREPARING`, `TRAVELLING`, `ARRIVED`, `ACTIVE`, `COMPLETED`, `SETTLED`) plus every required alternate state. Deterministic guards/effects, terminal versus holding semantics, NPC travel mapping, durable location `RELEASE_PENDING`/`QUARANTINED`, atomic or split-leg settlement, and separate cancellation-finance policy are now explicit.

Covering validation checks all 20 states, canonical order, the sole `COMPLETED -> SETTLED` authority, stable debit/credit/reversal keys, and `reassignable=false` until confirmed release/reconciliation. The full command and output are recorded in `final-fix-report.md`.

## Final settlement contradiction fix

`PENDING`/`UNKNOWN` remain pre-transition reconciliation statuses while the Booking is `COMPLETED`; only confirmed atomic-transfer success or confirmed success of both durable debit/credit legs permits `COMPLETED -> SETTLED`. A successful debit followed by declined credit requires same-key idempotent reversal. An unknown credit is reconciled before reversal so compensation cannot mint or duplicate funds. Query-by-key is conditional when guaranteed same-key replay already returns the durable result.
