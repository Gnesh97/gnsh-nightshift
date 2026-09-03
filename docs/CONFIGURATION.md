# Configuration

The effective configuration is assembled from config/config.lua and the feature/provider tables. Keep configuration declarative; provider code belongs in adapters/integrations.

## Provider selection

provider = { mode = 'explicit', name = 'standalone' } is the safe development default. Supported names are standalone, qbcore, qbox, and esx. mode = 'auto' succeeds only when exactly one supported framework is available. Ambiguous or unavailable providers fail closed.

## Important feature flags

workerMode, clientMode, serviceCatalog, pricing, reputation, scheduling, safety, security, recovery, and domainEvents are enabled by default. payments, deposits, and physical NPCs are off by default. developmentSettlement is for controlled development smoke only and has no money effects.

## Persistence and security

nightshift_persistence is a runtime convar. Security rate limits are enabled by default; action-token enforcement is intentionally opt-in until all callers use the token contract. Never place credentials, secrets, or authoritative prices in client config.

## Packages and locations

Packages use positive integer minor-unit prices and bounded durations. Every package references allowlisted location IDs and meeting modes. Locations are server-owned descriptors; arbitrary client coordinates are ignored.
