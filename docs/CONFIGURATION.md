# Configuration

The effective configuration is assembled from config/config.lua and the feature/provider tables. Keep configuration declarative; provider code belongs in adapters/integrations.

## Provider selection

provider = { mode = 'explicit', name = 'standalone' } is the safe development default. Supported names are standalone, qbcore, qbox, and esx. mode = 'auto' succeeds only when exactly one supported framework is available. Ambiguous or unavailable providers fail closed.

## Important feature flags

workerMode, clientMode, serviceCatalog, pricing, reputation, scheduling, safety, security, recovery, and domainEvents are enabled by default. payments, deposits, and physical NPCs are off by default. developmentSettlement is for controlled development smoke only and has no money effects.

## Runtime environment and readiness

The effective environment can be selected without editing source: set the
`nightshift_environment` convar to `development`, `staging`, or `production`.
An incomplete development boot is reported as `DEGRADED`; production and
persistent boots fail closed when database, provider, repository, booking, or
mode dependencies are unavailable. `READY` is reserved for a complete service
graph.

## Persistence and security

`nightshift_persistence`, `nightshift_framework`, `nightshift_provider`, and
`nightshift_money_provider` are runtime convars. Feature overrides are
available through `nightshift_payments`, `nightshift_developmentSettlement`,
`nightshift_physicalNpc`, and `nightshift_deposits`. In production,
development settlement is disabled and startup recovery defaults to applying
the configured policy; `nightshift_recovery_apply=false` intentionally fails
the production readiness gate.

Completed-booking settlement recovery is fail-closed by default. A runtime
integration may inject `settlementRecoveryResolver` into the bootstrap options;
it must return `approved=true`, an actor with a source, and distinct validated
`payerSource`/`payeeSource` values. Without that provider-owned resolver the
booking remains pending for operator reconciliation; no `server.cfg` fallback
or guessed player identity is used.

Security rate limits and action-token enforcement are enabled by default. The
only token opt-out is an explicit `developmentOptOut=true` in development.
Never place credentials, secrets, authoritative prices, or client-owned
coordinates in client config.

## NPC streaming

`npcStreaming.modelAllowlist` and `defaultModel` define the only models that a
physical NPC projection may use. Production (or `physicalNpc=true`) requires
an explicit non-empty allowlist containing the default model. The bootstrap
initializes the logical worker pool idempotently; it never creates duplicate
workers on restart.

## Packages and locations

Packages use positive integer minor-unit prices and bounded durations. Every package references allowlisted location IDs and meeting modes. Locations are server-owned descriptors; arbitrary client coordinates are ignored.
