NightShift = NightShift or {}
NightShift.OptionalProviders = NightShift.OptionalProviders or {}

local Base = NightShift.ProviderBase
local Result = NightShift.Result
local Codes = NightShift.Errors.Codes

local Appearance = {}

function Appearance.new(options)
    options = options or {}
    local adapter = Base.new('appearance', options, {
        optional = true, appearance = true, applyNPCProfile = true
    }, { 'applyNPCProfile' })
    if type(options.applyNPCProfile) == 'function' then
        adapter._handlers.applyNPCProfile = function(ped, profile)
            local ok, value = pcall(options.applyNPCProfile, ped, profile)
            if not ok then return false end
            if type(value) == 'table' and value.ok ~= nil then return value end
            if value == true then return { applied = true } end
            return value
        end
    end
    adapter.applyNPCProfile = function(self, ped, profile)
        if ped == nil or type(profile) ~= 'table' then return Result.err(Codes.PROVIDER_INVALID, 'appearance requires a ped and abstract profile') end
        return self:invoke('applyNPCProfile', { fallback = true, applied = false }, ped, profile)
    end
    return adapter
end

NightShift.OptionalProviders.Appearance = Appearance
