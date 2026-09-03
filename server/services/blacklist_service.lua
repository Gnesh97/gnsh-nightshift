NightShift = NightShift or {}; NightShift.Services = NightShift.Services or {}
local Result, Codes = NightShift.Result, NightShift.Errors.Codes
local Service = {}; Service.__index = Service
local function text(v,max) return type(v)=='string' and v:match('%S') and #v<=max end
local function integer(v,min,max)
    v=tonumber(v); if not v or v~=math.floor(v) or v==math.huge or v==-math.huge or (min and v<min) or (max and v>max) then return nil end; return v
end
local function invalid(m,d) return Result.err(Codes.BLACKLIST_INVALID,m,d) end
local function notFound(v) return type(v)=='table' and v.ok==false and v.error and v.error.code==Codes.REPOSITORY_NOT_FOUND end
local function scope(v) v=type(v)=='string' and v:upper(); return v and NightShift.Enums.BlacklistScopes[v] and v end
local function reason(v) v=type(v)=='string' and v:upper(); return v and NightShift.Enums.BlacklistReasons[v] and v end
function Service.new(options)
    options=options or {}; local repo=options.repository or options.blacklistRepository
    if type(repo)~='table' or type(repo.findByScopeWorker)~='function' or type(repo.listByScope)~='function' or type(repo.create)~='function' then return nil,invalid('blacklist service requires a repository') end
    return setmetatable({_repository=repo,_identity=options.identityService or options.identity,_agencyResolver=options.agencyResolver},Service)
end
function Service:_personalRef(actor)
    if type(actor)=='table' then return text(actor.ref,160) and actor.ref or actor.identityKey end
    if self._identity and type(self._identity.resolve)=='function' then
        local result=self._identity:resolve(actor)
        if type(result)=='table' and result.ok and type(result.value)=='table' then return result.value.identityKey or result.value.key end
    end
    return nil
end
function Service:_scopes(actor, options)
    options=options or {}; local out={}
    local personal=options.personalRef or self:_personalRef(actor)
    if text(personal,160) then out[#out+1]={scopeType='PERSONAL',scopeRef=personal} end
    local agency=options.agencyRef
    if not agency and type(self._agencyResolver)=='function' then local ok,v=pcall(self._agencyResolver,actor); if ok then agency=v end end
    if text(agency,160) then out[#out+1]={scopeType='AGENCY',scopeRef=agency} end
    return out
end
function Service:isBlocked(actor, workerProfileId, options)
    workerProfileId=integer(workerProfileId,1,2147483647); if not workerProfileId then return invalid('worker profile ID is invalid') end
    for _, item in ipairs(self:_scopes(actor,options)) do
        local found=self._repository:findByScopeWorker(item.scopeType,item.scopeRef,workerProfileId)
        if type(found)~='table' then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist lookup returned an invalid result') end
        if found.ok then return Result.ok(true,{scopeType=item.scopeType,scopeRef=item.scopeRef,entry=found.value}) end
        if not notFound(found) then return found end
    end
    return Result.ok(false)
end
function Service:add(actor, workerProfileId, why, options)
    workerProfileId=integer(workerProfileId,1,2147483647); why=reason(why); options=options or {}
    if not workerProfileId or not why then return invalid('worker profile ID or blacklist reason is invalid') end
    local scopes=self:_scopes(actor,options); local item=scopes[1]
    if not item then return invalid('blacklist scope could not be resolved') end
    local existing=self._repository:findByScopeWorker(item.scopeType,item.scopeRef,workerProfileId,true)
    if type(existing)~='table' then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist lookup returned an invalid result') end
    if existing.ok then
        if existing.value.active then return Result.ok(existing.value,{idempotent=true}) end
        local restored=self._repository:updateExpectedVersion(existing.value.id,existing.value.version,{active=1,reason=why})
        if type(restored)~='table' or not restored.ok then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist entry could not be restored') end
        return Result.ok({id=existing.value.id,scopeType=item.scopeType,scopeRef=item.scopeRef,workerProfileId=workerProfileId,reason=why,active=true,version=restored.value.version},{restored=true})
    end
    if not notFound(existing) then return existing end
    local created=self._repository:create({scopeType=item.scopeType,scopeRef=item.scopeRef,workerProfileId=workerProfileId,reason=why})
    if type(created)~='table' or not created.ok then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist entry could not be persisted',{cause=created and created.error and created.error.code}) end
    return Result.ok(created.value,{created=true,serverAuthoritative=true})
end
function Service:remove(actor, workerProfileId, options)
    workerProfileId=integer(workerProfileId,1,2147483647); if not workerProfileId then return invalid('worker profile ID is invalid') end
    local scopes=self:_scopes(actor,options); local item=scopes[1]; if not item then return invalid('blacklist scope could not be resolved') end
    local found=self._repository:findByScopeWorker(item.scopeType,item.scopeRef,workerProfileId)
    if type(found)~='table' then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist lookup returned an invalid result') end
    if not found.ok then if notFound(found) then return Result.ok({removed=false},{idempotent=true}) end; return found end
    local deleted=self._repository:deleteExpectedVersion(found.value.id,found.value.version)
    if type(deleted)~='table' or not deleted.ok then return Result.err(Codes.BLACKLIST_OPERATION_FAILED,'blacklist entry could not be removed',{cause=deleted and deleted.error and deleted.error.code}) end
    return Result.ok({removed=true,workerProfileId=workerProfileId},{serverAuthoritative=true})
end
function Service:list(actor, options)
    local scopes=self:_scopes(actor,options); local output={}
    for _,item in ipairs(scopes) do local result=self._repository:listByScope(item.scopeType,item.scopeRef,options)
        if type(result)~='table' or not result.ok then return result end
        for _,entry in ipairs(result.value or {}) do output[#output+1]=entry end
    end
    return Result.ok(output)
end
function Service:filterWorkers(actor, workers, options)
    if type(workers)~='table' then return invalid('worker list is invalid') end
    local out={}; for _,worker in ipairs(workers) do
        local profile=worker.profile or worker; local id=worker.profileId or profile.profileId or profile.id
        local blocked=self:isBlocked(actor,id,options)
        if type(blocked)~='table' then return blocked end
        if blocked.value~=true then out[#out+1]=worker end
    end
    return Result.ok(out,{filtered=#workers-#out})
end
Service.check=Service.isBlocked; Service.addEntry=Service.add; Service.removeEntry=Service.remove
NightShift.BlacklistService=Service; NightShift.Services.Blacklist=Service
return Service
