# S22 Sprint Report — Housing, Motel, Hotel & Custom Location Providers

S22 adds a typed location-provider boundary without requiring any external
motel or housing resource. The configured location provider is available by
default; motel, housing, and custom providers degrade to a typed skipped/error
result when their dependency is absent.

## Delivered

- Motel/hotel registry with room listing, access validation, reservation
  lifecycle, world-target resolution, capabilities, and legacy method aliases.
- Housing registry with booking/arrival access phases, property listing,
  meeting-target resolution, optional interior readiness, and lifecycle calls.
- Configured CONFIG_LOCATION provider with server-owned targets, meeting-mode
  and opening-hour checks, optional fees/capacity, and idempotent holds.
- Custom provider API with guarded exports, immutable request copies,
  capability checks, availability reporting, and dynamic attachment to the
  core location service.
- Bootstrap wiring, manifest load order, runtime fallback loader, and S22
  smoke commands.

## Verification

lua tests/run.lua passes the full contract suite, including NS-220 through
NS-223. A Lua syntax sweep and git diff --check also pass.

## Runtime smoke commands

The development resource exposes:

- /nightshift_s22_provider_list
- /nightshift_s22_locations [type]
- /nightshift_s22_location_resolve [type] [ref] [mode]
- /nightshift_s22_location_reserve [bookingId] [type] [ref] [mode]
- /nightshift_s22_location_occupy [bookingId] [reservationKey]
- /nightshift_s22_location_release [bookingId] [reservationKey]

These commands are resource-local smoke helpers and do not require edits to
server.cfg.
