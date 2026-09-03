local function check(condition, message)
    if not condition then error('S20 NS-202 contract failed: ' .. message) end
end

local Feedback = NightShift.DemandHeatFeedbackService
check(type(Feedback) == 'table' and type(Feedback.new) == 'function', 'feedback service must be loaded')

local service = assert(Feedback.new({
    config = {
        enabled = true,
        streetPressureThreshold = 60,
        streetOpportunityPenalty = 0.8,
        privateAvailabilityModifier = 0.5,
        pricingDemandWeight = 0.2,
        pricingHeatWeight = 0.2,
        pricingOversupplyPenalty = 0.3,
        minMultiplier = 0.25,
        maxMultiplier = 1.75
    }
}))

local high = service:apply({
    heat = 100,
    demandScore = 90,
    activeWorkers = 12,
    supplyCapacity = 6
})
check(high.ok and high.value.streetOpportunityMultiplier < 0.6, 'high pressure must reduce street opportunity')
check(high.value.privateBookingAvailabilityModifier > 1, 'high pressure must increase private availability')
check(high.value.pricingModifier <= 1.75, 'pricing modifier must be bounded')
check(high.value.explanation and high.value.explanation.heatPressure, 'feedback must be explainable')

local oversupply = service:apply({
    heat = 0,
    demandScore = 50,
    activeWorkers = 20,
    supplyCapacity = 5
})
check(oversupply.ok and oversupply.value.pricingModifier < 1, 'oversupply must reduce pricing modifier')

local recovery = service:apply({ heat = 10, demandScore = 50, activeWorkers = 1, supplyCapacity = 5 })
check(recovery.ok and recovery.value.streetOpportunityMultiplier == 1, 'low pressure must recover street opportunity')
check(recovery.value.privateBookingAvailabilityModifier >= 1, 'private modifier must remain stable after decay')

local bounded = assert(Feedback.new({ config = { enabled = true, minMultiplier = 0.5, maxMultiplier = 1.2 } }))
local extreme = bounded:apply({ heat = 999, demandScore = -999, activeWorkers = 999999, supplyCapacity = 1 })
check(extreme.ok and extreme.value.streetOpportunityMultiplier >= 0.5 and extreme.value.pricingModifier <= 1.2,
    'extreme feedback must clamp without runaway')

local disabled = assert(Feedback.new({ config = { enabled = false } }))
local unavailable = disabled:apply({ heat = 100, demandScore = 100, activeWorkers = 1, supplyCapacity = 1 })
check(not unavailable.ok and unavailable.code == NightShift.Errors.Codes.DEMAND_UNAVAILABLE,
    'disabled feedback must fail closed')

local Demand = NightShift.DemandService
local Districts = NightShift.DistrictService
local districts = assert(Districts.new({
    districts = {
        { id = 'vinewood', baseline = 65, maxActiveCustomers = 8, available = true }
    },
    defaultDistrict = 'vinewood'
}))
local demand = assert(Demand.new({
    districtService = districts,
    feedbackService = service,
    config = { enabled = true, districts = {}, min = 0, max = 100 }
}))
local evaluated = demand:evaluate({
    district = 'vinewood',
    heat = 90,
    demandScore = 80,
    activeWorkers = 2,
    supplyCapacity = 8,
    hour = 20,
    day = 5
})
check(evaluated.ok and evaluated.value.feedback and evaluated.value.factors.feedback,
    'demand evaluation must expose optional feedback modifiers')

local Pricing = NightShift.PricingService
local quoteService = assert(Pricing.new({
    catalog = {
        resolve = function(_, id)
            return NightShift.Result.ok({ id = id, basePriceMinor = 100, durationMinutes = 30, currency = 'USD' })
        end
    },
    config = {
        enabled = true, currency = 'USD', quoteTtlSeconds = 300,
        minAmountMinor = 1, maxAmountMinor = 100000,
        npcPriceClasses = {}, districtModifiers = {}, timeModifiers = {},
        demandModifiers = {}, reputationModifiers = {}, fees = {}
    },
    pricingModifierResolver = function() return 1.5 end
}))
local feedbackQuote = quoteService:quote({ servicePackageId = 'standard', district = 'vinewood' })
check(feedbackQuote.ok and feedbackQuote.value.amountMinor == 150, 'feedback pricing modifier must reach authoritative quotes')
local hasFeedbackLine = false
for _, item in ipairs(feedbackQuote.value.lineItems or {}) do
    if item.key == 'demandHeatFeedback' then hasFeedbackLine = true end
end
check(hasFeedbackLine, 'authoritative quote must explain feedback pricing')

print('NS-202 tests passed: bounded demand/heat feedback, oversupply pricing, and recovery')
