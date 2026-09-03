local Job = NightShift.HeatDecayJob
local Result = NightShift.Result

local function check(condition, message)
    if not condition then error('S20 heat decay job contract failed: ' .. message, 2) end
end

check(type(Job) == 'table' and type(Job.new) == 'function', 'heat decay job must load')

local calls = {}
local job = assert(Job.new({
    heatService = {
        decay = function(_, at)
            calls[#calls + 1] = at
            return Result.ok({ changed = 2, at = at })
        end
    },
    config = { enabled = true, decayIntervalSeconds = 30 },
    clock = { now = function() return 100 end }
}))
local once = job:runOnce()
check(once.ok and once.value.changed == 2 and once.value.at == 100 and calls[1] == 100,
    'runOnce must use the server clock and report service changes')
local explicit = job:runOnce(140)
check(explicit.ok and calls[2] == 140, 'runOnce must accept an explicit diagnostic timestamp')
local started = job:start()
check(not started.ok and started.error.code == NightShift.Errors.Codes.HEAT_OPERATION_FAILED,
    'start must fail clearly when the runtime loop is unavailable')

local disabled = assert(Job.new({
    heatService = { decay = function() return Result.ok({ changed = 0 }) end },
    config = { enabled = false }
}))
local skipped = disabled:runOnce(200)
check(skipped.ok and skipped.value.skipped == true, 'disabled decay must be a safe no-op')

print('S20 heat decay job contracts passed: scheduled interval, clock authority, and safe lifecycle')
