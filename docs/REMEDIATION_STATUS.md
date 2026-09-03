# Remediation status

This document records the evidence available in the current checkout for
`docs/NIGHTSHIFT_REMEDIATION_GUIDE.md`. The guide is an implementation
contract; `NightShift_DEVELOPMENT_PLAN.md` and `NightShift_IMPLEMENTATION_PLAN.md`
remain product requirements, not runtime instructions.

## Local evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Lua contracts | PASS | `lua tests/run.lua` — exit code 0; the event-bus failure-isolation case is intentionally exercised and captured by a silent test sink |
| Lua syntax | PASS | `luac -p` over `client/`, `server/`, `shared/`, `config/`, `tests/` — exit code 0 |
| Python quality gates | PASS | `python -m unittest discover -s tests -p '*_test.py' -v` — 12 tests, exit code 0 |
| NUI lint | PASS | `npm run lint -- --deny-warnings` from `web/` — exit code 0 |
| NUI build | PASS | `npm run build` from `web/` — exit code 0 |
| Locale parity | PASS | `scripts/validate_locales.py` covered by the Python suite |
| Secret scan | PASS | `scripts/secret_scan.py .` (mandatory deterministic scanner) |
| Measured modified-module coverage | BLOCKED | No local Lua coverage runtime/report is installed; CI artifact is required. |

## Remediation gates

| ID | Current result | Notes |
| --- | --- | --- |
| REM-001 | Contract PASS; live BLOCKED | Readiness is fail-closed for production/persistent dependencies. |
| REM-002/003 | Contract PASS; live BLOCKED | Pool/model/coordinator contracts pass; FiveM entity evidence is required. |
| REM-004 | Local PASS; live BLOCKED | NUI build and mock contracts pass; mock is not live vertical-slice evidence. |
| REM-005/006 | Contract PASS; settlement recovery BLOCKED; live BLOCKED | Interruption cleanup and disconnect/resource-stop cleanup are covered locally; completed rows still require an explicit provider/actor settlement resolver. |
| REM-007/008 | Contract/static PASS; live BLOCKED | Token/read authorization is server-bound; live abuse/reconnect evidence is pending. |
| REM-009 | BLOCKED — operator-required | No QBCore/Qbox/ESX/Standalone FXServer + oxmysql captures are available here. |
| REM-010 | BLOCKED — CI/coverage artifact required | Local syntax/lint/locale/secret checks pass; measured coverage is not claimed without a report. |
| REM-011 | BLOCKED — operator-required | No OneSync, load, owner migration, or restart capture is available. |
| REM-012 | BLOCKED — operator-required | S31 cannot be marked PASS without the live evidence below. |

## S31 live checklist

All live-dependent rows remain `BLOCKED` until an operator records the guide's
scenario fields (provider/version, FXServer artifact, OneSync mode, database,
flags, actions, logs, and cleanup verification): Worker Mode; Client Mode
`COME_TO_ME`, `PICKUP`, and `MEET_THERE`; authoritative pricing/location/
arrival/completion; race and duplicate payment tests; active-booking restart;
disconnect stale-lock cleanup; privacy and token replay/concurrency; four
framework/provider matrices; fresh install/upgrade; locale/CI/coverage gates;
and release-artifact smoke testing.

No browser mock result or local contract result is treated as live `PASS`.

## Recovery and retry notes

Recovery cleanup is deliberately fail-closed: if any authoritative release
dependency fails, the result is `pending` with `recovered=false` so the startup
gate can retry it. `COMPLETED` bookings are not guessed into a settled state;
they remain pending unless a provider-backed, actor-bound settlement resolver
is explicitly injected and returns `approved=true` with distinct payer/payee
sources. The resolver path is idempotent through the existing settlement
service; no source fallback or unverified money effect is used during restart
recovery.

The NUI lifecycle refreshes its actor-bound one-time action token after a
service/database error. A retry therefore uses a new token while the server
still remains authoritative for the booking transition. For entity-backed
retries, the server also verifies the booking, travel key, profile key, and
generation token against the NPC registry before issuing the replacement.
`NS-275` covers the callback boundary, mismatched-generation rejection, and
service-error token refresh/retry contract; live browser/FXServer evidence is
still required for S31.
