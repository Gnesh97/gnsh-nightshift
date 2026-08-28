NightShift = NightShift or {}

local Clock = NightShift.Clock or {}

local function epochNow() return os.time() end

function Clock.utcTimestamp(epoch)
    epoch = tonumber(epoch) or epochNow()
    return os.date('!%Y-%m-%dT%H:%M:%SZ', epoch)
end

function Clock.new(options)
    options = options or {}
    local now = type(options.now) == 'function' and options.now or epochNow
    return setmetatable({ _now = now }, { __index = Clock })
end

function Clock:now()
    local ok, value = pcall(self._now)
    if ok and tonumber(value) then return tonumber(value) end
    return epochNow()
end

function Clock:timestamp()
    return Clock.utcTimestamp(self:now())
end

NightShift.Clock = Clock
