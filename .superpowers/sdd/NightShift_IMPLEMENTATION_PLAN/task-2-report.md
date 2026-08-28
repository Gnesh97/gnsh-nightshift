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
  atomic_settlement=($t.Contains('allow_atomic_paid_settlement := money.accounts && money.balance && money.transfer.atomic && money.idempotency'))
  split_leg_compensation=($t.Contains('money.debit && money.credit && money.reversal') -and $t.Contains('settlement:{booking_id}:debit:reverse'))
  query_is_conditional=($t.Contains('(money.settlement.query || money.idempotent_replay)') -and -not $t.Contains('allow_atomic_paid_settlement := money.accounts && money.balance && money.transfer.atomic && money.settlement.query'))
  deposit_requires_accounts=($t.Contains('money.accounts && money.hold && money.deposit.capture && money.deposit.release'))
  availability_is_current=($t.Contains('internal_availability.supported && internal_availability.healthy && internal_availability.fresh && internal_availability.available'))
  deposit_not_overstrict=($t.Contains('allow_deposit_booking := money.accounts && money.hold && money.deposit.capture && money.deposit.release && money.idempotency') -and -not $t.Contains('allow_deposit_booking := money.accounts && money.hold && money.deposit.capture && money.deposit.release && money.settlement.query'))
  cleanup_quarantine=($t.Contains('QUARANTINED') -and $t.Contains('reassignable=false') -and $t.Contains('authoritative `ABSENT` reconciliation'))
  cancellation_finance=($t.Contains('configuration-driven state/timing schedule') -and $t.Contains('Cancellation itself never calls these capabilities'))
  adapter_boundary_covers_appearance_logging_evidence=($t.Contains('appearance, logging, or evidence') -or $t.Contains('appearance, logging, and evidence'))
}
```

Result: every listed check is `True`; table headers remain 9 including cross-cutting audit/evidence.

## Self-review

- Confirmed all eight requested areas have explicit headings and matrix rows.
- Confirmed every matrix row includes all five required columns.
- Confirmed paid operations fail closed or remain pending/unknown when idempotent provider behavior is unavailable.
- Confirmed paid settlement allows either guaranteed atomic transfer or durable debit/credit legs with reversal; query-by-key is conditional when same-key replay already resolves uncertainty.
- Confirmed worker eligibility requires a healthy, fresh, current `available=true` duty or server-owned internal-availability observation.
- Confirmed unavailable or uncertain external location cleanup persists `QUARANTINED` with `reassignable=false` until confirmed release or authoritative absence reconciliation.
- Confirmed cancellation has no direct settlement effect while the separate configuration-driven server policy may idempotently release/refund eligible deposits or prepayments.
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

Addressed the review findings: availability now requires a healthy, fresh current observation; settlement permits an atomic mode or compensatable split legs; deposit gates include accounts; uncertain cleanup is durably quarantined until authoritative release/reconciliation; and appearance, logging, and evidence remain adapter-only with internal-audit fallback.

Re-run output for the strengthened validation check:

`{"file":true,"areas":true,"table_headers":true,"atomic_settlement":true,"split_leg_compensation":true,"query_is_conditional":true,"deposit_requires_accounts":true,"availability_is_current":true,"cleanup_quarantine":true,"cancellation_finance":true}`

## Scoped re-review follow-up

Final S00 hardening adds `fresh` and a normalized `internal_availability` schema; makes query-by-key optional when guaranteed atomic/same-key replay resolves uncertainty; freezes stable per-leg/reversal keys; and requires external allocation `RELEASE_PENDING`/`QUARANTINED` to retain `reassignable=false` until proof of release.

Re-run output:

See `final-fix-report.md` for the final focused commands and outputs.
