NightShift = NightShift or {}

-- Constants are treated as immutable by convention by all resource modules.
NightShift.Constants = NightShift.Constants or {
    RESOURCE_VERSION = '0.1.0',
    STAGES = {
        'config',
        'db',
        'adapters',
        'repositories',
        'services',
        'jobs'
    }
}
