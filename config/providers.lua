NightShift = NightShift or {}

-- Provider identifiers are configuration data only. Core code consumes the
-- normalized capability map returned by the selected adapter.
NightShift.ProviderRegistry = NightShift.ProviderRegistry or {
    standalone = { capabilities = {} },
    qbcore = { capabilities = {} },
    qbox = { capabilities = {} },
    esx = { capabilities = {} }
}

NightShift.ProviderModes = { auto = true, explicit = true }
