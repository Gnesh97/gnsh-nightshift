NightShift = NightShift or {}
NightShift.Validators = NightShift.Validators or {}
local V = NightShift.Validators
local function copy(v, seen) if type(v) ~= 'table' then return v end; seen=seen or {}; if seen[v] then return seen[v] end; local r={}; seen[v]=r; for k,x in pairs(v) do r[copy(k,seen)]=copy(x,seen) end; return r end
local function fail(c,p,m) local e=NightShift.Errors.create(c,m,{path=p,field=p}); e.path,e.field=p,p; return nil,e end
local function text(v) return type(v)=='string' and v:match('%S')~=nil end
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function positive(v) return finite(v) and v>0 end
local function integer(v) return positive(v) and math.floor(v)==v end
local function array(a,p,label)
    if type(a)~='table' then return fail('INVALID_CONFIG',p,label..' must be an array') end
    local count=0; for k in pairs(a) do if type(k)~='number' or k<1 or math.floor(k)~=k then return fail('INVALID_CONFIG',p,label..' must be contiguous') end; count=count+1 end
    for i=1,count do if rawget(a,i)==nil then return fail('INVALID_CONFIG',p,label..' must be contiguous') end end
    return true
end
local function ids(a,p,label)
    local ok,e=array(a,p,label); if not ok then return nil,e end; local r,s={},{}
    for i,x in ipairs(a) do if type(x)~='table' or not text(x.id) then return fail('INVALID_CONFIG',p..'['..i..'].id',label..' IDs must be non-empty') end; if s[x.id] then return fail('DUPLICATE_ID',p..'['..i..'].id','duplicate '..label..' ID') end; s[x.id]=true; r[i]=copy(x) end
    return r,s
end

local function currency(value, path, fallback)
    value = value == nil and fallback or value
    if type(value) ~= 'string' then return fail('INVALID_CONFIG', path, 'currency must be a three-letter code') end
    value = value:upper()
    if value:match('^[A-Z][A-Z][A-Z]$') == nil then return fail('INVALID_CONFIG', path, 'currency must be a three-letter code') end
    return value
end

local function booleanValue(value, path, fallback)
    value = value == nil and fallback or value
    if type(value) ~= 'boolean' then return fail('INVALID_CONFIG', path, 'value must be boolean') end
    return value
end

local function numericMap(value, path, default)
    if value == nil then value = default or {} end
    if type(value) ~= 'table' then return fail('INVALID_CONFIG', path, 'modifier map must be a table') end
    local output = {}
    for key, item in pairs(value) do
        if not text(key) or not finite(item) or item <= 0 or item > 100 then
            return fail('INVALID_CONFIG', path .. '.' .. tostring(key), 'modifier must be a finite positive number')
        end
        output[tostring(key):upper()] = item
    end
    return output
end

