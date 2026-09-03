local function check(value, message) assert(value, message) end
local Result = NightShift.Result
local Agency = NightShift.Domain.Agency
local AgencyService = NightShift.AgencyService
local AgencyBookingService = NightShift.AgencyBookingService

local state = { nextId = 1, rows = {} }
local repository = {}
function repository:create(value)
    local copy = Agency.copy(value)
    copy.id, copy.version = state.nextId, 1
    state.nextId = state.nextId + 1
    state.rows[copy.key] = copy
    return Result.ok({ insertId = copy.id, id = copy.id })
end
function repository:findByKey(key)
    local row = state.rows[key]
    if not row then return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'agency was not found') end
    return Result.ok(Agency.copy(row))
end
function repository:updateExpectedVersion(id, version, changes)
    for key, row in pairs(state.rows) do
        if row.id == id then
            if row.version ~= version then return Result.err(NightShift.Errors.Codes.VERSION_CONFLICT, 'version mismatch') end
            local nextRow = Agency.copy(row)
            for field, value in pairs(changes) do nextRow[field] = Agency.copy(value) end
            nextRow.version = version + 1
            state.rows[key] = nextRow
            return Result.ok({ id = id, version = nextRow.version })
        end
    end
    return Result.err(NightShift.Errors.Codes.REPOSITORY_NOT_FOUND, 'agency was not found')
end

do
    local service = assert(AgencyService.new({ repository = repository }))
    check(not service:create(7, { key = 'downtown', name = 'Downtown Collective' }).ok,
        'agency creation must not trust a client admin flag')
    local created = service:create(0, {
        key = 'downtown', name = 'Downtown Collective', commissionRate = 1250, members = {}
    })
    check(created.ok and created.metadata and created.metadata.serverAuthoritative, 'console agency creation should succeed')
    check(not service:configure(0, 'downtown', { unknown = true }).ok, 'unknown agency fields must be rejected')
    check(service:optIn(7, 'downtown', { ref = 'worker-1', role = 'MEMBER' }).ok, 'worker opt-in should succeed')
    check(service:member('downtown', 'worker-1').value.optedIn, 'opted-in member should be visible')

    local booking = assert(AgencyBookingService.new({
        agencyService = service,
        bookingService = {},
        workerAvailabilityService = {
            get = function() return Result.ok({ available = true, state = 'AVAILABLE' }) end
        }
    }))
    local offered = booking:route(7, 'downtown', 'worker-1', 'booking-1')
    check(offered.ok and offered.value.status == 'OFFERED', 'agency routing should create an offer')
    local accepted = booking:accept('worker-1', offered.value.routingKey)
    check(accepted.ok and accepted.value.status == 'ACCEPTED'
        and accepted.value.commissionSnapshot.rate == 1250,
        'agency accept must freeze the commission snapshot')
    check(service:optOut(7, 'downtown', 'worker-1').ok, 'worker opt-out should succeed')
    check(not booking:route(7, 'downtown', 'worker-1', 'booking-2').ok,
        'opted-out workers must not receive agency offers')
end

print('NS-230/NS-231 tests passed: agency admin, opt-in membership, routing, and commission snapshots')
