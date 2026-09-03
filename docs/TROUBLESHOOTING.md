# Troubleshooting

## Resource starts but commands do nothing

Check the startup log for NightShift server ready, verify the active environment and smoke convar, and confirm the command is run from an in-game player when required. Smoke commands print their enabled list at startup; no server.cfg edit is needed for normal NUI use.

## NUI is transparent or does not open

Run nightshift_marketplace in game, confirm ui_page points at web/dist/index.html, rebuild with npm run build, and check browser/F8 errors. The resource must include the built dist assets.

## Provider unavailable or ambiguous

Use explicit provider selection while diagnosing. Ensure only the intended framework resource is started, its adapter is available, and dependencies start before NightShift. Auto mode intentionally rejects multiple candidates.

## Quote/session/settlement errors

Use IDs and tokens from the latest successful response, accept before quote expiry, complete only after the configured minimum duration, and verify the provider capability. Development settlement is a dry-run path; real settlement requires a configured durable money adapter.

## Database/migration errors

Check oxmysql availability, migration order/checksum, table permissions, and the startup migration version. Do not edit migration markers manually. Enable persistence only after the database connection is healthy.
