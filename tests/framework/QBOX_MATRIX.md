# S29 / NS-291 — Qbox Release Matrix

This matrix proves Qbox is a first-class provider, not a QBCore alias. The
adapter uses qbx_core exports where available and consumes Qbox lifecycle
events without changing the shared booking or service layer.

## Automated contract gate

Run:

~~~text
lua tests/run.lua
~~~

The parity contract injects a Qbox-shaped player and checks independent
capability metadata (qboxNative=true). It covers the official Qbox server
events used by the adapter:

- QBCore:Server:PlayerLoaded (player payload)
- qbx_core:server:playerLoggedOut
- QBCore:Server:OnPlayerUnload
- playerDropped
- QBCore:Server:OnJobUpdate
- QBCore:Server:SetDuty

Logout is normalized from a bounded last-identity snapshot because Qbox
explicitly removes the player from its in-memory registry before the
post-logout event.

## Live matrix

| ID | Flow | Expected evidence | Status |
| --- | --- | --- | --- |
| QX-01 | player load/logout | normalized identity on load; post-logout callback carries loaded=false and releases the snapshot | Contract PASS; live operator run |
| QX-02 | job/duty update | Qbox job grade and SetDuty boolean map to the normalized job DTO | Contract PASS; live operator run |
| QX-03 | money | qbx money get/remove/add operations use the Qbox money adapter and fail closed when unavailable | Contract PASS; live operator run |
| QX-04 | Worker Mode | S11 negotiation and session use the same unified booking core and settle once | Existing S11 contracts PASS; live operator run |
| QX-05 | all Client modes | COME_TO_ME, PICKUP, and MEET_THERE retain mode-specific travel only | S13-S15 contracts PASS; live operator run |
| QX-06 | reconnect | source reuse refreshes identity and does not inherit the old character/profile | Contract PASS; live operator run |
| QX-07 | provider capabilities | qboxNative, lifecycle, job, duty, money, and identity capabilities are reported accurately | Contract PASS; live operator run |
| QX-08 | optional provider absence | NUI, locations, target fallback, notifications, dispatch, and appearance degrade independently | Provider-minimal PASS; live operator run |

## Live evidence procedure

1. Run lua tests/run.lua and retain the S29 parity line.
2. On qbx_core, verify load -> duty toggle -> job update -> disconnect/logout ->
   reconnect. Confirm qbx_core:server:playerLoggedOut is observed for explicit
   logout and playerDropped covers direct disconnect.
3. Run the existing S11 and S13-S15 smoke sequences and replay completion.
4. Repeat with optional phone/target/dispatch/appearance resources stopped;
   missing integrations must not prevent the marketplace from loading.

## Release decision

The Qbox adapter contract is independent and automated PASS. Live Qbox rows are
still required on the target server. A Qbox-specific failure blocks release;
no compatibility alias or core patch is an acceptable workaround.
