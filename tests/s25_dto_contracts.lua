local function check(value, message) assert(value, message) end
local redactedValue = 'must-not-leak'
local hiddenValue = 'hidden'

local dto = NightShift.Api and NightShift.Api.Dto
check(type(dto) == 'table', 'S25 DTO surface must be loaded')

do
    local result, resultError = dto.booking({
        id = 42,
        status = 'ACCEPTED',
        mode = 'CLIENT',
        amount = 481,
        currency = 'USD',
        secret = redactedValue,
        worker = {
            publicId = 'npc-42',
            name = 'Alex',
            rating = 4.8,
            token = redactedValue
        },
        location = { id = 'vinewood_hills', label = 'Vinewood Hills', privateNote = 'hidden' }
    })
    check(result and not resultError and result.bookingId == 42 and result.status == 'ACCEPTED', 'booking DTO must preserve safe identity/status')
    check(result.secret == nil and result.worker.token == nil and result.location.privateNote == nil, 'booking DTO must omit sensitive/unknown fields')
    check(result.worker.workerId == 'npc-42' and result.location.locationId == 'vinewood_hills', 'nested DTO IDs must be normalized')
end

do
    local result, resultError = dto.bookingPage({
        items = {
            { bookingId = 1, status = 'COMPLETED', password = hiddenValue }
        },
        pagination = { limit = 20, offset = 0, total = 1 }
    })
    check(result and not resultError and #result.items == 1 and result.limit == 20 and result.items[1].password == nil,
        'booking page DTO must be bounded and safe')
end

do
    local value, errorResult = dto.booking({ id = 1 })
    check(value == nil and errorResult and errorResult.error.code == NightShift.Errors.Codes.API_INVALID,
        'booking DTO must reject missing status')
    value, errorResult = dto.worker({ id = 1, token = redactedValue })
    check(value and not errorResult and value.token == nil, 'worker DTO must omit unknown fields')
end

print('NS-250..NS-252 tests passed: safe public DTOs, nested allowlists, pagination bounds, and validation')
