local ViceService = NightShift.ViceService
local Result = NightShift.Result

local function check(condition, message)
    if not condition then error(message, 2) end
end

check(type(ViceService) == 'table' and type(ViceService.new) == 'function', 'vice service must load')

local dispatched
local heat = {
    get = function(_, request)
        return Result.ok({ districtPressure = request.district == 'vinewood' and 72 or 0 })
    end
}
local service = assert(ViceService.new({
    config = {
        enabled = true, riskThreshold = 60, dispatchThreshold = 70,
        districtPressureWeight = 0.5, archetypeWeight = 0.3, bookingWeight = 0.2,
        dispatch = { enabled = true, requireThreshold = true }
    },
    heatService = heat,
    dispatch = { emitViceAlert = function(_, payload) dispatched = payload; return Result.ok({ sent = true }) end }
}))

local assessed = service:evaluate({
    booking = { id = 9, meetingMode = 'STREET', servicePackage = 'standard', amount = 500 },
    district = 'vinewood',
    npc = { riskArchetype = 'AGGRESSIVE' }
})
check(assessed.ok and assessed.value.triggered == true, 'high pressure booking must trigger vice risk')
check(assessed.value.score >= 60 and assessed.value.reason and #assessed.value.reason.codes > 0, 'vice result must expose explainable reason')
check(assessed.value.dispatch.emitted == true and dispatched and dispatched.bookingId == '9', 'dispatch must emit only after configured threshold')

local quiet = service:evaluate({
    booking = { id = 10, meetingMode = 'PRIVATE', amount = 100 },
    district = 'vespucci',
    districtPressure = 2,
    npc = { riskArchetype = 'LOW' }
})
check(quiet.ok and quiet.value.triggered == false and quiet.value.dispatch.skipped == true, 'low risk must not dispatch')

local invalid = service:evaluate({ district = 'vinewood', npc = { riskArchetype = 'UNKNOWN' } })
check(not invalid.ok and invalid.error.code == NightShift.Errors.Codes.VICE_INVALID, 'invalid archetype must fail closed')

local disabled = assert(ViceService.new({ config = { enabled = false } }))
check(not disabled:evaluate({ district = 'vinewood' }).ok, 'disabled vice must fail closed')

print('NS-201 vice contracts passed: bounded explainable risk and conditional dispatch')
