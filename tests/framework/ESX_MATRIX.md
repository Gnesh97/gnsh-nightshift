# S29 / NS-292 — ESX Legacy Release Matrix

This matrix covers ESX Legacy xPlayer shape and its duty model. ESX does not
expose a universal server duty capability in this adapter, so NightShift uses
explicit internal availability state when the job payload has no duty field.

## Automated contract gate

Run:

~~~text
lua tests/run.lua
~~~

The parity contract checks getPlayerFromId, getIdentifier, getName, getJob,
esx:setJob, the internal duty event, and a playerDropped callback after the
xPlayer has disappeared. A normalized snapshot is delivered with loaded=false,
then released.

## Live matrix

| ID | Flow | Expected evidence | Status |
| --- | --- | --- | --- |
| EX-01 | player load/logout | identifier/name/job normalize; playerDropped releases the source snapshot | Automated contract PASS; live BLOCKED — operator evidence required |
| EX-02 | job update | esx:setJob refreshes name and grade without exposing xPlayer | Automated contract PASS; live BLOCKED — operator evidence required |
| EX-03 | money/accounts | cash and bank account get/remove/add map to ESX account methods | Automated contract PASS; live BLOCKED — operator evidence required |
| EX-04 | duty fallback | explicit internal availability toggles on-duty when ESX has no duty field | Automated contract PASS; live BLOCKED — operator evidence required |
| EX-05 | Worker Mode | S11 vertical slice reaches SETTLED once using the ESX adapters | Existing S11 contracts PASS; live BLOCKED — operator evidence required |
| EX-06 | Client modes | all three meeting modes retain unified booking/session/settlement behavior | S13-S15 contracts PASS; live BLOCKED — operator evidence required |
| EX-07 | reconnect | a new source or character identity cannot reuse the previous profile mapping | Automated contract PASS; live BLOCKED — operator evidence required |
| EX-08 | provider-minimal | optional integrations are unavailable/fallback without blocking core flows | Provider-minimal PASS; live BLOCKED — operator evidence required |

## Live evidence procedure

1. Run lua tests/run.lua and retain the S29 parity line.
2. On ESX Legacy, load a player, trigger a job change, exercise the internal
   duty availability hook, disconnect, and reconnect.
3. Verify money operations against both configured ESX accounts, including an
   insufficient-funds attempt and one idempotent retry.
4. Run the S11 and S13-S15 smoke scenarios; confirm the same booking state
   machine and one settlement key are used.

## Release decision

The ESX adapter contract is automated PASS. The target ESX Legacy runtime must
still pass every live row; any failure blocks the S29 gate.

## Live evidence record

`BLOCKED` — no ESX Legacy/FXServer run record is stored in this checkout. Add
the provider version, FXServer artifact, environment/config flags, timestamp,
logs, and cleanup verification before marking a live row PASS.
