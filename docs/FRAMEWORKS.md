# Frameworks

NightShift uses a normalized framework adapter so domain services do not branch on framework APIs.

| Framework | Identity | Lifecycle/job/duty | Money |
| --- | --- | --- | --- |
| QBCore | citizen ID + character | QBCore:Server:PlayerLoaded, unload, job and duty events | normalized account operations |
| Qbox | Qbox player/export APIs | QBCore:Server:PlayerLoaded, unload/logout/disconnect, job/duty | Qbox-native capability when available |
| ESX | identifier + character metadata | esx:playerLoaded, disconnect, esx:setJob, optional duty event | normalized account operations |
| Standalone | configured source identity | no external lifecycle | no real money |

Adapters expose normalized identity, job, grade, duty, loaded state, and capabilities. Services consume those values only. If an adapter is missing or throws, provider resolution fails closed.

For live parity, run rows in tests/framework/ with the actual framework installed. Do not assume a QBCore-compatible event name is valid for Qbox.
