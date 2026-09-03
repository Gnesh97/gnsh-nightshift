# NightShift

NightShift is a server-authoritative FiveM marketplace and booking resource for QBCore, Qbox, ESX, or standalone deployments. The embedded NUI discovers public worker cards, requests a server quote, and drives the booking/client-mode flow. Prices, identity, locations, tokens, booking state, and settlement are never client-authoritative.

## Quick start

1. Copy the resource into resources/[standalone]/gnsh-nightshift.
2. Install SQL migrations when persistence is enabled.
3. Configure provider and features in config/ (see docs/CONFIGURATION.md).
4. Ensure the resource after its framework/database dependencies.
5. Run nightshift_marketplace in game to open the NUI.

The default development configuration is standalone, persistence-off, payments-off, and development settlement-on. Do not copy development settlement settings into production.

## Documentation

- docs/INSTALLATION.md · docs/CONFIGURATION.md · docs/FRAMEWORKS.md
- docs/PROVIDERS.md · docs/API.md · docs/SECURITY.md
- docs/WORKER_MODE.md · docs/CLIENT_MODE.md · docs/NPC_TRAVEL.md
- docs/LOCATIONS.md · docs/PHONE.md · docs/TROUBLESHOOTING.md

## Authority boundary

Treat every client/NUI value as an untrusted request. The server resolves worker identity, package, quote, location, travel, appointment, deposit, refund, and settlement. Optional integrations may be unavailable; core behavior fails closed or degrades explicitly.

## Development checks

From the resource root, run lua tests/run.lua. From web/, run npm run build. Live FXServer smoke still requires an operator and a real framework/database/provider environment.