local function validateServiceCatalog(raw, locations)
    if raw == nil then raw = NightShift.ServiceCatalogConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'serviceCatalog', 'service catalog must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'serviceCatalog.enabled', true)
    if enabled == nil then return nil, enabledError end
    local code, codeError = currency(raw.currency, 'serviceCatalog.currency', 'USD')
    if not code then return nil, codeError end
    local packages = raw.packages or raw.servicePackages
    if packages == nil then packages = {} end
    local normalized, packageIds = ids(packages, 'serviceCatalog.packages', 'service package')
    if not normalized then return nil, packageIds end
    if #normalized == 0 and enabled then return fail('INVALID_CONFIG', 'serviceCatalog.packages', 'service catalog requires at least one package') end
    local locationIds = {}
    for _, location in ipairs(locations or {}) do locationIds[location.id] = true end
    local normalizedIds = {}
    for index, package in ipairs(normalized) do
        local normalizedId = tostring(package.id):lower()
        if normalizedIds[normalizedId] then return fail('DUPLICATE_ID', 'serviceCatalog.packages[' .. index .. '].id', 'duplicate service package ID') end
        normalizedIds[normalizedId] = true
        local price = package.basePriceMinor
        if price == nil then price = package.basePrice end
        if price == nil then price = package.priceMinor end
        if price == nil then price = package.price end
        if not integer(price) then return fail('INVALID_PRICE', 'serviceCatalog.packages[' .. index .. '].basePriceMinor', 'base price must be a positive integer in minor units') end
        package.basePriceMinor = price
        local duration = package.durationMinutes or package.duration
        if not integer(duration) then return fail('INVALID_DURATION', 'serviceCatalog.packages[' .. index .. '].durationMinutes', 'duration must be a positive integer') end
        package.durationMinutes = duration
        local minimum = package.minClientReputation or package.minReputation or package.reputationRequired or 0
        if not finite(minimum) or minimum < 0 or minimum > 1000000 then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].minClientReputation', 'reputation requirement is invalid') end
        package.minClientReputation = minimum
        local modes = package.meetingModes or package.modes
        if modes ~= nil then
            local modeOk, modeError = array(modes, 'serviceCatalog.packages[' .. index .. '].meetingModes')
            if not modeOk then return nil, modeError end
            local seenModes = {}
            for modeIndex, mode in ipairs(modes) do
                if not text(mode) or not mode:match('^[A-Za-z][A-Za-z0-9_%-]*$') then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].meetingModes[' .. modeIndex .. ']', 'meeting mode is invalid') end
                local normalizedMode = mode:upper()
                if seenModes[normalizedMode] then return fail('INVALID_CONFIG', 'serviceCatalog.packages[' .. index .. '].meetingModes', 'meeting modes must be unique') end
                seenModes[normalizedMode] = true
            end
            package.meetingModes = copy(modes)
        end
        local refs = package.locationIds or package.locations
        if refs ~= nil then
            local refsOk, refsError = array(refs, 'serviceCatalog.packages[' .. index .. '].locationIds')
            if not refsOk then return nil, refsError end
            local seenRefs = {}
            for refIndex, ref in ipairs(refs) do
                if not text(ref) or seenRefs[ref] then return fail('INVALID_LOCATION_REFERENCE', 'serviceCatalog.packages[' .. index .. '].locationIds[' .. refIndex .. ']', 'location reference must be unique and non-empty') end
                if next(locationIds) ~= nil and not locationIds[ref] then return fail('INVALID_LOCATION_REFERENCE', 'serviceCatalog.packages[' .. index .. '].locationIds[' .. refIndex .. ']', 'location reference is not allowlisted') end
                seenRefs[ref] = true
            end
            package.locationIds = copy(refs)
        end
        local categories = package.locationCategories or package.categories
        if categories ~= nil then
            local categoryOk, categoryError = array(categories, 'serviceCatalog.packages[' .. index .. '].locationCategories')
            if not categoryOk then return nil, categoryError end
            package.locationCategories = copy(categories)
        end
        if package.currency ~= nil then
            local packageCurrency, packageCurrencyError = currency(package.currency, 'serviceCatalog.packages[' .. index .. '].currency', code)
            if not packageCurrency then return nil, packageCurrencyError end
            package.currency = packageCurrency
        end
    end
    output.enabled, output.currency, output.packages = enabled, code, normalized
    output.servicePackages = copy(normalized)
    return output
end

local function validatePricing(raw)
    if raw == nil then raw = NightShift.PricingConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'pricing', 'pricing must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'pricing.enabled', true)
    if enabled == nil then return nil, enabledError end
    local code, codeError = currency(raw.currency, 'pricing.currency', 'USD')
    if not code then return nil, codeError end
    local ttl = raw.quoteTtlSeconds == nil and 300 or raw.quoteTtlSeconds
    if not integer(ttl) or ttl > 86400 then return fail('INVALID_CONFIG', 'pricing.quoteTtlSeconds', 'quote TTL must be a positive integer no greater than one day') end
    local minimum = raw.minAmountMinor == nil and 1 or raw.minAmountMinor
    local maximum = raw.maxAmountMinor == nil and 100000000000 or raw.maxAmountMinor
    if not integer(minimum) or not integer(maximum) or minimum > maximum then return fail('INVALID_CONFIG', 'pricing', 'pricing bounds are invalid') end
    local npc, npcError = numericMap(raw.npcPriceClasses or raw.npcModifiers, 'pricing.npcPriceClasses')
    if not npc then return nil, npcError end
    local district, districtError = numericMap(raw.districtModifiers, 'pricing.districtModifiers')
    if not district then return nil, districtError end
    local time, timeError = numericMap(raw.timeModifiers, 'pricing.timeModifiers')
    if not time then return nil, timeError end
    local demand, demandError = numericMap(raw.demandModifiers, 'pricing.demandModifiers')
    if not demand then return nil, demandError end
    local reputation, reputationError = numericMap(raw.reputationModifiers, 'pricing.reputationModifiers')
    if not reputation then return nil, reputationError end
    local fees = raw.fees == nil and {} or raw.fees
    if type(fees) ~= 'table' then return fail('INVALID_CONFIG', 'pricing.fees', 'pricing fees must be a table') end
    local travel = fees.travelMinor or fees.travel or 0
    local location = fees.locationMinor or fees.location or 0
    if not finite(travel) or travel < 0 or math.floor(travel) ~= travel or not finite(location) or location < 0 or math.floor(location) ~= location then return fail('INVALID_CONFIG', 'pricing.fees', 'pricing fees must be non-negative integers') end
    output.enabled, output.currency, output.quoteTtlSeconds = enabled, code, ttl
    output.minAmountMinor, output.maxAmountMinor = minimum, maximum
    output.npcPriceClasses, output.districtModifiers, output.timeModifiers = npc, district, time
    output.demandModifiers, output.reputationModifiers = demand, reputation
    output.fees = { travelMinor = travel, locationMinor = location }
    return output
