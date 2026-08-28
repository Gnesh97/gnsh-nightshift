# Changelog

All notable changes to NightShift are documented here.

## [Unreleased]

### S00 — Specification Freeze

- Initialized repository and isolated `feat/s00-specification-freeze` branch.
- Added normative domain invariants for unified Worker/Client booking, participant validation, settlement, NPC identity, and location reservations.
- Added provider capability matrix with server-authoritative contracts and safe fallbacks.
- Added five architecture decision records for booking, NPC entities, authority, locations, and OneSync ownership.
- Hardened the final S00 contracts with the complete canonical Booking lifecycle, deterministic alternate/recovery transitions, and explicit travel-state mapping.
- Defined durable non-reassignable location quarantine until confirmed release/reconciliation, plus atomic or compensatable split-leg settlement with conditional query/replay capability gates.
- Clarified configuration-driven cancellation refunds/deposit releases and the healthy, fresh server-owned internal availability fallback.
- Added the S00 Sprint Report; production resource implementation remains intentionally deferred until S01.
- Kept S01 Resource Foundation and all runtime/FiveM implementation deferred.
- Refreshed the codebase-memory index after final S00 contract hardening; S01 remains deferred.
