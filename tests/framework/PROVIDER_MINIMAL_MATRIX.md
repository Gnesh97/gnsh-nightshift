# S29 / NS-293 — Provider-Minimal Release Matrix

The provider-minimal profile proves that optional phone, housing, motel,
target, notify, dispatch, and appearance resources are not core release
dependencies. The framework adapter may still be QBCore, Qbox, ESX, or
standalone; optional providers are capability probes, not hard requirements.

## Automated contract gate

Run:

~~~text
lua tests/run.lua
~~~

tests/s29_framework_parity_contracts.lua and tests/provider_contracts.lua
verify typed absence behavior. Missing providers either return a bounded
fallback/skip result or a typed CAPABILITY_UNAVAILABLE result; they never
fabricate a success or expose a raw external handle.

## Matrix

| ID | Flow | Expected evidence | Status |
| --- | --- | --- | --- |
| PM-01 | standalone NUI | resource load leaves the panel hidden; an explicit command/action opens it | NUI visibility PASS; live operator run |
| PM-02 | config locations | allowlisted config location resolves and invalid references fail closed | Location contracts PASS; live operator run |
| PM-03 | no target provider | interaction registration returns the local fallback; core remains usable | Contract PASS; live operator run |
| PM-04 | standalone notifications | notify adapter returns a local fallback without a hard dependency | Contract PASS; live operator run |
| PM-05 | no dispatch | safety/incident path records a skipped optional dispatch result | Contract PASS; live operator run |
| PM-06 | no appearance | NPC appearance uses the bounded fallback and does not block spawn logic | Contract PASS; live operator run |
| PM-07 | no phone/housing/motel | marketplace and configured-location flows remain available; unsupported external operations are typed | Contract PASS; live operator run |
| PM-08 | no provider leakage | DTOs and diagnostics contain capability/status metadata only, never raw provider objects | Provider and DTO contracts PASS; live operator run |

## Live evidence procedure

1. Stop or omit each optional resource one at a time; do not change
   server.cfg for the NightShift implementation.
2. Run the NUI marketplace explicitly and verify the page is hidden until the
   user opens it.
3. Resolve a configured location, try the target fallback, send a local
   notification, and exercise safety/appearance paths.
4. Confirm the server logs typed capability results and continues serving the
   core marketplace/booking flow.

## Release decision

Provider absence is not a release blocker when the documented fallback or
typed-unavailable contract is observed. A raw-handle leak, fabricated success,
or optional provider becoming a hard core dependency is a release blocker.
