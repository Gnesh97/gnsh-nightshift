# S09 Sprint Report — NPC Travel, Streaming & Entity Control

## Scope

S09 adds server-authoritative logical NPC travel and a replaceable physical
representation boundary. A distant worker can progress without a ped, while
near-player spawning, navigation, arrival, ownership changes, deletion, and
despawn remain generation-bound and validated.

## Delivered

- **NS-090:** Added immutable travel plans and service operations for typed
  origin/destination references, deterministic ETA, logical progress, spawn
  threshold, recovery state, arrival, and return transitions. Destination
  world targets are retained only after server location resolution.
- **NS-091:** Added server/client entity registries with profile-to-entity
  generation tokens, network-handle metadata, ownership migration tolerance,
  deletion detection, replacement generations, and no client business-state
  storage.
- **NS-092:** Added server-safe spawn authorization and client spawn handling.
  Model allowlists, server-resolved candidates, generation tokens, and
  optional server-created entities prevent client-supplied models or
  coordinates from controlling a ped.
- **NS-093:** Added near-player navigation with arrival-radius checks, stuck,
  timeout, player-away, and deleted-entity recovery. Added server arrival
  validation against the travel plan, entity generation, owner, plausibility
  callback, and booking transition guard.
- **NS-094:** Added bounded client fade/delete cleanup and optional
  generation-bound worker return callback; registry cleanup prevents leaked
  physical mappings while logical state remains server-owned.
- Added streaming policy configuration, shared enums/error codes/schemas,
  manifest and bootstrap wiring, and S09 contract coverage.

## Verification

- \`lua tests/run.lua\` — pass (S05, S06, S07, S08, S09, core, provider,
  repository, migration, schema, and profile contracts).
- \`luac -p\` — pass for all 107 Lua files.
- \`git diff --check\` — pass.

## Runtime Gate

S09 is ready for the next controlled FiveM restart. The default configuration
keeps model allowlists empty and therefore fails closed until a server
integration supplies approved models and safe spawn candidates. Live player
navigation/entity smoke remains the next runtime gate.
