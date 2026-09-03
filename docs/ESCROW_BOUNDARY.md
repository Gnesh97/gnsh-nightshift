# Release and escrow boundary

NightShift ships as a normal FiveM resource. The public release boundary is
the runtime contract, not a promise that the current repository is encrypted:
the standard release builder produces an inspectable archive and does not
perform escrow obfuscation.

## Always-open integration surface

The following files and contracts must remain usable by a server owner or an
integration author:

- `config/` feature, provider, location, security, and framework settings;
- locale/UI copy and `web/dist` assets;
- `docs/` installation, API, provider, and troubleshooting guidance;
- typed provider registries and adapter contracts under `server/adapters/`;
- the read-only public API exports and privacy-safe DTO shapes documented in
  `docs/API.md`.

Integrations must not depend on private table layouts, internal service state,
or undocumented error strings. Provider absence must continue to produce the
documented typed fallback or unavailable result.

## Optional proprietary boundary

If a commercial distribution later enables FiveM escrow for server logic, the
candidate boundary is the implementation behind the server domain/services,
repositories, jobs, and security modules. The open integration surface above
must still be emitted in the artifact, and `fxmanifest.lua` must continue to
resolve the public adapter/API entry points. Escrow packaging is therefore a
separate release profile; it must not silently change configuration defaults,
DTO allowlists, migration order, or provider capability checks.

The current `scripts/build_release.py` intentionally creates the open,
source-preserving profile. It excludes tests, development smoke code, cache,
dependency trees, credentials, and CI/editor metadata, but it does not claim
to encrypt or conceal server implementation.

## Escrow acceptance checklist

Before publishing an escrow profile, verify both profiles against the same
fresh/upgrade matrix:

1. the open profile passes `lua tests/run.lua`, NUI lint/build, syntax, and
   release-builder checks;
2. the escrow profile starts with the same framework/provider combinations and
   applies migrations in the same order;
3. provider registration, public exports, safe DTOs, and failure codes remain
   available to integrations;
4. no tests, `.env*` files, CI metadata, or development smoke modules are in
   the customer artifact; and
5. the escrow profile is reviewed as a separate artifact before distribution.
