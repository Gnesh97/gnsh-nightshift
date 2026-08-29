NightShift = NightShift or {}

-- Result is a runtime-neutral envelope. The server has its own implementation;
-- this small client copy keeps NPC controllers usable without server scripts.
local existing = NightShift.Result
if type(existing) == 'table' and type(existing.ok) == 'function' and type(existing.err) == 'function' then
    return
end

local Result = existing or {}

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
    local safeValue = copy(value)
    return {
        ok = true,
        success = true,
        value = safeValue,
        data = copy(safeValue),
        metadata = copy(metadata)
    }
end

function Result.err(code, message, details, metadata)
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
