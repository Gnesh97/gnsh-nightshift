NightShift = NightShift or {}
NightShift.Client = NightShift.Client or {}
local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}
local Session = {}
Session.__index = Session

local function validId(value)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return tostring(value) end
    if type(value) == 'string' and value:match('^[A-Za-z0-9_.:%-]+$') and #value <= 160 then return value end
end

function Session.new(options)
    options = options or {}
    if type(options.checkInTransport) ~= 'function' or type(options.helpTransport) ~= 'function' or type(options.endTransport) ~= 'function' then
        return nil, Result.err(Codes.SAFETY_INVALID or 'SAFETY_INVALID', 'safety client transports are required')
    end
    return setmetatable({ _checkIn = options.checkInTransport, _help = options.helpTransport, _end = options.endTransport, _active = {} }, Session)
end

function Session:checkIn(bookingId)
    local id = validId(bookingId)
    if not id then return Result.err(Codes.SAFETY_INVALID or 'SAFETY_INVALID', 'safety booking ID is invalid') end
    local ok, result = pcall(self._checkIn, { bookingId = id })
    if not ok or type(result) ~= 'table' then return Result.err(Codes.SAFETY_OPERATION_FAILED or 'SAFETY_OPERATION_FAILED', 'safety check-in transport failed') end
    if result.ok == true then self._active[id] = true end
    return result
end

function Session:imOkay(bookingId)
    return self:checkIn(bookingId)
end

function Session:requestHelp(bookingId, reason)
    local id = validId(bookingId)
    if not id or (reason ~= nil and (type(reason) ~= 'string' or #reason > 160)) then return Result.err(Codes.SAFETY_INVALID or 'SAFETY_INVALID', 'safety help request is invalid') end
    local ok, result = pcall(self._help, { bookingId = id, reason = reason })
    if not ok or type(result) ~= 'table' then return Result.err(Codes.SAFETY_OPERATION_FAILED or 'SAFETY_OPERATION_FAILED', 'safety help transport failed') end
    return result
end

function Session:requestEnd(bookingId)
    local id = validId(bookingId)
    if not id then return Result.err(Codes.SAFETY_INVALID or 'SAFETY_INVALID', 'safety booking ID is invalid') end
    local ok, result = pcall(self._end, { bookingId = id })
    if not ok or type(result) ~= 'table' then return Result.err(Codes.SAFETY_OPERATION_FAILED or 'SAFETY_OPERATION_FAILED', 'safety end transport failed') end
    return result
end

NightShift.ClientSafetySession = Session
NightShift.Client.SafetySession = Session
