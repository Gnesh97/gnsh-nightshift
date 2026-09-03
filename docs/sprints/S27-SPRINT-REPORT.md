# S27 Sprint Report — Security, Abuse & Concurrency

## Delivered

- Added an allowlisted security configuration with bounded rate rules.
- Added a source/method token-bucket limiter with burst, refill, eviction,
  reset, purge, stable RATE_LIMITED errors, and read-only status.
- Installed the limiter at the NUI network gateway before service dispatch.
- Added short-lived opaque action tokens bound to actor, booking, and action.
  Tokens support nonce generation, verification, one-time consume, replay,
  expiry, revocation, and bounded capacity.
- Registered the limiter and token store through the normal bootstrap services
  stage and exposed a read-only GetSecurityStatus export.
- Added S27 smoke commands (development-only, console-only) and abuse/race
  matrices.

## Safety boundary

The startup/recovery path remains observation-only. Action-token enforcement is
opt-in (security.actionTokens.enforce = false) until every caller has been
migrated to issue and present the new token. No server.cfg edits or runtime
restart commands are required by this sprint.

## Verification

- lua tests/run.lua — all existing suites plus NS-270..NS-274 passed.
- Lua loadfile syntax sweep — changed Lua files passed.
- npm run build in web/ — passed.
- git diff --check — passed.
