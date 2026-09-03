NightShift=NightShift or {}; NightShift.Repositories=NightShift.Repositories or {}
local Result,Codes=NightShift.Result,NightShift.Errors.Codes; local Base,Domain=NightShift.Repositories.Base,NightShift.Domain.Agency
local R={}; R.__index=R; local columns={'id','agency_key','name','owner_ref','status','commission_rate','members_json','version','created_at','updated_at'}
local function bad(m) return Result.err(Codes.REPOSITORY_INVALID,m) end
local function text(v) return type(v)=='string' and v:match('%S') end
function R.new(o)
 o=o or {}; local db=o.db or o.databaseAdapter; if type(db)~='table' then return nil,Result.err(Codes.REPOSITORY_DB_UNAVAILABLE,'agency repository requires a database adapter') end
 local name=o.tableName or 'nightshift_agencies'; if type(name)~='string' or not name:match('^[A-Za-z_][A-Za-z0-9_]*$') then return nil,bad('agency repository table name is invalid') end
 local base,e=Base.new({db=db,tableName=name,columns=columns,mapper=function(row) local x,er=Domain.fromRow(row); return x or Result.err(Codes.MAPPING_FAILED,'agency row is invalid',{cause=er and er.error and er.error.code}) end}); if not base then return nil,e end
 return setmetatable({_base=base,_db=db,_table=name},R)
end
function R:findById(id) return self._base:findById(id) end
function R:findByKey(key)
 if not text(key) then return bad('agency key is invalid') end
 local list,e=self._base:_selectList(); if not list then return e end
 local r=self._db:single(('SELECT %s FROM %s WHERE agency_key = ? LIMIT 1'):format(list,self._table),{key}); if type(r)~='table' or not r.ok then return r end
 if r.value==nil then return Result.err(Codes.REPOSITORY_NOT_FOUND,'agency was not found') end; return self._base:_map(r.value)
end
function R:findAll(o) return self._base:findAll(o) end
function R:create(v) local row,e=Domain.toRow(v); if not row then return e end; local old=self:findByKey(row.agency_key); if old and old.ok then return Result.err(Codes.PROVIDER_CONFLICT,'agency key already exists') end; if old and old.error and old.error.code~=Codes.REPOSITORY_NOT_FOUND then return old end; return self._base:create(row) end
function R:updateExpectedVersion(id,ver,changes)
 if type(changes)~='table' then return bad('agency changes must be a table') end
 local map={key='agency_key',agencyKey='agency_key',name='name',displayName='name',ownerRef='owner_ref',status='status',commissionRate='commission_rate',members='members_json'}; local out={}
 for k,v in pairs(changes) do if not map[k] then return bad('agency field is not mutable') end; if k=='members' then if not json or type(json.encode)~='function' then return bad('agency members serializer is unavailable') end; local ok,encoded=pcall(json.encode,v); if not ok then return bad('agency members are not serializable') end; v=encoded end; out[map[k]]=v end
 return self._base:updateExpectedVersion(id,ver,out)
end
R.update=R.updateExpectedVersion; R.findByAgencyKey=R.findByKey; NightShift.Repositories.Agency=R
