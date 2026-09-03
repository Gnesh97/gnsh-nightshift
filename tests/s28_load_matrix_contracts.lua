local function check(value, message) assert(value, message) end

local Codes = NightShift.Errors.Codes
local Budget = NightShift.NpcStreamingBudgetService
local ScheduledJob = NightShift.ScheduledBookingJob
local Result = NightShift.Result

local logicalProfiles = {}
local budget = assert(Budget.new({
    config = {
        enabled = true, maxActive = 20, maxPerSource = 10,
        maxPerDistrict = 20, maxTracked = 30, leaseSeconds = 120
    },
    clock = { now = function() return 100 end }
}))
local admitted, rejected = 0, 0
for index = 1, 100 do
    logicalProfiles[index] = 'npc-worker:' .. tostring(index)
    if index <= 30 then
        local lease = budget:request(1, logicalProfiles[index], 'vinewood', 100)
        if lease.ok then admitted = admitted + 1
        else rejected = rejected + 1 end
    end
end
check(#logicalProfiles == 100 and admitted == 10 and rejected == 20,
    '100 logical workers must remain separate from the ten physical stream slots')
check(assert(budget:status(100)).value.active == 10,
    'physical NPC admission must stay within the configured global budget')
local blocked = budget:request(1, 'npc-worker:31', 'vinewood', 100)
check(not blocked.ok and blocked.error.code == Codes.NPC_STREAMING_SOURCE_BUDGET_EXHAUSTED,
    'per-source streaming budget must stop additional physical peds')

local dueCalls, activations = 0, 0
local dueRepository = {
    findDueScheduled = function(_, _, options)
        dueCalls = dueCalls + 1
        check(options.limit == 20, 'scheduler matrix must use the configured batch size')
        local rows = {}
        for index = 1, 20 do rows[index] = { id = 'booking:' .. tostring(index), version = 1 } end
        return Result.ok(rows)
    end
}
local bookingService = {
    activateScheduled = function() activations = activations + 1; return Result.ok({ activated = true }) end
}
local scheduler = assert(ScheduledJob.new({
    repository = dueRepository,
    bookingService = bookingService,
    clock = { now = function() return 100 end },
    config = { enabled = true, tickSeconds = 15, batchSize = 20, reservationLeadTimeSeconds = 0 }
}))
local summary = scheduler:runOnce(100)
check(summary.ok and summary.value.scanned == 20 and activations == 20 and dueCalls == 1,
    'scheduler matrix must process one bounded batch without per-booking threads')

print('NS-284 load matrix contracts passed: logical/physical separation, bounded streaming admission, and batch scheduler')
