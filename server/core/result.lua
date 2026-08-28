NightShift = NightShift or {}

local Result = NightShift.Result or {}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

function Result.ok(value, metadata)
    return {
        ok = true,
        success = true,
        value = value,
        data = value,
        metadata = copy(metadata)
    }
end

function Result.err(code, message, details, metadata)
    if type(code) == 'table' then
        local source = code
        return Result.err(source.code, source.message, source.details, source.metadata or source.meta)
    end
    return {
        ok = false,
        success = false,
        error = {
            code = code or 'NIGHTSHIFT_ERROR',
            message = message or 'NightShift operation failed',
            details = copy(details)
        },
        code = code or 'NIGHTSHIFT_ERROR',
        message = message or 'NightShift operation failed',
        details = copy(details),
        metadata = copy(metadata)
    }
end

function Result.isOk(result) return type(result) == 'table' and result.ok == true end
function Result.isErr(result) return type(result) == 'table' and result.ok == false end

NightShift.Result = Result
