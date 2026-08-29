NightShift = NightShift or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.Booking

local StateMachine = {}
StateMachine.__index = StateMachine

local transitions = {
    DRAFT = { QUOTED = true, CANCELLED = true, EXPIRED = true },
    QUOTED = { OFFERED = true, CANCELLED = true, EXPIRED = true },
    OFFERED = { ACCEPTED = true, DECLINED = true, CANCELLED = true, EXPIRED = true },
    ACCEPTED = { RESERVED = true, CANCELLED = true, EXPIRED = true },
    RESERVED = { TRAVELLING = true, CANCELLED = true, INTERRUPTED = true },
    TRAVELLING = { ARRIVED = true, CANCELLED = true, INTERRUPTED = true, EXPIRED = true },
    ARRIVED = { ACTIVE = true, CANCELLED = true, INTERRUPTED = true },
    ACTIVE = { COMPLETED = true, CANCELLED = true, INTERRUPTED = true },
    COMPLETED = { SETTLED = true },
    SETTLED = {},
    DECLINED = {},
    CANCELLED = {},
    EXPIRED = {},
    INTERRUPTED = {}
}

local terminal = { SETTLED = true, DECLINED = true, CANCELLED = true, EXPIRED = true, INTERRUPTED = true }

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, item in pairs(value) do output[copy(key, seen)] = copy(item, seen) end
    return output
end

local function text(value, maxLength)
    return type(value) == 'string' and value:match('%S') ~= nil and #value <= (maxLength or 160)
end

local function invalid(message, details)
    return Result.err(Codes.BOOKING_TRANSITION_INVALID, message, details)
end

local function normalizeMetadata(metadata)
    if metadata == nil then return {} end
    if type(metadata) ~= 'table' then return nil, invalid('transition metadata must be a table') end
    local output = {}
    local allowed = { actorType = true, actorRef = true, reason = true, correlationId = true, eventKey = true, details = true }
    for key, value in pairs(metadata) do
        if not allowed[key] then return nil, invalid('transition metadata field is not allowlisted', { field = tostring(key) }) end
        if key ~= 'details' and value ~= nil and not text(value, key == 'correlationId' and 96 or 160) then
            return nil, invalid('transition metadata value is invalid', { field = key })
        end
        if key == 'details' and value ~= nil and type(value) ~= 'table' and not text(value, 512) then
            return nil, invalid('transition metadata details are invalid', { field = key })
        end
        output[key] = copy(value)
    end
    return output
end

function StateMachine.new(options)
    options = options or {}
    local custom = options.transitions
    if custom ~= nil and type(custom) ~= 'table' then return nil, invalid('state transitions must be a table') end
    return setmetatable({
        _transitions = custom or transitions,
        _guards = type(options.guards) == 'table' and options.guards or {}
    }, StateMachine)
end

function StateMachine:canTransition(from, to, context)
    from = type(from) == 'string' and from:upper() or from
    to = type(to) == 'string' and to:upper() or to
    if not Domain.statuses[from] or not Domain.statuses[to] then
        return Result.err(Codes.BOOKING_STATE_INVALID, 'booking state is unknown', { from = from, to = to })
    end
    if terminal[from] then
        return Result.err(Codes.BOOKING_STATE_INVALID, 'terminal booking state cannot transition', { from = from, to = to })
    end
    if not (self._transitions[from] and self._transitions[from][to]) then
        return Result.err(Codes.BOOKING_TRANSITION_INVALID, 'booking state transition is not allowed', { from = from, to = to })
    end
    local guard = self._guards[from .. '->' .. to] or self._guards[to]
    if type(guard) == 'function' then
        local ok, allowed = pcall(guard, context)
        if not ok then return Result.err(Codes.BOOKING_GUARD_FAILED, 'booking transition guard failed', { from = from, to = to }) end
        if type(allowed) == 'table' and allowed.ok == false then return allowed end
        if allowed ~= true and not (type(allowed) == 'table' and allowed.allowed == true) then
            return Result.err(Codes.BOOKING_GUARD_FAILED, 'booking transition guard rejected the operation', { from = from, to = to })
        end
    end
    return Result.ok({ allowed = true, from = from, to = to })
end

function StateMachine:transition(booking, to, metadata)
    local current, bookingError = Domain.new(booking)
    if not current then return bookingError end
    local normalizedMetadata, metadataError = normalizeMetadata(metadata)
    if not normalizedMetadata then return metadataError end
    local check = self:canTransition(current.status, to, {
        booking = copy(current),
        metadata = copy(normalizedMetadata)
    })
    if not check.ok then return check end
    local nextBooking = copy(current)
    nextBooking.status = to:upper()
    nextBooking.version = current.version + 1
    return Result.ok({
        booking = nextBooking,
        from = current.status,
        to = nextBooking.status,
        metadata = normalizedMetadata
    }, { from = current.status, to = nextBooking.status, version = nextBooking.version })
end

function StateMachine:isTerminal(status)
    return terminal[type(status) == 'string' and status:upper() or status] == true
end

StateMachine.transitions = copy(transitions)
StateMachine.terminalStates = copy(terminal)
NightShift.BookingStateMachine = StateMachine
NightShift.State = NightShift.State or {}
NightShift.State.Booking = StateMachine
