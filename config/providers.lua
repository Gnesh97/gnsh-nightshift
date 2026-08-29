NightShift = NightShift or {}

-- Provider identifiers are configuration data only. Core code consumes the
-- normalized capability map returned by the selected adapter.
NightShift.ProviderRegistry = NightShift.ProviderRegistry or {
    standalone = { capabilities = { identity = true, availability = true, standalone = true } },
    qbcore = { capabilities = { identity = true, characterId = true, job = true, grade = true, duty = true, lifecycle = true, money = true } },
    qbox = { capabilities = { identity = true, characterId = true, job = true, grade = true, duty = true, lifecycle = true, money = true, qboxNative = true } },
    esx = { capabilities = { identity = true, characterId = true, job = true, grade = true, internalDuty = true, lifecycle = true, money = true } }
}

NightShift.ProviderModes = { auto = true, explicit = true }
