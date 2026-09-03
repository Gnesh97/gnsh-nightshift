local function check(value, message) assert(value, message) end
local Result = NightShift.Result
local redactedValue = 'must-not-persist'

local rows, queryOptions = {}, nil
local repository = {}
function repository:create(value)
    rows[#rows + 1] = NightShift.Validators.copy(value)
    return Result.ok({ insertId = #rows })
end
function repository:findRecent(options)
    queryOptions = NightShift.Validators.copy(options)
    return Result.ok(NightShift.Validators.copy(rows))
end

local service = assert(NightShift.AuditService.new({
    repository = repository,
    clock = { timestamp = function() return '2026-09-02T12:00:00Z' end },
    metadataBudget = 64
}))
local recorded = service:record({
    actor = { source = 7, actorType = 'PLAYER', ref = 'player:7' },
    action = 'admin.override',
    target = { type = 'BOOKING', ref = 'booking:1' },
    result = Result.ok({ applied = true }),
    reason = 'approved support action',
    correlationId = 'corr-1',
    metadata = {
        safe = 'visible',
        token = redactedValue,
        nested = { password = redactedValue, accessToken = redactedValue, count = 2 }
    }
})
check(recorded.ok and #rows == 1, 'audit event should be appended')
check(rows[1].actorSource == 7 and rows[1].action == 'admin.override'
    and rows[1].resultStatus == 'OK' and rows[1].occurredAt == '2026-09-02T12:00:00Z',
    'audit actor/action/result/timestamp should be normalized')
check(rows[1].metadata.safe == 'visible' and rows[1].metadata.token == nil
    and rows[1].metadata.nested.password == nil and rows[1].metadata.nested.accessToken == nil,
    'audit metadata must redact sensitive keys')
check(not service:record({ action = ' ', result = Result.ok({}) }).ok,
    'audit action must be required')
check(not service:record({ action = 'audit.invalid', actor = { source = 0 }, result = Result.ok({}) }).ok,
    'audit actor source must be a player source')
local listed = service:list({ limit = 5, offset = 2 })
check(listed.ok and queryOptions.limit == 5 and queryOptions.offset == 2,
    'audit listing should preserve bounded pagination')
check(service:record({
    action = 'permission.check', target = { type = 'PERMISSION', ref = 'admin.manage' },
    result = Result.err(NightShift.Errors.Codes.PERMISSION_DENIED, 'denied')
}).ok and rows[2].resultStatus == 'ERROR',
    'permission denial should be representable as an error audit event')

print('NS-240 tests passed: typed audit events, redaction, correlation, and bounded listing')
