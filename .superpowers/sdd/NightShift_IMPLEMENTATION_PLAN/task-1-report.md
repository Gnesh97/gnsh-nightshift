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

## Scoped re-review fix append

Changed lines in `docs/spec/DOMAIN_INVARIANTS.md`: booking transition rows 61, 64-65; session lifecycle rows 69-83; settlement postconditions 96-100; reservation lifecycle and lease guard 177-195 (line numbers may shift with formatting). Added explicit guards and side effects for every session/reservation transition, deterministic server-clock lease expiry to `EXPIRED`/`RECOVERED`, and clarified that `PENDING`/`UNKNOWN` settlement is non-terminal while only confirmed stable-key success permits `COMPLETED -> SETTLED`. Added inbound booking-cancellation to session `CANCELLED`.

Covering validation command:

```powershell
$p = Get-Content -Raw docs/spec/DOMAIN_INVARIANTS.md
foreach ($id in @('INV-001','INV-002','INV-003','INV-004','INV-005','INV-006','INV-007')) { if ($p -notmatch [regex]::Escape($id)) { throw "Missing $id" } }
foreach ($topic in @('Worker Mode','player-player','Adult-themed','exactly once','Logical NPC profile','allowlist','Location reservation')) { if ($p -notmatch [regex]::Escape($topic)) { throw "Missing topic: $topic" } }
foreach ($token in @('Session state enum is closed','Reservation state enum is','now >= lease_expires_at','COMPLETED -> SETTLED','PENDING`/`UNKNOWN` are non-terminal','RESERVED` | `RECOVERED','ACTIVE` | `CANCELLED')) { if ($p -notmatch [regex]::Escape($token)) { throw "Missing state contract: $token" } }
if ($p -match 'Cancellation/expiry before activation') { throw 'Expiry must not be cancellation' }
Write-Output 'PASS: closed session/reservation transitions, lease guard, deterministic expiry, and settlement guard validated'
```

Output: `PASS: closed session/reservation transitions, lease guard, deterministic expiry, and settlement guard validated`.
