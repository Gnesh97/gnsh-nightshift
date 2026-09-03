NightShift=NightShift or {}; NightShift.Services=NightShift.Services or {}
local Result,Codes=NightShift.Result,NightShift.Errors.Codes; local Domain=NightShift.Domain.Agency; local S={}; S.__index=S
local function text(v) return type(v)=='string' and v:match('%S') end
local function bad(m) return Result.err(Codes.AGENCY_INVALID or Codes.PROVIDER_INVALID,m) end
function S.new(o)
 o=o or {}; local r=o.repository or o.agencyRepository; if type(r)~='table' or type(r.create)~='function' or type(r.findByKey)~='function' then return nil,bad('agency service requires an agency repository') end
 return setmetatable({_repository=r,_admin=o.adminCheck},S)
end
function S:_allowed(source,input) if type(self._admin)=='function' then local ok,v=pcall(self._admin,source,input); return ok and v==true end; return tonumber(source) == 0 end
function S:create(source,input) if type(input)~='table' or not self:_allowed(source,input) then return Result.err(Codes.PERMISSION_DENIED,'agency administration is required') end; local a,e=Domain.new(input); if not a then return e end; local r=self._repository:create(a); if not r or not r.ok then return r end; return Result.ok(r.value or r,{created=true,serverAuthoritative=true}) end
function S:get(key) if not text(key) then return bad('agency key is required') end; return self._repository:findByKey(key) end
function S:configure(source,key,changes)
 if type(changes)~='table' or not self:_allowed(source,changes) then return Result.err(Codes.PERMISSION_DENIED,'agency administration is required') end
 local r=self:get(key); if not r or not r.ok then return r end
 local allowed={ name=true, displayName=true, ownerRef=true, status=true, commissionRate=true, members=true }
 local a=Domain.copy(r.value); local clean={}
 for k,v in pairs(changes) do
  if not allowed[k] then return bad('agency configuration field is not mutable') end
  a[k]=v; clean[k]=v
 end
 if next(clean)==nil then return bad('agency configuration must not be empty') end
 local n,e=Domain.new(a); if not n then return e end
 return self._repository:updateExpectedVersion(n.id,r.value.version,clean)
end
function S:optIn(source,key,member) local r=self:get(key); if not r or not r.ok then return r end; member=member or {}; local ref=member.ref or member.identityKey or ('source:'..tostring(source)); if not text(ref) then return bad('agency member ref is required') end; local role=tostring(member.role or 'MEMBER'):upper(); if role~='MEMBER' and role~='MANAGER' and role~='OWNER' then return bad('agency member role is invalid') end; local m=Domain.copy(r.value.members or {}); m[ref]={ref=ref,role=role,permissions=Domain.copy(member.permissions or {}),optedIn=true}; return self._repository:updateExpectedVersion(r.value.id,r.value.version,{members=m}) end
function S:optOut(source,key,ref) local r=self:get(key); if not r or not r.ok then return r end; ref=ref or ('source:'..tostring(source)); local m=Domain.copy(r.value.members or {}); if not m[ref] then return Result.ok({optedOut=false},{idempotent=true}) end; m[ref].optedIn=false; return self._repository:updateExpectedVersion(r.value.id,r.value.version,{members=m}) end
function S:member(key,ref) local r=self:get(key); if not r or not r.ok then return r end; local m=(r.value.members or {})[ref]; if not m or m.optedIn==false then return Result.err(Codes.REPOSITORY_NOT_FOUND,'agency member was not found') end; return Result.ok(Domain.copy(m)) end
S.join=S.optIn; S.leave=S.optOut; NightShift.Services.Agency=S; NightShift.AgencyService=S
