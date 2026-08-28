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
    local profiles,pr=ids(input.npcProfiles==nil and {} or input.npcProfiles,'npcProfiles','NPC profile'); if not profiles then return nil,pr end; local allowed={id=true,availability=true,traits=true,tags=true,displayName=true}; for i,p in ipairs(profiles) do for k,v in pairs(p) do if not allowed[k] then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile field is not abstract/allowlisted') end; if (k=='availability' or k=='displayName') and (not text(v) or #v>80) then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k),'NPC profile scalar is invalid') end; if k=='traits' or k=='tags' then local ok,e=array(v,'npcProfiles['..i..'].'..tostring(k),'NPC profile list'); if not ok then return nil,e end; for j,item in ipairs(v) do if not text(item) or #item>40 then return fail('INVALID_CONFIG','npcProfiles['..i..'].'..tostring(k)..'['..j..']','NPC profile list value is invalid') end end end end end; out.npcProfiles=profiles
    local function bounded(v,p,d,max) v=v==nil and d or v; if not finite(v) or v<0 or v>max then return fail('INVALID_CONFIG',p,'value is outside safe bounds') end; return v end
    local function section(name)
        local s=rawget(input,name); if s==nil then s={} end; if type(s)~='table' then return fail('INVALID_CONFIG',name,name..' must be a table') end; local mn,e=bounded(s.min,name..'.min',0,100); if mn==nil then return nil,e end; local mx; mx,e=bounded(s.max,name..'.max',100,100); if mx==nil then return nil,e end; if mx<mn then return fail('INVALID_CONFIG',name..'.max','maximum must not be below minimum') end; local r=copy(s); r.min,r.max=mn,mx; if name=='demand' then r.window,e=bounded(s.window,name..'.window',0,86400); if r.window==nil then return nil,e end else r.decay,e=bounded(s.decay,name..'.decay',0,100); if r.decay==nil then return nil,e end end; return r
    end
    local demand,e=section('demand'); if not demand then return nil,e end; local heat; heat,e=section('heat'); if not heat then return nil,e end; out.demand,out.heat=demand,heat; return out
end
V.copy=copy; NightShift.Config=NightShift.Config or {validate=V.validateConfig}
