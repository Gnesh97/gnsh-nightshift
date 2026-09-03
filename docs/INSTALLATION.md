# Installation

NightShift is a FiveM resource with an embedded Vite-built NUI.

## Runtime order

Ensure dependencies first, then NightShift. Typical order is database adapter, framework (qb-core, qbx_core, or es_extended), optional integrations, then gnsh-nightshift. The resource does not edit server.cfg; the operator owns startup order and convars.

## Database

With nightshift_persistence=true, provide the oxmysql runtime and apply SQL files in sql/ in migration order. Bootstrap reports persistence, database presence, and migration version. A mismatch is a startup failure; do not manually alter the schema marker.

## NUI build

The shipped web/dist files are referenced by fxmanifest.lua. For source changes:

    cd web
    npm install
    npm run build

## Verification

Run lua tests/run.lua, npm run build, and a Lua syntax check before live testing. Then restart the resource from the server console and check for NightShift server ready. Live framework/provider tests are documented in tests/framework/.
