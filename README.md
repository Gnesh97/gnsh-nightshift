# gnsh-nightshift (NightShift)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Server-authoritative FiveM marketplace, booking, and worker/client dispatch resource for **QBCore**, **Qbox**, **ESX**, and **standalone** deployments.

## Overview

NightShift provides an embedded Vite-built NUI and a server-authoritative booking core for player and NPC service workers. Clients can discover public worker cards, request server quotes, negotiate packages, and manage appointments or client-mode pickups while all pricing, identity, location resolution, action tokens, booking state transitions, deposits, refunds, and settlements remain strictly server-owned.

## Key Features

- **Marketplace & Booking Core:** Service catalog, dynamic pricing & demand/heat feedback, negotiation, conflict-checked scheduling, agencies, venues, favorites, reviews, relationships, and blacklists.
- **Worker & Client Modes:** Full workflows for player workers, NPC worker pools, customer candidate discovery, pickup/vehicle meeting modes, and dual-travel coordination.
- **NPC Streaming & Travel:** Logical-to-physical NPC projection with model allowlists (`npcStreaming.modelAllowlist`), streaming budgets, OneSync entity ownership policies, and coordinate-free server-owned locations.
- **Security & Authority Boundary:** Every client/NUI payload is treated as untrusted input; guarded by per-source/method rate limiting, one-time action tokens, idempotency keys, and fail-closed production startup recovery.
- **Framework & Optional Integrations:** Adapters for `qbcore`, `qbox`, `esx`, and `standalone`, `oxmysql` persistence (23 SQL migrations in [`sql/`](sql)), and optional phone integrations (`lb`, `qs`, `qb`, `yseries`, `generic`).

## Quick Start

1. Copy the resource into `resources/[standalone]/gnsh-nightshift`.
2. When `nightshift_persistence=true`, start `oxmysql` and ensure the migrations in [`sql/`](sql) (`001_schema_version.sql`–`023_idempotency.sql`) are applied in order.
3. Configure runtime convars in `server.cfg` and declarative defaults under [`config/`](config) (see [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)).
4. Add `ensure gnsh-nightshift` after your database, framework, and optional integration resources.
5. Run `nightshift_marketplace` in game to open the NUI.

> The default development profile (`environment = 'development'`) uses `standalone`, persistence off, payments off, and `developmentSettlement = true`. Never carry development settlement settings into production; production boots fail closed unless dependencies and recovery checks succeed (`READY`).

### Runtime Convars

| Convar | Values | Purpose |
| --- | --- | --- |
| `nightshift_environment` | `development` / `staging` / `production` | Readiness policy (production fails closed) |
| `nightshift_provider` | `standalone` / `qbcore` / `qbox` / `esx` | Explicit provider selection |
| `nightshift_framework` | adapter name | Framework adapter override |
| `nightshift_money_provider` | adapter name | Money adapter override |
| `nightshift_persistence` | `true` / `false` | Enable `oxmysql` persistence & migration gate |
| `nightshift_physicalNpc` | `true` / `false` | Enable physical NPC projection |
| `nightshift_payments` | `true` / `false` | Enable live payment checks |
| `nightshift_deposits` | `true` / `false` | Enable deposit lifecycle |
| `nightshift_recovery_apply` | `true` / `false` | Override startup recovery policy |

## Server API & Domain Events

Read-only server exports (returning `NightShift.Result` DTO envelopes) and domain events are documented in [`docs/API.md`](docs/API.md):

- **Exports:** `GetBooking`, `ListAvailableNPCWorkers`, `GetClientProfileSummary`, `ListLocationProviders`, `GetHealth`, `GetSecurityStatus` (`CreateExternalBookingRequest` is intentionally gated until caller authentication is installed).
- **Events:** `nightshift:bookingCreated`, `nightshift:bookingAccepted`, `nightshift:npcWorkerEnRoute`, `nightshift:bookingArrived`, `nightshift:bookingCompleted`, `nightshift:bookingSettled`, `nightshift:bookingCancelled`, `nightshift:safetyAlert`, `nightshift:reputationChanged`.

## Verification & Build

Run offline Lua contracts, NUI build/lint, locale validation, and secret checks from the repository root:

```bash
lua tests/run.lua
cd web && npm ci --ignore-scripts && npm run lint -- --deny-warnings && npm run build && cd ..
python -m unittest discover -s tests -p '*_test.py' -v
python scripts/validate_locales.py
python scripts/secret_scan.py .
```

Live FXServer, OneSync, and framework smoke scenarios are documented under `tests/scenarios/`.

## Documentation

- [`docs/INSTALLATION.md`](docs/INSTALLATION.md) · [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) · [`docs/FRAMEWORKS.md`](docs/FRAMEWORKS.md)
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) · [`docs/API.md`](docs/API.md) · [`docs/SECURITY.md`](docs/SECURITY.md)
- [`docs/WORKER_MODE.md`](docs/WORKER_MODE.md) · [`docs/CLIENT_MODE.md`](docs/CLIENT_MODE.md) · [`docs/NPC_TRAVEL.md`](docs/NPC_TRAVEL.md)
- [`docs/LOCATIONS.md`](docs/LOCATIONS.md) · [`docs/PHONE.md`](docs/PHONE.md) · [`docs/RECOVERY.md`](docs/RECOVERY.md) · [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- [`CHANGELOG.md`](CHANGELOG.md)

## License

Licensed under the [MIT License](LICENSE).
