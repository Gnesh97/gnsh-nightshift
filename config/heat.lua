NightShift = NightShift or {}

NightShift.HeatConfig = NightShift.HeatConfig or {
    enabled = true,
    playerEnabled = true,
    min = 0,
    max = 100,
    playerIncrement = 5,
    districtIncrement = 5,
    decayIntervalSeconds = 300,
    playerDecay = 2,
    districtDecay = 3,
    maxEventKeys = 2048,
    eventIncrements = {}
}

NightShift.Heat = NightShift.Heat or NightShift.HeatConfig
