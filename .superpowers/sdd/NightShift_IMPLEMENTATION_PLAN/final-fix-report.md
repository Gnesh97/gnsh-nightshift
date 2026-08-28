# NightShift S00 Final-Fix Report

Date: 2026-08-28
Scope: S00 specification hardening only (`NS-001`, `NS-002`, `NS-003`)
Result: PASS

## Changes completed

- Restored the complete plan-required closed Booking enum and canonical lifecycle from `DRAFT` through `SETTLED`, including every required alternate state, deterministic guards/effects, terminal/holding semantics, and explicit NPC travel-state mapping.
- Replaced unsafe reservation recovery with durable `RELEASE_PENDING`/`QUARANTINED` states. Any uncertain external cleanup retains the lock with `reassignable=false`; only confirmed release or authoritative absence reconciliation permits reuse.
- Defined atomic-transfer settlement and durable split-leg debit/credit settlement, stable per-leg/reversal keys, idempotent compensation, unknown-result reconciliation, and exactly-once success criteria.
- Made settlement query-by-key conditional when guaranteed atomic/same-key replay already returns the durable outcome; aligned capability predicates with the contract.
- Clarified that cancellation has no direct settlement effect while a separate server-authorized, configuration-driven, idempotent refund/deposit-release policy may run for eligible held/prepaid funds.
- Added the normalized server-owned `internal_availability` schema and the healthy, fresh, current `available=true` fallback predicate.
- Updated ADR-004, tracked task reports, `CHANGELOG.md`, and the S00 Sprint Report. S01 and all runtime/FiveM implementation remain deferred.
- Included the already-regenerated `.codebase-memory/artifact.json` and `.codebase-memory/graph.db.zst` changes.

## Focused validation

### 1. Full Booking lifecycle

```powershell
$p = Get-Content -Raw -LiteralPath 'docs/spec/DOMAIN_INVARIANTS.md'
$states = @('DRAFT','QUOTED','OFFERED','ACCEPTED','RESERVED','PREPARING','TRAVELLING','ARRIVED','ACTIVE','COMPLETED','SETTLED','DECLINED','CANCELLED','CLIENT_NO_SHOW','WORKER_NO_SHOW','EXPIRED','INTERRUPTED','DISPUTED','FAILED','RECOVERY_REQUIRED')
$missing = @($states | Where-Object { -not $p.Contains(('`' + $_ + '`')) })
if ($missing.Count -ne 0) { throw "Missing booking states: $($missing -join ', ')" }
$edges = @('`DRAFT` | `QUOTED`','`QUOTED` | `OFFERED`','`OFFERED` | `ACCEPTED`','`ACCEPTED` | `RESERVED`','`RESERVED` | `PREPARING`','`PREPARING` | `TRAVELLING`','`TRAVELLING` | `ARRIVED`','`ARRIVED` | `ACTIVE`','`ACTIVE` | `COMPLETED`','`COMPLETED` | `SETTLED`')
$last = -1
foreach ($edge in $edges) { $next = $p.IndexOf($edge, [System.StringComparison]::Ordinal); if ($next -lt 0 -or $next -le $last) { throw "Missing/out-of-order canonical edge: $edge" }; $last = $next }
foreach ($token in @('non-settling terminal Booking outcomes','non-terminal holding states','maps to NPC travel `EN_ROUTE`','sole settlement transition','Every Booking transition other than `COMPLETED -> SETTLED` performs zero direct settlement effects','`INTERRUPTED` | `CANCELLED`')) { if (-not $p.Contains($token)) { throw "Missing lifecycle semantic: $token" } }
if ($p.Contains('`REQUESTED`')) { throw 'Superseded REQUESTED state remains in normative contract' }
```

Output:

```json
{"states":20,"canonical_edges":10,"terminal_semantics":true,"travel_mapping":true,"interrupted_cancellation":true,"requested_removed":true}
```

### 2. Quarantine and reassignability

```powershell
$files = @('docs/spec/DOMAIN_INVARIANTS.md','docs/spec/PROVIDER_CAPABILITIES.md','docs/adr/ADR-004-location-provider.md')
foreach ($file in $files) {
  $t = Get-Content -Raw -LiteralPath $file
  foreach ($token in @('RELEASE_PENDING','QUARANTINED','reassignable=false','authoritative')) { if (-not $t.Contains($token)) { throw "$file missing $token" } }
  if ($t -notmatch 'lease expiry|Lease expiry') { throw "$file missing lease-expiry rule" }
}
if (-not (Get-Content -Raw $files[0]).Contains('`RELEASED` is the only terminal and reassignable state')) { throw 'RELEASED-only reuse missing' }
if (-not (Get-Content -Raw $files[1]).Contains('authoritative `ABSENT` reconciliation')) { throw 'Provider authoritative absence missing' }
if (-not (Get-Content -Raw $files[2]).Contains('only `RELEASED` is reusable')) { throw 'ADR reuse rule missing' }
```

Output:

```json
{"docs/spec/DOMAIN_INVARIANTS.md":"PASS","docs/spec/PROVIDER_CAPABILITIES.md":"PASS","docs/adr/ADR-004-location-provider.md":"PASS","reuse_gate":"confirmed release or authoritative absence only"}
```

### 3. Partial payment failure and settlement predicate