end

local function validateCancellation(raw)
    if raw == nil then raw = NightShift.CancellationConfig end
    if raw == nil then raw = {} end
    if type(raw) ~= 'table' then return fail('INVALID_CONFIG', 'cancellation', 'cancellation must be a table') end
    local output = copy(raw)
    local enabled, enabledError = booleanValue(raw.enabled, 'cancellation.enabled', true)
    if enabled == nil then return nil, enabledError end
    if raw.account ~= nil and not text(raw.account) then return fail('INVALID_CONFIG', 'cancellation.account', 'cancellation account is invalid') end
    local percentages = raw.percentages or raw.refundPercentages or {}
    if type(percentages) ~= 'table' then return fail('INVALID_CONFIG', 'cancellation.percentages', 'cancellation percentages must be a table') end
    local normalized = {}
    for status, percentage in pairs(percentages) do
        if not text(status) or not finite(percentage) or percentage < 0 or percentage > 100 then return fail('INVALID_CONFIG', 'cancellation.percentages.' .. tostring(status), 'refund percentage must be between zero and one hundred') end
        normalized[tostring(status):upper()] = percentage
    end
    output.enabled, output.account, output.percentages = enabled, raw.account or 'cash', normalized
    return output
end

function V.validateConfig(input, options)
    options=options or {}; if input==nil then input=NightShift.DefaultConfig end; if type(input)~='table' then return fail('INVALID_CONFIG','config','configuration must be a table') end
    local out=copy(input); local raw=rawget(input,'provider'); if raw==nil then raw=rawget(input,'providerSelection') end; local provider=raw==nil and {} or raw
    if type(provider)=='string' then provider={mode='explicit',name=provider} end; if type(provider)~='table' then return fail('INVALID_CONFIG','provider','provider selection must be a table') end
    local mode=rawget(provider,'mode'); mode=mode==nil and 'auto' or mode; if not NightShift.ProviderModes[mode] then return fail('INVALID_CONFIG','provider.mode','provider mode must be auto or explicit') end
    local registry=options.registry or NightShift.ProviderRegistry; if type(registry)~='table' then return fail('INVALID_CONFIG','provider','provider registry is invalid') end
    local selected,capabilities
    if mode=='explicit' then selected=rawget(provider,'name'); if selected==nil then selected=rawget(provider,'provider') end; if not text(selected) or type(registry[selected])~='table' then return fail('UNKNOWN_PROVIDER','provider.name','provider is not allowlisted') end; capabilities=copy(registry[selected].capabilities or {})
    else
        local resolver=options.resolveProvider or options.providerResolver; if type(resolver)~='function' then return fail('PROVIDER_UNAVAILABLE','provider','auto provider detection is unavailable') end
        local ok,result=pcall(resolver,copy(registry)); if not ok or type(result)~='table' then return fail('PROVIDER_UNAVAILABLE','provider','no supported provider was detected') end
        selected=result.name; if not text(selected) or type(registry[selected])~='table' or result.supported~=true or result.available~=true or type(result.capabilities)~='table' then return fail('PROVIDER_UNAVAILABLE','provider','detected provider has no supported capability') end
        local supported=false; for _,v in pairs(result.capabilities) do if v==true then supported=true; break end end; if not supported then return fail('PROVIDER_UNAVAILABLE','provider','detected provider has no supported capability') end; capabilities=copy(result.capabilities)
    end
    out.provider={mode=mode,name=selected,capabilities=capabilities}
    local features=copy(NightShift.FeatureDefaults); local rf=rawget(input,'features'); if rf~=nil then if type(rf)~='table' then return fail('INVALID_CONFIG','features','features must be a table') end; for k,v in pairs(rf) do if type(features[k])~='boolean' or type(v)~='boolean' then return fail('INVALID_CONFIG','features.'..tostring(k),'feature flags must be boolean') end; features[k]=v end end; out.features=features
    local rp=rawget(input,'servicePackages'); if rp==nil then rp=rawget(input,'packages') end; local packages,ps=ids(rp==nil and {} or rp,'servicePackages','service package'); if not packages then return nil,ps end
    for i,pkg in ipairs(packages) do local price=rawget(pkg,'price'); if price==nil then price=rawget(pkg,'priceMinor') end; if not integer(price) then return fail('INVALID_PRICE','servicePackages['..i..'].price','price must be a positive integer in minor units') end; pkg.price=price; if not positive(pkg.duration) then return fail('INVALID_DURATION','servicePackages['..i..'].duration','duration must be positive') end; local refs=rawget(pkg,'locationIds'); if refs==nil then refs=rawget(pkg,'location_ids') end; if refs==nil then refs=rawget(pkg,'locations') end; refs=refs==nil and {} or refs; local rok,re=array(refs,'servicePackages['..i..'].locationIds','location references'); if not rok then return nil,re end; local rs={}; for j,id in ipairs(refs) do if not text(id) or rs[id] then return fail('INVALID_LOCATION_REFERENCE','servicePackages['..i..'].locationIds['..j..']','location reference must be unique and non-empty') end; rs[id]=true end; pkg.locationIds=copy(refs); if pkg.provider~=nil and (not text(pkg.provider) or not registry[pkg.provider]) then return fail('UNKNOWN_PROVIDER','servicePackages['..i..'].provider','provider reference is not allowlisted') end end; out.servicePackages=packages
    local rl=rawget(input,'locations'); local locations,ls=ids(rl==nil and {} or rl,'locations','location'); if not locations then return nil,ls end; local categories={configured=true,housing=true,motel=true,venue=true,vehicle=true}; for i,l in ipairs(locations) do if not text(l.category) or not categories[l.category] then return fail('INVALID_CONFIG','locations['..i..'].category','location category is invalid') end end; out.locations=locations; for i,pkg in ipairs(packages) do for j,id in ipairs(pkg.locationIds) do if not ls[id] then return fail('INVALID_LOCATION_REFERENCE','servicePackages['..i..'].locationIds['..j..']','location reference is not allowlisted') end end end
    local catalog, catalogError = validateServiceCatalog(rawget(input, 'serviceCatalog'), locations); if not catalog then return nil, catalogError end; out.serviceCatalog = catalog
    local pricing, pricingError = validatePricing(rawget(input, 'pricing')); if not pricing then return nil, pricingError end; out.pricing = pricing
    local cancellation, cancellationError = validateCancellation(rawget(input, 'cancellation')); if not cancellation then return nil, cancellationError end; out.cancellation = cancellation
    local profiles,pr=ids(input.npcProfiles==nil and {} or input.npcProfiles,'npcProfiles','NPC profile'); if not profiles then return nil,pr end; local allowed={id=true,availability=true,traits=true,tags=true,displayName=true}; for i,p in ipairs(profiles) do for k,v in pairs(p) do if not allowed[k] then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile field is not abstract/allowlisted') end; if (k=='availability' or k=='displayName') and (not text(v) or #v>80) then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile scalar is invalid') end; if k=='traits' or k=='tags' then local ok,e=array(v,'npcProfiles['..i..'].'..tostring(k),'NPC profile list'); if not ok then return nil,e end; for j,item in ipairs(v) do if not text(item) or #item>40 then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k)..'['..j..']','NPC profile list value is invalid') end end end end end; out.npcProfiles=profiles
    local function bounded(v,p,d,max) v=v==nil and d or v; if not finite(v) or v<0 or v>max then return fail('INVALID_CONFIG',p,'value is outside safe bounds') end; return v end
    local function section(name)
        local s=rawget(input,name); if s==nil then s={} end; if type(s)~='table' then return fail('INVALID_CONFIG',name,name..' must be a table') end; local mn,e=bounded(s.min,name..'.min',0,100); if mn==nil then return nil,e end; local mx; mx,e=bounded(s.max,name..'.max',100,100); if mx==nil then return nil,e end; if mx<mn then return fail('INVALID_CONFIG',name..'.max','maximum must not be below minimum') end; local r=copy(s); r.min,r.max=mn,mx; if name=='demand' then r.window,e=bounded(s.window,name..'.window',0,86400); if r.window==nil then return nil,e end else r.decay,e=bounded(s.decay,name..'.decay',0,100); if r.decay==nil then return nil,e end end; return r
    end
    local demand,e=section('demand'); if not demand then return nil,e end; local heat; heat,e=section('heat'); if not heat then return nil,e end; out.demand,out.heat=demand,heat; return out
end
V.copy=copy; NightShift.Config=NightShift.Config or {validate=V.validateConfig}
