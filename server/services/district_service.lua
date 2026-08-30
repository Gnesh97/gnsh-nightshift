NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}

local Result = NightShift.Result
local Codes = NightShift.Errors.Codes
local Domain = NightShift.Domain.District

local Service = {}
Service.__index = Service

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

local function invalid(message, details)
    return Result.err(Codes.DISTRICT_INVALID, message, details)
end

local function notFound(id)
    return Result.err(Codes.DISTRICT_NOT_FOUND, 'district was not found', { district = id })
end

local function unavailable(id)
    return Result.err(Codes.DISTRICT_UNAVAILABLE, 'district is unavailable', { district = id })
end

local function definitions(config)
    if type(config) ~= 'table' then return nil end
    local raw = config.districts or config.profiles
    if raw ~= nil then return raw end
    if config.id or config.districtId or config.key then return { config } end
    return config
end

function Service.new(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return nil, invalid('district service options must be a table') end
    local config = options.config or options.demandConfig or NightShift.DemandConfig or {}
    local raw = options.districts or definitions(config) or {}
    if type(raw) ~= 'table' then return nil, invalid('district definitions must be a table') end
    local byId = {}
    local count = 0
    if #raw > 0 then
        for _, value in ipairs(raw) do
            local district, errorResult = Domain.new(value)
            if not district then return nil, errorResult end
            if byId[district.id] then return nil, invalid('duplicate district ID', { district = district.id }) end
            byId[district.id] = district
            count = count + 1
        end
    else
        for key, value in pairs(raw) do
            local source = copy(value)
            if type(source) ~= 'table' then return nil, invalid('district profile must be a table', { district = key }) end
            source.id = source.id or source.districtId or source.key or key
            local district, errorResult = Domain.new(source)
            if not district then return nil, errorResult end
            if byId[district.id] then return nil, invalid('duplicate district ID', { district = district.id }) end
            byId[district.id] = district
            count = count + 1
        end
    end
    local defaultDistrict = options.defaultDistrict or config.defaultDistrict
    if defaultDistrict ~= nil then
        defaultDistrict = tostring(defaultDistrict):lower()
        if not token(defaultDistrict, 64) then return nil, invalid('default district is invalid') end
        if byId[defaultDistrict] == nil then return nil, invalid('default district is not configured', { district = defaultDistrict }) end
    elseif count > 0 then
        local ids = {}
        for id in pairs(byId) do ids[#ids + 1] = id end
        table.sort(ids)
        defaultDistrict = ids[1]
    end
    return setmetatable({
        _districts = byId,
        _defaultDistrict = defaultDistrict,
        _clock = options.clock
    }, Service)
end

function Service:get(districtRef)
    if districtRef == nil then districtRef = self._defaultDistrict end
    if not text(tostring(districtRef), 64) then return nil end
    local district = self._districts[tostring(districtRef):lower()]
    return district and district:copy() or nil
end

function Service:resolve(districtRef, options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return invalid('district resolve options must be a table') end
    local district = self:get(districtRef)
    if not district then return notFound(districtRef) end
    if district.available ~= true and options.allowUnavailable ~= true then return unavailable(district.id) end
    if options.zone ~= nil and not district:isZoneAllowed(options.zone) then
        return Result.err(Codes.DISTRICT_ZONE_NOT_ALLOWED, 'district does not allow the requested discovery zone', { district = district.id, zone = options.zone })
    end
    return Result.ok(district)
end

function Service:isEligible(request)
    if type(request) == 'string' then request = { district = request } end
    if type(request) ~= 'table' then return invalid('district eligibility request must be a table') end
    local districtRef = request.district or request.districtId or request.district_id or request.id
    return self:resolve(districtRef, { zone = request.zone or request.discoveryZone })
end

function Service:list(options)
    if options == nil then options = {} end
    if type(options) ~= 'table' then return invalid('district list options must be a table') end
    local output = {}
    for _, district in pairs(self._districts) do
        if options.available ~= true or district.available then output[#output + 1] = district:copy() end
    end
    table.sort(output, function(left, right) return left.id < right.id end)
    return Result.ok(output, { count = #output })
end

function Service:default()
    return self:get(self._defaultDistrict)
end

function Service:defaultId()
    return self._defaultDistrict
end

function Service:count()
    local count = 0
    for _ in pairs(self._districts) do count = count + 1 end
    return count
end

function Service:configuration()
    local districts = {}
    for id, district in pairs(self._districts) do districts[id] = district:toConfig() end
    return { defaultDistrict = self._defaultDistrict, districts = districts }
end

Service.getDistrict = Service.get
Service.resolveDistrict = Service.resolve
Service.isAllowed = Service.isEligible

NightShift.DistrictService = Service
NightShift.Services.District = Service
