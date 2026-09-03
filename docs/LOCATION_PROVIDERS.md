# Location Providers

NightShift keeps motel, hotel, housing, and other location integrations behind
typed server-side adapters. Booking and location services consume the provider
contract; they do not call a motel resource directly.

## Motel / hotel contract

Register a provider with NightShift.Motel.ProviderRegistry.new:

~~~lua
local registry = NightShift.Motel.ProviderRegistry.new({
    defaultProvider = 'my_motel',
    providers = {
        my_motel = NightShift.OptionalProviders.Motel.new({
            listAvailable = function(source, context) end,
            validate = function(source, roomId, context) end,
            reserve = function(roomId, bookingId, ttlSeconds) end,
            occupy = function(roomId, bookingId) end,
            release = function(roomId, bookingId) end,
            resolveWorldTarget = function(roomId, context) end
        })
    }
})
~~~

The registry also accepts the legacy names getAvailableRooms, validateRoom,
reserveRoom, and releaseRoom. Every operation is invoked server-side,
validates its arguments, copies input tables, and returns a NightShift.Result.
A provider may return a Result, true, or a value table; rejected calls are
typed errors.

Supported operations:

| Operation | Purpose |
| --- | --- |
| listAvailable(source, context) | List rooms the player may see |
| validate(source, roomId, context) | Re-check access and room validity |
| reserve(roomId, bookingId, ttlSeconds) | Hold a room for a booking |
| occupy(roomId, bookingId) | Mark a held room in use |
| release(roomId, bookingId) | Release a hold or occupied room |
| resolveWorldTarget(roomId, context) | Return a safe meeting/world target |

list(), resolve(name), and each operation expose capability/availability
information. Missing or stopped optional providers return a successful
skipped result, allowing the marketplace to hide or degrade the location
feature without changing BookingService.

Provider code must remain isolated in the adapter/integration layer. Never
trust client-supplied room state, booking state, price, or world coordinates;
the provider and the server location service must validate them at the point
of use.
