NightShift = NightShift or {}

local readiness = NightShift.Enums.Readiness
local defaultStages = {
    config = function(context, bootstrap)
        local options = bootstrap and bootstrap.options or {}
        local source = NightShift.DefaultConfig
        if type(context) == 'table' and rawget(context, 'config') ~= nil then
            source = rawget(context, 'config')
        elseif type(options) == 'table' and rawget(options, 'config') ~= nil then
            source = rawget(options, 'config')
        end
        local resolver = options.resolveProvider
        if type(context) == 'table' and rawget(context, 'resolveProvider') ~= nil then
            resolver = rawget(context, 'resolveProvider')
        end
        local normalized, err = NightShift.Validators.validateConfig(source, {
            registry = options.providerRegistry,
            resolveProvider = resolver
        })
        if not normalized then return NightShift.Result.err(err) end
        return { ok = true, config = normalized }
    end
}
for _, stage in ipairs(NightShift.Constants.STAGES) do
    if not defaultStages[stage] then
        defaultStages[stage] = function() return { ok = true, deferred = true } end
    end
end

local function failure(stage, reason)
    if type(reason) == 'table' and reason.code and reason.message then
        local copy = {}
        for key, value in pairs(reason) do copy[key] = value end
        copy.stage = copy.stage or stage
        return copy
    end
    return NightShift.Errors.create(NightShift.Errors.Codes.BOOTSTRAP_STAGE, ('Required stage "%s" failed'):format(stage), {
        stage = stage,
        reason = tostring(reason or 'unknown failure')
    })
end

local Bootstrap = {}
Bootstrap.__index = Bootstrap

function Bootstrap.new(options)
    options = options or {}
    local stageInitializers = options.stages or {}
    local instance = setmetatable({
        readiness = readiness.STARTING,
        error = nil,
        results = {},
        cleanup = {},
        cleanupComplete = false,
        stages = {},
        options = options
    }, Bootstrap)
    for _, stage in ipairs(NightShift.Constants.STAGES) do
        instance.stages[stage] = stageInitializers[stage] or defaultStages[stage]
    end
    instance:registerStopHook()
    return instance
end

function Bootstrap:boot(context)
    if self.readiness == readiness.STOPPED then
        return false, self.error
    end
    self.readiness = readiness.STARTING
    for _, stage in ipairs(NightShift.Constants.STAGES) do
        local initializer = self.stages[stage]
        local ok, result = pcall(initializer, context, self)
        if not ok then
            self.readiness = readiness.FAILED
            self.error = failure(stage, result)
            return false, self.error
        end
        local stageSucceeded = result == true or (type(result) == 'table' and result.ok ~= false and result.success ~= false and (result.ok == true or result.success == true))
        if not stageSucceeded then
            self.readiness = readiness.FAILED
            self.error = failure(stage, type(result) == 'table' and result or 'initializer returned no success result')
            return false, self.error
        end
        self.results[stage] = result
    end
    self.readiness = readiness.READY
    self.error = nil
    return true, self.results
end

function Bootstrap:onCleanup(callback)
    if type(callback) == 'function' and not self.cleanupComplete then
        self.cleanup[#self.cleanup + 1] = callback
    end
    return self
end

function Bootstrap:stop(resourceName)
    if self.cleanupComplete then
        return self.readiness == readiness.STOPPED
    end
    self.cleanupComplete = true
    local cleanupErrors = {}
    for _, callback in ipairs(self.cleanup) do
        local ok, err = pcall(callback, self)
        if not ok then cleanupErrors[#cleanupErrors + 1] = tostring(err) end
    end
    self.readiness = readiness.STOPPED
    if NightShift.Server and NightShift.Server.instance == self then
        NightShift.Server.readiness = self.readiness
        NightShift.Server.error = self.error
    end
    if #cleanupErrors > 0 then
        self.error = NightShift.Errors.create('CLEANUP_FAILED', 'One or more cleanup callbacks failed', {
            resource = resourceName,
            failures = cleanupErrors
        })
    end
    if NightShift.Server and NightShift.Server.instance == self then
        NightShift.Server.readiness = self.readiness
        NightShift.Server.error = self.error
    end
    return true, self.error
end

function Bootstrap:registerStopHook()
    local addEventHandler = rawget(_G, 'AddEventHandler')
    if type(addEventHandler) ~= 'function' then return false end
    local getResourceName = rawget(_G, 'GetCurrentResourceName')
    local ownName = type(getResourceName) == 'function' and getResourceName() or nil
    if ownName == nil then return false end
    addEventHandler('onResourceStop', function(resourceName)
        if resourceName == ownName then self:stop(resourceName) end
    end)
    return true
end

NightShift.ServerBootstrap = Bootstrap
NightShift.Server = NightShift.Server or {}
NightShift.Server.readiness = readiness.STARTING
NightShift.Server.bootstrap = function(options, context)
    local instance = Bootstrap.new(options)
    NightShift.Server.instance = instance
    local ok, result = instance:boot(context)
    NightShift.Server.readiness = instance.readiness
    NightShift.Server.error = instance.error
    return ok, result
end

-- A FiveM resource script executes on load; start the server lifecycle here so
-- `ensure nightshift` cannot leave the resource in STARTING without an
-- explicit external call. Tests and embedders can still create isolated
-- Bootstrap instances through the exported constructor.
if not NightShift.Server.instance then
    NightShift.Server.bootstrap()
end
