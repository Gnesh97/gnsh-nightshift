local function check(value, message) assert(value, message) end

local previousExports = rawget(_G, 'exports')
local previousInstance = NightShift.Server and NightShift.Server.instance
local registered = {}
_G.exports = function(name, handler)
    registered[name] = handler
end
NightShift.Api._publicExportsInstalled = false

local bookingService = {
    get = function() return NightShift.Result.ok({ id = 9, status = 'ACCEPTED', token = 'hidden' }) end
}
local marketplace = {
    list = function() return NightShift.Result.ok({ items = { { publicId = 'worker-9', name = 'Public', secret = 'hidden' } }, total = 1 }) end
}
local clientProfile = {
    get = function() return NightShift.Result.ok({ id = 5, displayName = 'Client', password = 'hidden' }) end
}
local providerApi = { list = function() return NightShift.Result.ok({ { id = 'config', available = true } }) end }
local diagnostics = {
    snapshot = function(_, source) check(source == 0, 'health export must use server-side diagnostic authority'); return NightShift.Result.ok({ bounded = true }) end
}
NightShift.Server.instance = { results = { services = {
    services = {
        booking = bookingService, marketplace = marketplace, clientProfile = clientProfile,
        locationProviderApi = providerApi, diagnostics = diagnostics
    }
} } }
NightShift.Api.installPublicExports()

local booking = registered.GetBooking(9)
check(booking.ok and booking.value.bookingId == 9 and booking.value.token == nil, 'GetBooking export must return a safe DTO')
local workers = registered.ListAvailableNPCWorkers({})
check(workers.ok and workers.value.items[1].workerId == 'worker-9' and workers.value.items[1].secret == nil,
    'worker listing export must return safe DTO cards')
local profile = registered.GetClientProfileSummary(12)
check(profile.ok and profile.value.profileId == 5 and profile.value.password == nil, 'profile export must omit private fields')
check(registered.ListLocationProviders().ok and registered.GetHealth({}).ok, 'read-only provider/health exports must be available')
local blocked = registered.CreateExternalBookingRequest({})
check(not blocked.ok and blocked.error.code == NightShift.Errors.Codes.API_FORBIDDEN, 'external booking write must remain disabled')

NightShift.Server.instance = previousInstance
NightShift.Api._publicExportsInstalled = false
_G.exports = previousExports
print('NS-263..NS-265 tests passed: read-only exports, safe DTOs, health authority, and blocked external writes')
