# S07 Sprint Report — Typed Locations, Atomic Location Holds & Vehicle Resolution

**Date:** 2026-08-29

**Status:** PASS (local contracts, migration/schema wiring, static verification; live location/provider/vehicle smoke pending)

**Scope:** NS-070, NS-071, NS-072, NS-073

## Completed tasks

- **NS-070 — Location Domain:** added allowlisted location types and meeting modes, normalized location references, immutable server-owned world targets, access requirements, provider/category descriptors, route limits, blocked tags, availability, and reservability.
- **NS-071 — Location Resolver:** added typed-reference resolution for configured and optional provider locations. Resolver checks registration, type compatibility, provider validation, access authorization, blocked/restricted tags, finite/bounded targets, water safety hooks, and route reachability/max distance. Registered server targets override all client-supplied coordinates.
- **NS-072 — Atomic Location Reservation:** added location reservation domain/repository/service with location-scoped lock keys, booking idempotency, TTL holds, owner-bound occupy/release, expiration, optional persistence, provider reserve/occupy/release mirrors, and rollback when provider/persistence fails.
- **NS-073 — Vehicle Location Resolver:** added server-visible vehicle lookup, player access, stationary/private checks, configurable allowed-zone validation, safe server position checks, optional water/booking binding, and typed VEHICLE output. Remote client vehicle IDs/coordinates are not trusted.
- **Booking integration:** BookingService now resolves a supplied typed location before creating a draft and persists the canonical locationType/locationRef.
- **Bootstrap/persistence:** location services and repositories are available in deferred development boot and full provider boot; migration sql/013_location_resolver.sql extends location descriptors and adds a location-scoped active reservation key.

## Changed files

- config/locations.lua
- config/config.lua
- shared/enums.lua
- shared/errors.lua
- shared/schemas.lua
- shared/validators.lua
- server/domain/location.lua
- server/domain/location_reservation.lua
- server/repositories/location_repository.lua
- server/repositories/location_reservation_repository.lua
- server/services/location_service.lua
- server/services/location_reservation_service.lua
- server/services/vehicle_location_service.lua
- server/services/booking_service.lua
- server/bootstrap.lua
- server/core/migrations.lua
- sql/013_location_resolver.sql
- fxmanifest.lua
- tests/s07_location_contracts.lua
- tests/run.lua
- tests/migrations_contracts.lua
- tests/schema_contracts.lua
- CHANGELOG.md

## Tests and verification

- C:\Users\Gnesh\AppData\Local\Programs\Lua\5.5.1\lua.exe tests/run.lua passes NS-010/011, NS-020/023, NS-030..037, NS-040..043, NS-050..054, NS-060..065, and NS-070..073 contracts.
- S07 contracts cover normalization/immutability, invalid target/type fail-closed behavior, provider routing, access and blocked-zone checks, water/route checks, same-location conflict, idempotent retry, TTL expiry, provider rollback, repository persistence, and vehicle validation.
- All Lua files parse with luac -p; git diff --check passes.
- Schema/migration contracts verify migration 013 registration and typed/active-key columns.

## Live FiveM gate

- The prior live persistence gate is green (persistence=true database=true migration=12). Migration 013 and location/vehicle smoke require one controlled resource restart against the running MariaDB instance.
- No live provider or player vehicle operation was executed in this local phase. The next gate is a server-console restart, migration 013 application, then a player smoke using a registered location and a stationary private vehicle.

## Security / recovery

- Location selection is server-authoritative: only allowlisted typed references reach the resolver, and client world targets are discarded.
- Provider and vehicle callbacks are capability-gated and fail closed. Reservation provider failures release local holds; persistence failures compensate provider mirrors and local locks.
- Reservation keys are booking-scoped for retries and location-scoped for active uniqueness. Occupy/release require the owning booking.

## Exit Gate

- [x] Typed location domain/configuration and validation.
- [x] Server resolver with provider/access/blocked/target/route checks.
- [x] Atomic location reservation with TTL, owner checks, provider compensation, and active uniqueness.
- [x] Server-bound vehicle location validation.
- [x] Booking/bootstrap/repository/migration wiring.
- [x] Local contracts, parser, schema/migration, and diff verification.
- [ ] Live location/provider/vehicle player smoke after migration 013 restart.

**S07 Exit Gate: PASS for local implementation and safety contracts. Live location/provider/vehicle smoke is the next runtime action.**
