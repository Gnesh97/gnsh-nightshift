NightShift = NightShift or {}

NightShift.Errors = NightShift.Errors or {}

function NightShift.Errors.create(code, message, details)
    return {
        code = code or 'NIGHTSHIFT_ERROR',
        message = message or 'NightShift lifecycle failure',
        details = details
    }
end