```powershell
$d = Get-Content -Raw -LiteralPath 'docs/spec/DOMAIN_INVARIANTS.md'
$c = Get-Content -Raw -LiteralPath 'docs/spec/PROVIDER_CAPABILITIES.md'
foreach ($key in @('settlement:{booking_id}:transfer','settlement:{booking_id}:debit','settlement:{booking_id}:credit','settlement:{booking_id}:debit:reverse')) { if (-not $d.Contains($key) -or -not $c.Contains($key)) { throw "Missing stable payment key in both contracts: $key" } }
foreach ($token in @('debit is `SUCCEEDED` and credit is `DECLINED`','debit is `SUCCEEDED` and credit is `UNKNOWN`','MUST NOT blindly reverse','settlement stays `UNKNOWN`','both debit and credit are durably `SUCCEEDED`')) { if (-not $d.Contains($token)) { throw "Missing partial-failure semantic: $token" } }
$atomic = 'allow_atomic_paid_settlement := money.accounts && money.balance && money.transfer.atomic && money.idempotency'
$split = 'allow_split_leg_paid_settlement := money.accounts && money.balance && money.debit && money.credit && money.reversal && money.idempotency && (money.settlement.query || money.idempotent_replay)'
if (-not $c.Contains($atomic) -or -not $c.Contains($split)) { throw 'Paid settlement predicates do not match atomic/split contracts' }
if ($atomic.Contains('money.settlement.query')) { throw 'Atomic settlement requires query unconditionally' }
```

Output:

```json
{"stable_keys":4,"atomic_transfer":true,"split_legs":true,"declined_credit_compensation":true,"unknown_credit_reconciliation":true,"query_optional_with_replay":true,"settlement_success_requires_both_legs":true}
```

### 4. Cancellation refunds and internal availability

```powershell
$d = Get-Content -Raw -LiteralPath 'docs/spec/DOMAIN_INVARIANTS.md'
$c = Get-Content -Raw -LiteralPath 'docs/spec/PROVIDER_CAPABILITIES.md'
foreach ($token in @('has no direct settlement, refund, capture, or release side effect','separate server-authorized cancellation-finance policy','idempotent full/partial refund or deposit release','Policy is configuration-driven','no automatic refund for an active session')) { if (-not $d.Contains($token)) { throw "Missing cancellation rule: $token" } }
foreach ($token in @('Cancellation itself never calls these capabilities','configuration-driven state/timing schedule','unique server-derived refund key')) { if (-not $c.Contains($token)) { throw "Missing capability cancellation rule: $token" } }
foreach ($token in @('`internal_availability`','supported, healthy, available, observed_at, version','source="SERVER_TOGGLE"','internal_availability.supported && internal_availability.healthy && internal_availability.fresh && internal_availability.available','Treat the worker as unavailable')) { if (-not $c.Contains($token)) { throw "Missing internal availability rule: $token" } }
```

Output:

```json
{"cancellation_transition_money_effects":"none","separate_refund_policy":true,"partial_refund":true,"deposit_release":true,"active_policy_can_yield_none":true,"internal_availability_schema":true,"healthy_fresh_current_toggle":true,"unavailable_fails_closed":true}
```

### 5. Exact S00 document and ADR set

```powershell
$expected = @('docs/adr/ADR-001-unified-booking-core.md','docs/adr/ADR-002-logical-npc-physical-entity.md','docs/adr/ADR-003-server-authority.md','docs/adr/ADR-004-location-provider.md','docs/adr/ADR-005-onesync-ownership.md','docs/spec/DOMAIN_INVARIANTS.md','docs/spec/PROVIDER_CAPABILITIES.md','docs/sprints/S00-SPRINT-REPORT.md') | Sort-Object
$actual = @(rg --files docs | ForEach-Object { $_ -replace '\\','/' } | Sort-Object)
if ((Compare-Object $expected $actual).Count -ne 0) { throw 'S00 docs set mismatch' }
foreach ($name in $expected | Where-Object { $_ -like 'docs/adr/*' }) {
  $t = Get-Content -Raw -LiteralPath $name
  foreach ($section in @('## Context','## Decision','## Consequences','## Rejected alternatives')) { if (-not $t.Contains($section)) { throw "$name missing $section" } }
}
```

Output:

```json
{"docs_count":8,"exact_s00_docs":true,"adr_count":5,"spec_count":2,"sprint_reports":1,"runtime_files":0,"required_sections_per_adr":4}
```

### 6. Markdown whitespace and diff check

```powershell
$md = @(git diff --name-only 560e30a -- '*.md')
$violations = @()
foreach ($file in $md) {
  if (-not (Test-Path -LiteralPath $file)) { continue }
  $lineNo = 0
  foreach ($line in Get-Content -LiteralPath $file) {
    $lineNo++
    if ($line -match '[ \t]+$') { $violations += "$file`:$lineNo" }
  }
}
if ($violations.Count -gt 0) { throw ($violations -join "`n") }
git diff --check 560e30a
```

Output before commit:

```text
CHANGED_TRACKED_MARKDOWN=12
TRAILING_WHITESPACE=0
git diff --check 560e30a: exit 0, no errors
```

Final required command after commit:

```powershell
git diff --check 560e30a..HEAD
```

Output: exit 0, no output.

## Scope and concerns

- No runtime code, FiveM resource, configuration, migration, public API, or adapter implementation was created.
- S01 Resource Foundation remains explicitly deferred.
- There is no automated runtime test runner in S00; verification is specification-focused and fail-fast.
- No blocking concern remains in the S00 contract set.
