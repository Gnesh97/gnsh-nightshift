# Locations

Locations are typed, registered, server-owned references. Supported categories include configured locations, safe roadside pickup points, motel/hotel rooms, housing, venues, vehicles, and custom providers.

The resolver validates provider registration, access requirements, blocked tags, availability, reservability, meeting mode, and route/travel limits. It returns a safe world target only after server validation. Arbitrary client coordinates are never used to select or reserve a location.

Location holds are atomic, booking-scoped, TTL-bound, idempotent, and released/occupied only by the owning booking. Provider mirror failures trigger typed errors and compensation where supported.

The default development location is configured_default; pickup references include pickup:vinewood:1, pickup:vinewood:2, and pickup:los_santos:1.
