# S30 Release / Install Matrix

The release archive is produced by `python scripts/build_release.py --version 1.0.0` (the default is a sibling output directory; pass an explicit output outside the resource tree when needed).
The builder stages a copy, runs the web build there, excludes tests/dev/cache/dependencies/secrets, and writes `RELEASE-MANIFEST.json` with SHA-256 hashes. It never writes into the source tree.

| Row | Evidence | Acceptance |
| --- | --- | --- |
| NS-301 builder/CI | python -m unittest tests/release_builder_test.py, CI Lua/TypeScript/lint gates | filters, syntax, contracts, NUI build, and secret-scan gate are green |
| NS-302 NUI | npm run lint && npm run build in web and builder output | archive contains web/dist, no web/node_modules |
| NS-303 escrow boundary | Review docs/ESCROW_BOUNDARY.md and compare open/escrow artifacts | config, provider contracts, public API, DTOs, and migrations remain integration-safe |
| NS-304 fresh QBCore | Disposable FXServer with qb-core and oxmysql; apply sql/*.sql in order | resource starts and reports the expected migration/schema state |
| NS-304 fresh Qbox | Disposable FXServer with qbx_core and oxmysql | framework lifecycle, identity, permissions, and booking smoke pass |
| NS-304 fresh ESX | Disposable FXServer with es_extended and oxmysql | framework lifecycle, identity, permissions, and booking smoke pass |
| NS-304 provider-minimal | Framework disabled; injected minimal provider seams only | optional providers degrade explicitly; core contracts remain green |
| NS-304 upgrade | Restore the previous release database, then apply new migrations in order | migration is monotonic and existing bookings remain readable |
| NS-304 restart recovery | Restart the resource while a scheduled booking is active | scheduler/recovery jobs resume idempotently without duplicate settlement |

## Clean-install evidence

1. Verify the archive contains `fxmanifest.lua`, `config/`, `server/`, `client/`, `shared/`, `sql/`, `web/dist/`, and runtime docs.
2. Verify it contains no `.env*`, `node_modules/`, `tests/`, `server/dev/`, `.git/`, or `.codebase-memory/` paths.
3. Verify every payload file (excluding the manifest itself) appears in `RELEASE-MANIFEST.json` with the same SHA-256.
4. Install into a disposable FiveM resource directory and run the existing Lua contract/syntax, TypeScript build, and migration/locale checks before any server restart.

## Framework and upgrade evidence

The matrix is intentionally runtime-oriented. The local contracts prove the
adapter and migration invariants, while each row above needs one operator
capture from the target FXServer/database combination. Record the startup
line, migration version, booking state before/after restart, and any provider
fallback in the release evidence packet. Normal installation requires only the
resource ensure/startup order; development smoke commands are opt-in and are
not a substitute for these framework/provider checks.
