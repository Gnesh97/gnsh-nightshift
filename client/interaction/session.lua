NightShift = NightShift or {}
NightShift.Client = NightShift.Client or {}

local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}

local Session = {}
Session.__index = Session

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maximum)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maximum or 160)
end

local function token(value, maximum)
    return text(value, maximum) and value:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') ~= nil
end

local function invalid(message)
    return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', message)
end

function Session.new(options)
    options = options or {}
    if type(options) ~= 'table' then return nil, invalid('client session options must be a table') end
    if options.startTransport ~= nil and type(options.startTransport) ~= 'function' then return nil, invalid('client session start transport must be a function') end
    if options.completeTransport ~= nil and type(options.completeTransport) ~= 'function' then return nil, invalid('client session completion transport must be a function') end
    return setmetatable({ _startTransport = options.startTransport, _completeTransport = options.completeTransport, _pending = {} }, Session)
end

function Session:_bookingId(value)
    if type(value) == 'number' and value >= 1 and value == math.floor(value) then return tostring(value) end
    return token(value, 160) and tostring(value) or nil
end

function Session:start(bookingId, location)
    local id = self:_bookingId(bookingId)
    if not id then return invalid('client session booking ID is invalid') end
    if location ~= nil and not token(tostring(location), 160) then return invalid('client session location reference is invalid') end
    if type(self._startTransport) ~= 'function' then return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', 'client session start transport is unavailable') end
    local request = { bookingId = id, locationRef = location and tostring(location) or nil }
    local ok, result = pcall(self._startTransport, copy(request))
    if not ok or type(result) ~= 'table' then return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', 'server session start returned an invalid result') end
    if result.ok ~= true then return result end
    local value = result.value
    if type(value) ~= 'table' or not token(value.token or '', 200) or tostring(value.bookingId) ~= id then return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', 'server session start did not return a bound token') end
    self._pending[value.token] = { bookingId = id, locationRef = value.locationRef }
    return Result.ok(copy(value), { serverAuthoritative = true })
end

function Session:complete(sessionToken, bookingId, location)
    if not token(sessionToken or '', 200) then return invalid('client session token is invalid') end
    local id = self:_bookingId(bookingId)
    if not id then return invalid('client session booking ID is invalid') end
    local pending = self._pending[sessionToken]
    if pending and pending.bookingId ~= id then return invalid('client session token is bound to another booking') end
    if location ~= nil and not token(tostring(location), 160) then return invalid('client session location reference is invalid') end
    if type(self._completeTransport) ~= 'function' then return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', 'client session completion transport is unavailable') end
    local request = { token = sessionToken, bookingId = id, locationRef = location and tostring(location) or nil }
    local ok, result = pcall(self._completeTransport, copy(request))
    if not ok or type(result) ~= 'table' then return Result.err(Codes.APPOINTMENT_SESSION_INVALID or 'APPOINTMENT_SESSION_INVALID', 'server session completion returned an invalid result') end
    if result.ok == true then self._pending[sessionToken] = nil end
    return result
end

function Session:clear()
    self._pending = {}
    return Result.ok({ cleared = true })
end

NightShift.ClientAppointmentSession = Session
NightShift.Client.InteractionSession = Session
