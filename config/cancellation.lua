NightShift = NightShift or {}

NightShift.CancellationConfig = NightShift.CancellationConfig or {
    enabled = true,
    account = 'cash',
    percentages = {
        DRAFT = 100,
        QUOTED = 100,
        OFFERED = 100,
        ACCEPTED = 100,
        SCHEDULED = 100,
        ASSIGNED = 90,
        RESERVED = 90,
        EN_ROUTE = 75,
        TRAVELLING = 75,
        ARRIVED = 50,
        ACTIVE = 0,
        COMPLETED = 0,
        SETTLED = 0
    }
}

NightShift.RefundConfig = NightShift.RefundConfig or NightShift.CancellationConfig
