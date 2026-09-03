# S29 / NS-290 — QBCore Release Matrix

This matrix is the QBCore provider gate. The framework adapter is the only
place allowed to know QBCore event names and PlayerData shapes; domain,
booking, worker, client-mode, and settlement services consume normalized
identities and capabilities.

## Automated contract gate

Run from the resource directory:

~~~text
lua tests/run.lua
~~~

tests/s29_framework_parity_contracts.lua verifies the adapter with a
QBCore-shaped player fixture, including QBCore:Server:PlayerLoaded,
QBCore:Server:PlayerUnload, QBCore:Server:OnJobUpdate, and
QBCore:Server:SetDuty. It also verifies that an unload can be normalized from
the last safe identity snapshot after QBCore removes the player object.

## Live matrix

| ID | Flow | Expected evidence | Status |
| --- | --- | --- | --- |
| QB-01 | identity/load/unload | normalized identifier, character ID/name, loaded=true; unload invalidates the source cache | Contract PASS; live operator run |
| QB-02 | job/duty | OnJobUpdate and SetDuty update normalized job/grade/duty | Contract PASS; live operator run |
| QB-03 | money/deposit/refund | cash/bank debit, credit, insufficient-funds failure, idempotent deposit/refund | Contract PASS; live operator run |
| QB-04 | Worker Mode | S11 vertical slice reaches SETTLED once and releases worker/location locks | Existing S11 contracts PASS; live operator run |
| QB-05 | Client COME_TO_ME | quote -> reserve -> travel -> spawn/arrival -> session -> settlement | S13 contracts PASS; live operator run |
| QB-06 | Client PICKUP | safe pickup claim, vehicle binding, destination arrival, settlement | S14 contracts PASS; live operator run |
| QB-07 | Client MEET_THERE | dual arrival barrier and one settlement | S15 contracts PASS; live operator run |
| QB-08 | reconnect/recovery | logout releases identity/permission cache; reconnect refreshes the ephemeral source | Contract PASS; live operator run |
| QB-09 | standalone NUI | panel opens only on an explicit UI action; closed state has no active panel | NUI visibility PASS; live operator run |
| QB-10 | location provider/fallback | configured location works; missing optional provider returns typed fallback/unavailable result | Provider contracts PASS; live operator run |

## Live evidence procedure

1. Run the automated gate and retain the NS-290..NS-293 line.
2. On a QBCore server, load one player, change job/duty, disconnect, and
   reconnect. Confirm no raw QBCore object appears in a NightShift DTO.
3. Run the documented S11/S13/S14/S15 development smoke sequences from their
   sprint reports. Record booking IDs and final states; retry completion once.
4. Open the marketplace NUI explicitly and verify the closed page remains
   hidden after resource load.

The live rows are deployment evidence, not a reason to add framework branches
to core services. Any QBCore-only failure belongs in this adapter or its
configuration.

## Release decision

The automated QBCore adapter contract is PASS. The QBCore live rows remain an
operator-side gate until run against the target FXServer build. A failed row
blocks the S29 release gate.
