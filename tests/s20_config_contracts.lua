local Validators = NightShift.Validators
local function check(condition, message)
    if not condition then error('S20 config contract failed: ' .. message, 2) end
end

local normalized, err = Validators.validateConfig(NightShift.DefaultConfig)
check(normalized and not err, 'default S20 configuration must validate')
check(normalized.heat and normalized.heat.decayIntervalSeconds == 300,
    'heat interval must survive normalization')
check(normalized.vice and normalized.demandHeatFeedback,
    'vice and demand feedback config must be returned')

local invalidHeat = Validators.copy(NightShift.DefaultConfig)
invalidHeat.heat.decayIntervalSeconds = 0
normalized, err = Validators.validateConfig(invalidHeat)
check(not normalized and err.code == NightShift.Errors.Codes.INVALID_CONFIG,
    'zero heat decay interval must fail fast')

local invalidVice = Validators.copy(NightShift.DefaultConfig)
invalidVice.vice.dispatch = { enabled = true, untrusted = true }
normalized, err = Validators.validateConfig(invalidVice)
check(not normalized and err.code == NightShift.Errors.Codes.INVALID_CONFIG,
    'unknown vice dispatch fields must fail fast')

local invalidFeedback = Validators.copy(NightShift.DefaultConfig)
invalidFeedback.demandHeatFeedback.minMultiplier = 2
invalidFeedback.demandHeatFeedback.maxMultiplier = 1
normalized, err = Validators.validateConfig(invalidFeedback)
check(not normalized and err.code == NightShift.Errors.Codes.INVALID_CONFIG,
    'inverted feedback multipliers must fail fast')

print('S20 config contracts passed: heat/vice/feedback validation and normalization')
