# Identity, Player Profiles, and Permissions

S04 defines the server-owned boundary for player identity and the two player
profile aggregates used by the booking core.

## Stable identity

`IdentityService` consumes only the normalized framework adapter. A persistent
identity is the composite of `playerIdentifier` and `characterId`; the runtime
FiveM source ID is an ephemeral lookup value and is never written as a profile
key. A missing character ID uses the same deterministic default component for
all reconnects.

The service returns a copied identity DTO with a stable `identityKey`, a safe
display alias, and the current source. Reconnects can therefore change source
IDs without changing profile ownership. Character changes and source reuse
produce different keys. Unload handling clears only the in-memory source map.

## Player profiles

Worker and client profiles are separate persistent aggregates. Their
repositories query the `(player_identifier, character_id)` unique identity and
use the base repository's parameterized SQL and expected-version updates.
Services resolve identity from the server-side framework adapter before every
read or write. Profile updates produce a new value and reject identity/source
fields supplied by callers.

`sql/010_identity_profiles.sql` extends the S02 profile tables with worker
traits/counters and client counters/rating/tier/deposit-risk metadata without
editing an already-applied migration checksum.

## Permissions

`PermissionService` is the only S04 authorization boundary. Permission keys
are allowlisted in `config/permissions.lua`; unknown keys and malformed
provider responses fail closed. The service may combine trusted server-side
ACE checks, normalized framework job/grade mappings, and an explicitly injected
custom provider. Client flags are never read.

Successful decisions may be cached by stable identity key. Job and unload
lifecycle callbacks invalidate the relevant entries; denials are evaluated
again so ACE/provider changes do not remain stale.
