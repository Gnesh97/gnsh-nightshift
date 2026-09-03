NightShift = NightShift or {}
NightShift.Server = NightShift.Server or {}
local Result = NightShift.Result
local Codes = NightShift.Errors and NightShift.Errors.Codes or {}
local Venue = NightShift.Domain and NightShift.Domain.Venue
local Service = {}; Service.__index = Service
local function clone(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}; if seen[v] then return seen[v] end
    local out = {}; seen[v] = out
    for k, item in pairs(v) do out[clone(k, seen)] = clone(item, seen) end
    return out
end
local function err(code, message, details) return Result.err(code, message, details) end
local function text(v, max) return type(v) == 'string' and #v > 0 and #v <= (max or 160) and v:find('^%s*$') == nil end
local function now(self)
    if self._clock and type(self._clock.now) == 'function' then
        local ok, value = pcall(self._clock.now, self._clock)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return os.time()
end
local function slotKey(venueId, roomId, startAt) return tostring(venueId)..':'..tostring(roomId or '_')..':'..tostring(startAt) end
function Service.new(options)
    options = options or {}
    if type(Venue) ~= 'table' then return nil, err(Codes.INTERNAL or 'INTERNAL_ERROR', 'venue domain is unavailable') end
    local service = setmetatable({
        _repository=options.repository, _clock=options.clock, _venues={}, _slots={}, _desks={},
        _admin = options.adminCheck
    }, Service)
    if options.venues ~= nil then
        if type(options.venues) ~= 'table' then return nil, err(Codes.VALIDATION or 'VALIDATION_FAILED', 'venue definitions must be a table') end
        local definitions = {}
        if #options.venues > 0 then
            for _, definition in ipairs(options.venues) do definitions[#definitions + 1] = definition end
        else
            for _, definition in pairs(options.venues) do definitions[#definitions + 1] = definition end
        end
        for _, definition in ipairs(definitions) do
            local registered = service:register(definition)
            if type(registered) ~= 'table' or registered.ok ~= true then return nil, registered end
        end
    end
    return service
end
function Service:_allowed(source, payload)
    if type(self._admin) == 'function' then
        local ok, allowed = pcall(self._admin, source, clone(payload or {}))
        return ok and allowed == true
    end
    return tonumber(source) == 0 or source == nil
end
function Service:register(values, source)
    if source ~= nil and not self:_allowed(source, values) then return err(Codes.PERMISSION_DENIED or 'PERMISSION_DENIED', 'venue administration is required') end
    local venue, validation = Venue.new(values)
    if not venue then return validation end
    if self._venues[venue.id] then return err(Codes.PROVIDER_CONFLICT or 'PROVIDER_CONFLICT', 'venue already exists') end
    self._venues[venue.id] = venue; return Result.ok(venue:toRow())
end
function Service:get(venueId)
    if not text(venueId, 96) then return err(Codes.VALIDATION or 'VALIDATION_FAILED', 'venue ID is invalid') end
    if not self._venues[venueId] then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    return Result.ok(self._venues[venueId]:toRow())
end
function Service:list(filters)
    filters = type(filters) == 'table' and filters or {}; local out = {}
    for _, venue in pairs(self._venues) do
        if venue.available and (not filters.category or venue.category == filters.category) then out[#out+1] = venue:toRow() end
    end
    table.sort(out, function(a,b) return a.id < b.id end); return Result.ok(out)
end
function Service:setBookingDesk(venueId, desk, source)
    if source ~= nil and not self:_allowed(source, desk) then return err(Codes.PERMISSION_DENIED or 'PERMISSION_DENIED', 'venue administration is required') end
    if not text(venueId, 96) or type(desk) ~= 'table' or not self._venues[venueId] then return err(Codes.VALIDATION or 'VALIDATION_FAILED', 'booking desk is invalid') end
    self._desks[venueId] = clone(desk); return Result.ok({venueId=venueId,configured=true})
end
function Service:getBookingDesk(venueId)
    if not self._venues[venueId] then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    return Result.ok(self._desks[venueId])
end
function Service:isOpen(venueId, at)
    local venue = self._venues[venueId]
    if not venue then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    if venue.available == false then return Result.ok(false) end
    local hours = venue.openingHours; if type(hours) ~= 'table' then return Result.ok(true) end
    local stamp = tonumber(at) or now(self); local day = tonumber(os.date('!%w', stamp)) + 1
    local entry = hours[day] or hours[tostring(day)]; if type(entry) ~= 'table' then return Result.ok(false) end
    local minute = tonumber(os.date('!%H', stamp))*60 + tonumber(os.date('!%M', stamp))
    return Result.ok(minute >= tonumber(entry.open or 0) and minute < tonumber(entry.close or 1440))
end
function Service:reserveSlot(venueId, request)
    request = type(request) == 'table' and request or {}; local venue = self._venues[venueId]
    if not venue then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    local bookingId = request.bookingId or request.booking_id; local startAt = tonumber(request.startAt or request.slotStart); local endAt = tonumber(request.endAt or request.slotEnd); local roomId = request.roomId or request.room_id
    if not text(bookingId, 96) or not startAt or not endAt or endAt <= startAt then return err(Codes.RESERVATION_INVALID or 'RESERVATION_INVALID', 'venue slot request is invalid') end
    if roomId and not venue.rooms[tostring(roomId)] then return err(Codes.LOCATION_NOT_FOUND or 'LOCATION_NOT_FOUND', 'venue room was not found') end
    local k = slotKey(venueId, roomId, startAt); local current = self._slots[k]
    if current and current.bookingId == tostring(bookingId) then return Result.ok(clone(current), {idempotent=true}) end
    if current and current.endAt > now(self) then return err(Codes.RESERVATION_CONFLICT or 'RESERVATION_CONFLICT', 'venue slot is already reserved') end
    for _, existing in pairs(self._slots) do
        if existing.venueId == venueId and tostring(existing.roomId or '') == tostring(roomId or '')
            and existing.status ~= 'RELEASED' and existing.endAt > now(self)
            and endAt > existing.startAt and startAt < existing.endAt then
            return err(Codes.RESERVATION_CONFLICT or 'RESERVATION_CONFLICT', 'venue slot overlaps an existing reservation')
        end
    end
    local entry = {venueId=venueId,roomId=roomId,bookingId=tostring(bookingId),startAt=startAt,endAt=endAt,status='RESERVED',reservedAt=now(self)}
    self._slots[k] = entry; return Result.ok(clone(entry))
end
function Service:releaseSlot(venueId, request)
    request = type(request) == 'table' and request or {}; local bookingId = request.bookingId or request.booking_id
    if not text(venueId, 96) or not self._venues[venueId] then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    local k = request.reservationKey or slotKey(venueId, request.roomId or request.room_id, request.startAt or request.slotStart); local current = self._slots[k]
    if not request.reservationKey and not tonumber(request.startAt or request.slotStart) then return err(Codes.RESERVATION_INVALID or 'RESERVATION_INVALID', 'venue reservation key is required') end
    if not current then return Result.ok({released=false,idempotent=true}) end
    if bookingId and tostring(bookingId) ~= current.bookingId then return err(Codes.RESERVATION_OWNER_MISMATCH or 'RESERVATION_OWNER_MISMATCH', 'venue reservation owner mismatch') end
    self._slots[k] = nil; return Result.ok({released=true,reservationKey=k})
end
function Service:occupySlot(venueId, request)
    request = type(request) == 'table' and request or {}; local k = request.reservationKey or slotKey(venueId, request.roomId or request.room_id, request.startAt or request.slotStart); local current = self._slots[k]
    if not text(venueId, 96) or not self._venues[venueId] then return err(Codes.REPOSITORY_NOT_FOUND or 'REPOSITORY_NOT_FOUND', 'venue was not found') end
    if not request.reservationKey and not tonumber(request.startAt or request.slotStart) then return err(Codes.RESERVATION_INVALID or 'RESERVATION_INVALID', 'venue reservation key is required') end
    if not current then return err(Codes.RESERVATION_INVALID or 'RESERVATION_INVALID', 'venue reservation was not found') end
    if current.venueId ~= venueId or (request.bookingId and current.bookingId ~= tostring(request.bookingId)) then return err(Codes.RESERVATION_OWNER_MISMATCH or 'RESERVATION_OWNER_MISMATCH', 'venue reservation owner mismatch') end
    if current.status == 'OCCUPIED' then return Result.ok(clone(current), {idempotent=true}) end
    local next = clone(current); next.status='OCCUPIED'; self._slots[k]=next; return Result.ok(clone(next))
end
function Service:commission(venueId, amount)
    local venue = self._venues[venueId]; amount=tonumber(amount)
    if not venue or not amount or amount < 0 then return err(Codes.VALIDATION or 'VALIDATION_FAILED', 'commission request is invalid') end
    local rate=venue.commission.rate or 0; local fixed=venue.commission.fixed or 0; local commission=amount*rate/100+fixed
    return Result.ok({venueId=venueId,gross=amount,rate=rate,fixed=fixed,commission=commission,net=amount-commission})
end
NightShift.Server.VenueService = Service
NightShift.VenueService = Service
