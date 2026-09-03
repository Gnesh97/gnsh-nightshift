NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}

local Result = NightShift.Result

local function finite(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge
end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, item in pairs(value) do out[copy(key, seen)] = copy(item, seen) end
    return out
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local Heat = {}
Heat.__index = Heat

function Heat.new(options)
    options = options or {}
    local minimum = tonumber(options.min) or 0
    local maximum = tonumber(options.max) or 100
    if not finite(minimum) or not finite(maximum) or minimum < 0 or maximum <= minimum then
        return nil, Result.err('HEAT_INVALID', 'heat bounds are invalid')
    end
    return setmetatable({ min = minimum, max = maximum }, Heat)
end

function Heat:apply(current, increments)
    current, increments = current or {}, increments or {}
    if type(current) ~= 'table' or type(increments) ~= 'table' then
        return Result.err('HEAT_INVALID', 'heat values must be tables')
    end
    local player = current.playerHeat
    if player ~= nil or increments.player ~= nil then
        player = clamp((tonumber(player) or 0) + (tonumber(increments.player) or 0), self.min, self.max)
    end
    local district = clamp((tonumber(current.districtPressure) or 0) + (tonumber(increments.district) or 0), self.min, self.max)
    local value = { playerHeat = player, districtPressure = district, updatedAt = increments.updatedAt or current.updatedAt }
    return Result.ok(value)
end

function Heat:decay(current, elapsedSeconds, rates)
    current, rates = current or {}, rates or {}
    elapsedSeconds = tonumber(elapsedSeconds)
    if not finite(elapsedSeconds) or elapsedSeconds < 0 then return Result.err('HEAT_INVALID', 'elapsed time is invalid') end
    local intervals = math.floor(elapsedSeconds / math.max(1, tonumber(rates.intervalSeconds) or 1))
    local player = current.playerHeat
    if player ~= nil then player = clamp(player - intervals * (tonumber(rates.player) or 0), self.min, self.max) end
    local district = clamp((tonumber(current.districtPressure) or 0) - intervals * (tonumber(rates.district) or 0), self.min, self.max)
    return Result.ok({ playerHeat = player, districtPressure = district, updatedAt = current.updatedAt })
end

function Heat:clamp(value) return clamp(value, self.min, self.max) end
function Heat:copy(value) return copy(value) end

NightShift.Heat = Heat
NightShift.Domain.Heat = Heat
