NightShift = NightShift or {}

-- Scheduling is enabled by default. The jobs are single batch loops and only
-- start when persistence has supplied a booking repository.
NightShift.SchedulingConfig = NightShift.SchedulingConfig or {
    enabled = true,
    tickSeconds = 15,
    batchSize = 50,
    reservationLeadTimeSeconds = 300,
    noShowGraceSeconds = 300,
    conflictBufferSeconds = 60,
    defaultDurationSeconds = 1800
}
