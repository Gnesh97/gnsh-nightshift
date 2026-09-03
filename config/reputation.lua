NightShift = NightShift or {}

-- Reputation is deliberately bounded and event-driven. These values are
-- defaults only; providers may supply a validated override at bootstrap.
NightShift.ReputationConfig = {
    enabled = true,
    min = 0,
    max = 100,
    initial = 50,
    regularThreshold = 3,
    worker = {
        completion = 2,
        cancellation = -1,
        noShow = -12,
        paymentReliability = 1
    },
    client = {
        completion = 2,
        cancellation = -1,
        noShow = -12,
        paymentReliability = 1
    },
    review = {
        minimum = 1,
        maximum = 5,
        textMaxLength = 1000
    },
    favorite = {
        persistentOnly = true
    },
    relationship = {
        regularThreshold = 3,
        trustPerSettled = 10,
        trustPerCancelled = 0
    }
}
