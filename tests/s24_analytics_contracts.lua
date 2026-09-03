local function check(value, message) assert(value, message) end
local Result = NightShift.Result

local calls = {}
local repository = {}
function repository:bookingSummary(window)
    calls.booking = window
    return Result.ok({
        { status = 'OFFERED', mode = 'CLIENT', count = 4, averageAmountMinor = 100 },
        { status = 'COMPLETED', mode = 'WORKER', count = 2, averageAmountMinor = 200 }
    })
end
function repository:settlementSummary(window)
    calls.settlement = window
    return Result.ok({
        { status = 'SUCCEEDED', count = 5, amountMinor = 5000 },
        { status = 'FAILED', count = 1, amountMinor = 1000 }
    })
end
function repository:travelFailureSummary()
    return Result.ok({ { eventType = 'TRAVEL_FAILED', count = 3 } })
end
function repository:demandSummary()
    return Result.ok({
        { district = 'vinewood', count = 7 },
        { district = 'vespucci', count = 2 }
    })
end

local service = assert(NightShift.AnalyticsService.new({
    repository = repository,
    clock = { now = function() return 200 end, timestamp = function(_, epoch) return tostring(epoch) end }
}))
local summary = service:summary({ from = 100, to = 200 })
check(summary.ok and summary.value.totalBookings == 6, 'analytics should count bounded bookings')
check(summary.value.byStatus.OFFERED == 4 and summary.value.byStatus.COMPLETED == 2
    and summary.value.byMode.CLIENT == 4 and summary.value.byMode.WORKER == 2,
    'analytics should group bookings by status and mode')
check(summary.value.averageAgreedPriceMinor > 133 and summary.value.averageAgreedPriceMinor < 134,
    'analytics should calculate weighted average price')
check(summary.value.conversion == 0.5 and summary.value.settlementFailures == 1
    and summary.value.travelFailures == 3,
    'analytics should expose conversion and failure KPIs')
check(summary.value.demandByDistrict.vinewood == 7 and summary.value.demandByDistrict.vespucci == 2,
    'analytics should expose demand by district')
check(summary.value.gameplayAuthority == false and summary.metadata.bounded == true,
    'analytics must be non-authoritative and bounded')
check(calls.booking.from == 100 and calls.booking.to == 200,
    'analytics repository must receive the bounded window')
check(not service:summary({ from = 0, to = 7776001 }).ok,
    'analytics must reject windows larger than ninety days')

print('NS-241 tests passed: bounded booking, price, conversion, demand, travel, and settlement KPIs')
