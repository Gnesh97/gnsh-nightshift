# NS-002 Task Report — Capability Matrix

## Status

PASS — specification-only deliverable complete.

## Scope

Implemented only NS-002 from S00. No FiveM resource, runtime code, configuration, database schema, S01 work, or `CHANGELOG` changes were made.

## Changed files

- `docs/spec/PROVIDER_CAPABILITIES.md` — added the normative capability-first provider matrix.
- `.superpowers/sdd/NightShift_IMPLEMENTATION_PLAN/task-2-report.md` — this report.

## Coverage

The matrix explicitly covers framework identity/lifecycle/job/duty, money and account operations (including holds, deposits, capture/release, settlement, refunds, and idempotency), phone app/notifications, housing/motel/venue/vehicle/configured locations, dispatch/safety, appearance/NPC presentation, target interaction, and notification interaction.

Each capability row states detection/normalized contract semantics, required/optional/conditional status, authority boundary, and deterministic fallback. The document also records privacy-minimal DTO rules, logical NPC versus physical ped separation, adapter boundaries, provider outage/restart behavior, and capability-predicate examples that do not require provider-name checks.

## Validation

Focused document validation command/check:

```powershell
$f='docs/spec/PROVIDER_CAPABILITIES.md'
$t=Get-Content -Raw $f
$areas=@('## 1. Framework','## 2. Money','## 3. Phone','## 4. Housing','## 5. Dispatch','## 6. Appearance','## 7. Target','## 8. Notification')
$missing=$areas | Where-Object { -not $t.Contains($_) }
$tables=([regex]::Matches($t,'\| Capability \| Detection and normalized contract \| Status \| Authority \| Safe fallback when unavailable \|')).Count
[ordered]@{
  file=(Test-Path -LiteralPath $f)
  areas=($missing.Count -eq 0)
  table_headers=($tables -eq 9)
  no_fiveM_code=(-not $t.Contains('fxmanifest.lua'))
  settlement_requires_both_legs=($t.Contains('money.accounts && money.debit && money.credit && money.settlement.query && money.idempotency'))
  deposit_requires_accounts=($t.Contains('money.accounts && money.hold && money.deposit.capture && money.deposit.release'))
  duty_requires_current_availability=($t.Contains('framework.duty.healthy && framework.duty.available') -and $t.Contains('internal_availability.healthy && internal_availability.available'))
  settlement_key_normalized=($t.Contains('money.settlement.query') -and $t.Contains('settlement = { query = true }'))
  deposit_not_overstrict=($t.Contains('allow_deposit_booking := money.accounts && money.hold && money.deposit.capture && money.deposit.release && money.idempotency') -and -not $t.Contains('allow_deposit_booking := money.accounts && money.hold && money.deposit.capture && money.deposit.release && money.settlement.query'))
  cleanup_quarantine=($t.Contains('quarantine the location allocation') -and $t.Contains('block reassignment until release succeeds'))
  adapter_boundary_covers_appearance_logging_evidence=($t.Contains('appearance, logging, or evidence') -or $t.Contains('appearance, logging, and evidence'))
}
```

Result: `file=True`, `areas=True`, `table_headers=True (9 including cross-cutting audit/evidence)`, `no_fiveM_code=True`, `settlement_requires_both_legs=True`, `deposit_requires_accounts=True`, `duty_requires_current_availability=True`, `settlement_key_normalized=True`, `deposit_not_overstrict=True`, `cleanup_quarantine=True`, `adapter_boundary_covers_appearance_logging_evidence=True`.

## Self-review

- Confirmed all eight requested areas have explicit headings and matrix rows.
- Confirmed every matrix row includes all five required columns.
- Confirmed paid operations fail closed or remain pending/unknown when idempotent provider behavior is unavailable.
- Confirmed settlement requires configured accounts, both debit and credit legs, query/reconciliation, and idempotency; deposit gates also require accounts.
- Confirmed worker duty requires a healthy current `available=true` observation rather than capability presence alone.
- Confirmed unavailable external location cleanup quarantines/retains a non-overlapping lease until authoritative release or reconciliation, preventing unsafe reassignment.
- Confirmed server/core authority is retained for lifecycle, consent, reservation, settlement, refund, and safety state.
- Confirmed optional provider loss cannot silently invent state or broaden feature behavior.
- Confirmed no provider-name branch is used in the core decision examples.
- Confirmed appearance, logging, and evidence integrations remain adapter-only with internal audit fallback.
- Confirmed no explicit adult content or unnecessary private/provider data is introduced.

## Concerns / deferred items

No blocking concerns. Concrete adapter schemas, implementation health checks, and automated tests are intentionally deferred to later sprints as required by the task brief.

## Exit gate

PASS — NS-002 capability matrix complete; STOP before S01.

## Review follow-up

Addressed all five review findings: duty now requires a healthy current `available=true` observation; settlement requires configured accounts plus independent debit and credit legs, query/reconciliation, and idempotency; deposit gates include accounts; failed external location cleanup quarantines/retains a non-overlapping lease until authoritative release or reconciliation; and appearance, logging, and evidence are explicitly adapter-only with internal-audit fallback.

Re-run output for the strengthened validation check:

`{"file":true,"areas":true,"table_headers":true,"no_fiveM_code":true,"settlement_requires_both_legs":true,"deposit_requires_accounts":true,"duty_requires_current_availability":true,"cleanup_quarantine":true,"adapter_boundary_covers_appearance_logging_evidence":true}`

## Scoped re-review follow-up

Addressed the subsequent four findings: internal availability now requires both healthy and `available=true`; failed cleanup explicitly clears only into a quarantined/non-reassignable state; the sample and predicates use the normalized `money.settlement.query` key; and deposit gating relies on account-scoped hold/capture/release plus idempotency/query-by-key without requiring settlement-query support intended for debit/credit uncertainty.

Re-run output:

`{"file":true,"areas":true,"table_headers":true,"no_fiveM_code":true,"settlement_requires_both_legs":true,"deposit_requires_accounts":true,"duty_requires_current_availability":true,"settlement_key_normalized":true,"deposit_not_overstrict":true,"cleanup_quarantine":true,"adapter_boundary_covers_appearance_logging_evidence":true}`
