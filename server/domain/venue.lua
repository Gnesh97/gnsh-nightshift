NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}
local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}
local Venue = {}; Venue.__index = Venue
local function clone(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}; if seen[v] then return seen[v] end
    local out = {}; seen[v] = out
    for k, item in pairs(v) do out[clone(k, seen)] = clone(item, seen) end
    return out
end
local function invalid(message, details) return Result.err(Codes.VALIDATION or 'VALIDATION_FAILED', message, details) end
local function text(v, max) return type(v) == 'string' and #v > 0 and #v <= (max or 160) and v:find('^%s*$') == nil end
local function positive(v) v = tonumber(v); return v and v >= 1 and v == math.floor(v) and v end
function Venue.new(values)
    if type(values) ~= 'table' then return nil, invalid('venue values must be a table') end
    local id = values.id or values.venueId or values.venue_id
    if not text(id, 96) then return nil, invalid('venue ID is invalid') end
    local capacity = positive(values.capacity or 1)
    if not capacity or capacity > 10000 then return nil, invalid('venue capacity is invalid') end
    if values.rooms ~= nil and type(values.rooms) ~= 'table' then return nil, invalid('venue rooms must be a table') end
    if values.openingHours ~= nil and type(values.openingHours) ~= 'table' then return nil, invalid('venue opening hours must be a table') end
    if values.bookingDesk ~= nil and type(values.bookingDesk) ~= 'table' then return nil, invalid('venue booking desk must be a table') end
    if values.metadata ~= nil and type(values.metadata) ~= 'table' then return nil, invalid('venue metadata must be a table') end
    local rooms = {}
    for key, raw in pairs(values.rooms or {}) do
        if type(raw) ~= 'table' then return nil, invalid('venue room must be a table') end
        local roomId = raw.id or raw.roomId or key
        local roomCapacity = positive(raw.capacity or capacity)
        if not text(roomId, 96) or not roomCapacity or roomCapacity > capacity then return nil, invalid('venue room is invalid') end
        if raw.openingHours ~= nil and type(raw.openingHours) ~= 'table' then return nil, invalid('venue room opening hours must be a table') end
        if raw.available ~= nil and type(raw.available) ~= 'boolean' then return nil, invalid('venue room availability must be boolean') end
        rooms[tostring(roomId)] = { id=tostring(roomId), name=raw.name, capacity=roomCapacity, openingHours=clone(raw.openingHours), available=raw.available ~= false }
    end
    local commission = values.commission or {}
    if type(commission) ~= 'table' then return nil, invalid('venue commission is invalid') end
    local rate = commission.rate == nil and 0 or tonumber(commission.rate)
    local fixed = commission.fixed == nil and 0 or tonumber(commission.fixed)
    if not rate or rate < 0 or rate > 100 or not fixed or fixed < 0 then return nil, invalid('venue commission is invalid') end
    if values.available ~= nil and type(values.available) ~= 'boolean' then return nil, invalid('venue availability must be boolean') end
    return setmetatable({ id=tostring(id), name=values.name, category=values.category or 'VENUE', capacity=capacity, rooms=rooms, openingHours=clone(values.openingHours), commission={rate=rate, fixed=fixed}, bookingDesk=clone(values.bookingDesk), available=values.available ~= false, metadata=clone(values.metadata) }, Venue)
end
function Venue:copy() return Venue.new(clone(self)) end
function Venue:validate() return true end
function Venue:room(roomId) return roomId and clone(self.rooms[tostring(roomId)]) or nil end
function Venue:toRow() return clone({id=self.id,name=self.name,category=self.category,capacity=self.capacity,rooms=self.rooms,openingHours=self.openingHours,commission=self.commission,available=self.available,metadata=self.metadata}) end
NightShift.Domain.Venue = Venue
