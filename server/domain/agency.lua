NightShift = NightShift or {}
NightShift.Domain = NightShift.Domain or {}
local Result,Codes=NightShift.Result,NightShift.Errors.Codes
local Agency={}
local function copy(v,s) if type(v)~='table' then return v end; s=s or {}; if s[v] then return s[v] end; local o={}; s[v]=o; for k,x in pairs(v) do o[copy(k,s)]=copy(x,s) end; return o end
local function decodeMembers(v)
 if type(v)=='table' then return copy(v) end
 if type(v)=='string' and json and type(json.decode)=='function' then local ok,x=pcall(json.decode,v); if ok and type(x)=='table' then return x end end
 return {}
end
local function text(v,m) return type(v)=='string' and v:match('%S') and #v<=(m or 160) end
local function token(v,m) return text(v,m) and v:match('^[A-Za-z][A-Za-z0-9_.:%-]*$') end
local function int(v,a,b) v=tonumber(v); if not v or v~=math.floor(v) or v==math.huge or v==-math.huge or (a and v<a) or (b and v>b) then return nil end; return v end
local function bad(m) return Result.err(Codes.AGENCY_INVALID or Codes.PROVIDER_INVALID,m) end
local function normalize(v)
 if type(v)~='table' then return nil,bad('agency must be a table') end
 local key=v.key or v.agencyKey or v.agency_key or v.slug; local name=v.name or v.displayName or v.display_name
 if not token(key,96) then return nil,bad('agency key is invalid') end
 if not text(name,120) then return nil,bad('agency name is required') end
 local owner=v.ownerRef or v.owner_ref or v.ownerIdentifier or v.owner_identifier
 if owner~=nil and not text(owner,160) then return nil,bad('agency owner is invalid') end
 local rate=tonumber(v.commissionRate or v.commission_rate or 0)
 if not rate or rate<0 or rate>10000 or rate~=math.floor(rate) then return nil,bad('agency commission rate must be 0..10000 basis points') end
 local status=tostring(v.status or 'ACTIVE'):upper(); if status~='ACTIVE' and status~='SUSPENDED' and status~='ARCHIVED' then return nil,bad('agency status is invalid') end
 local id=v.id and int(v.id,1,2147483647) or nil; if v.id~=nil and not id then return nil,bad('agency ID is invalid') end
 return {id=id,key=key,agencyKey=key,name=name,displayName=name,ownerRef=owner,status=status,commissionRate=rate,members=decodeMembers(v.members or v.members_json),version=int(v.version or 1,1,2147483647) or 1,createdAt=v.createdAt or v.created_at,updatedAt=v.updatedAt or v.updated_at}
end
function Agency.new(v) return normalize(v) end
function Agency.fromRow(v) return normalize(v) end
function Agency.validate(v) local x,e=normalize(v); return x~=nil,e end
function Agency.copy(v) return copy(v) end
function Agency.toRow(v) local x,e=normalize(v); if not x then return nil,e end; local encoded; if json and type(json.encode)=='function' then local ok,value=pcall(json.encode,x.members); if ok then encoded=value end end; return {agency_key=x.key,name=x.name,owner_ref=x.ownerRef,status=x.status,commission_rate=x.commissionRate,members_json=encoded or '{}'} end
NightShift.Domain.Agency=Agency; NightShift.Agency=Agency
