NightShift = NightShift or {}

local readiness = NightShift.Enums.Readiness
local Client = {}
Client.__index = Client

function Client.new()
    return setmetatable({ readiness = readiness.STARTING, stopped = false }, Client)
end

function Client:start()
    if not self.stopped then self.readiness = readiness.READY end
    if NightShift.Client and NightShift.Client.instance == self then
        NightShift.Client.readiness = self.readiness
    end
    return self.readiness == readiness.READY
end

function Client:stop()
    self.stopped = true
    self.readiness = readiness.STOPPED
    if NightShift.Client and NightShift.Client.instance == self then
        NightShift.Client.readiness = self.readiness
    end
    return true
end

function Client:registerStopHook()
    local addEventHandler = rawget(_G, 'AddEventHandler')
    if type(addEventHandler) ~= 'function' then return false end
    local getResourceName = rawget(_G, 'GetCurrentResourceName')
    local ownName = type(getResourceName) == 'function' and getResourceName() or nil
    if ownName == nil then return false end
    addEventHandler('onResourceStop', function(resourceName)
        if resourceName == ownName then self:stop() end
    end)
    return true
end

NightShift.ClientBootstrap = Client
NightShift.Client = NightShift.Client or {}
NightShift.Client.instance = Client.new()
NightShift.Client.readiness = readiness.STARTING
NightShift.Client.instance:registerStopHook()
NightShift.Client.instance:start()
