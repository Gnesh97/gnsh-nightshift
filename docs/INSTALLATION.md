# Installation

NightShift is a FiveM resource with an embedded Vite-built NUI.

## Runtime order

Ensure dependencies first, then NightShift. Typical order is database adapter, framework (qb-core, qbx_core, or es_extended), optional integrations, then gnsh-nightshift. The resource does not edit server.cfg; the operator owns startup order and convars.

## Database

With nightshift_persistence=true, provide the oxmysql runtime and apply SQL files in sql/ in migration order. Bootstrap reports persistence, database presence, and migration version. A mismatch is a startup failure; do not manually alter the schema marker.

## Runtime convars

The resource reads these optional convars at boot (the operator owns
`server.cfg` and restart order):

| Convar | Values | Purpose |
| --- | --- | --- |
| `nightshift_environment` | `development` / `staging` / `production` | Readiness policy; production fails closed |
| `nightshift_provider` | `standalone` / `qbcore` / `qbox` / `esx` | Explicit provider selection |
| `nightshift_framework` | adapter name | Framework adapter override |
| `nightshift_money_provider` | adapter name | Money adapter override |
| `nightshift_persistence` | `true` / `false` | Enable database and migration gate |
| `nightshift_physicalNpc` | `true` / `false` | Enable physical NPC projection |
| `nightshift_payments` | `true` / `false` | Enable live money capability checks |
| `nightshift_deposits` | `true` / `false` | Enable deposit lifecycle |
| `nightshift_recovery_apply` | `true` / `false` | Override startup recovery policy |

Development defaults may be `DEGRADED` when optional runtime dependencies are
not present. Do not treat that status as a live-provider success. Production
must reach `READY`; unresolved recovery work or missing dependencies keeps the
resource failed closed.

## NUI build

The shipped web/dist files are referenced by fxmanifest.lua. For source changes:

    cd web
    npm install
    npm run build

## Verification

Run `lua tests/run.lua`, `npm run lint -- --deny-warnings`, `npm run build`,
`python scripts/validate_locales.py`, `python scripts/secret_scan.py .`, and a
Lua syntax check before live testing. Then restart the resource from the server
console and capture the sanitized readiness line. Live framework/provider,
OneSync, and recovery evidence must follow the templates in
`tests/scenarios/` and may not be replaced by browser mocks.
