NightShift = NightShift or {}

NightShift.Errors = NightShift.Errors or {}

NightShift.Errors.Codes = NightShift.Errors.Codes or {
    VALIDATION = 'VALIDATION_FAILED',
    UNAVAILABLE_CAPABILITY = 'CAPABILITY_UNAVAILABLE',
    BOOTSTRAP_STAGE = 'BOOTSTRAP_STAGE_FAILED',
    INTERNAL = 'INTERNAL_ERROR',
    LIFECYCLE_STOPPED = 'LIFECYCLE_STOPPED'
}

function NightShift.Errors.create(code, message, details)
    return {
        code = code or 'NIGHTSHIFT_ERROR',
        message = message or 'NightShift lifecycle failure',
        details = details
    }
end
