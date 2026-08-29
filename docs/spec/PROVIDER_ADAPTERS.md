# Provider Adapter Conventions

S03 provider code is the only boundary allowed to call QBCore, Qbox, ESX Legacy, oxmysql, phone, housing, motel, dispatch, appearance, evidence, target, or notify APIs. Core/domain/service code consumes normalized contracts and capability snapshots.

## Framework adapters

`NightShift.FrameworkInterface` exposes:

- `getPlayer(source)` / `getIdentity(source)` → immutable normalized identity and job DTO
- `getJob(source)` → normalized job DTO
- `isPlayerLoaded(source)`
- `onPlayerLoaded`, `onPlayerUnloaded`, `onJobChanged`, `onDutyChanged`
- `getCapabilities()` and `healthCheck()`

The normalized identity contains `source`, `identifier`, `characterId`, `characterName`, `job`, `loaded`, and `provider`. Native player objects never leave the adapter. Qbox is an independent implementation; it is not a QBCore alias. ESX duty gaps use the `internalDuty`/`availability` capability, while Standalone reports a no-job profile.

## Money adapters

Money operations accept a positive integer amount in configured minor units and an allowlisted account (`cash`, `bank`, or a configured custom account). `has`, `remove`, `add`, and `transfer` return Result envelopes. False or ambiguous mutation acknowledgements fail closed. A non-atomic transfer reports `atomic = false` and attempts a compensating credit if the destination leg fails.

## Optional providers

Phone, housing, motel, dispatch, appearance, evidence, target, and notify providers expose `getCapabilities()` and `healthCheck()`. Their absence never blocks resource startup:

- required location/phone operations return `CAPABILITY_UNAVAILABLE`;
- dispatch/evidence use an explicit skipped result;
- appearance, target, and notify expose a documented fallback result.

Feature services must inspect capabilities before showing or executing an optional flow. Optional provider implementations receive copied payloads and must not become a source of booking, payment, or reputation truth.

## Resolver

`NightShift.ProviderResolver` applies explicit configuration first. Auto mode accepts exactly one available framework and rejects ambiguity; it never silently falls back from an explicit selection. Resource dependencies can be supplied through `resourceNames`/`dependencies`. The resolver returns the selected adapters, capability summary, candidate list, and missing optional provider diagnostics.

Runtime-specific event names and injected seams are configurable so adapters can be tested without a FiveM process. Live framework/export/money smoke tests remain a release-gate requirement.
