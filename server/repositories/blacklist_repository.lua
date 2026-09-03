NightShift = NightShift or {}
NightShift.Repositories = NightShift.Repositories or {}
local Result, Codes, Base = NightShift.Result, NightShift.Errors.Codes, NightShift.Repositories.Base
local Repository = {}; Repository.__index = Repository
local columns = {'id','scope_type','scope_ref','worker_profile_id','reason','active','version','created_at','updated_at'}
local function integer(v, min, max)
    v = tonumber(v)
    if not v or v ~= math.floor(v) or v == math.huge or v == -math.huge or (min and v < min) or (max and v > max) then return nil end
    return v
end
local function text(v, max) return type(v) == 'string' and v:match('%S') and #v <= max end
local function scope(v) v = type(v) == 'string' and v:upper(); return v and NightShift.Enums.BlacklistScopes[v] and v end
local function reason(v) v = type(v) == 'string' and v:upper(); return v and NightShift.Enums.BlacklistReasons[v] and v end
local function invalid(m, d) return Result.err(Codes.REPOSITORY_INVALID, m, d) end
local function map(row)
    if type(row) ~= 'table' then return nil end
    local st, sr = scope(row.scope_type or row.scopeType), row.scope_ref or row.scopeRef
    local wi, rr = integer(row.worker_profile_id or row.workerProfileId, 1, 2147483647), reason(row.reason)
    if not st or not text(sr, 160) or not wi or not rr then return nil end
    return {id=integer(row.id,1), scopeType=st, scopeRef=sr, workerProfileId=wi, reason=rr,
        active=tonumber(row.active) ~= 0, version=integer(row.version,1) or 1,
        createdAt=row.created_at or row.createdAt, updatedAt=row.updated_at or row.updatedAt}
end
function Repository.new(options)
    options = options or {}; local db = options.db or options.databaseAdapter
    if type(db) ~= 'table' then return nil, Result.err(Codes.REPOSITORY_DB_UNAVAILABLE, 'blacklist repository requires a database adapter') end
    local name = options.tableName or 'nightshift_blacklist'
    local base, err = Base.new({db=db, tableName=name, columns=columns, mapper=map}); if not base then return nil, err end
    return setmetatable({_base=base, _db=db, _table=name}, Repository)
end
function Repository:findById(id) return self._base:findById(id) end
function Repository:findByScopeWorker(scopeType, scopeRef, workerProfileId, includeInactive)
    scopeType, scopeRef, workerProfileId = scope(scopeType), tostring(scopeRef or ''), integer(workerProfileId,1,2147483647)
    if not scopeType or not text(scopeRef,160) or not workerProfileId then return invalid('blacklist lookup values are invalid') end
    local list, err = self._base:_selectList(); if not list then return err end
    local activeClause = includeInactive == true and '' or ' AND active = 1'
    local result = self._db:single(('SELECT %s FROM %s WHERE scope_type = ? AND scope_ref = ? AND worker_profile_id = ?%s LIMIT 1'):format(list,self._table,activeClause), {scopeType,scopeRef,workerProfileId})
    if type(result) ~= 'table' or not result.ok then return result end
    if result.value == nil then return Result.err(Codes.REPOSITORY_NOT_FOUND, 'blacklist entry was not found') end
    local mapped = self._base:_map(result.value); if not mapped then return Result.err(Codes.MAPPING_FAILED, 'blacklist row mapper returned an error') end
    return Result.ok(mapped)
end
function Repository:listByScope(scopeType, scopeRef, options)
    scopeType, scopeRef = scope(scopeType), tostring(scopeRef or ''); options = options or {}
    local limit, offset = integer(options.limit or 100,1,1000), integer(options.offset or 0,0)
    if not scopeType or not text(scopeRef,160) or not limit or not offset then return invalid('blacklist list values are invalid') end
    local list, err = self._base:_selectList(); if not list then return err end
    local result = self._db:query(('SELECT %s FROM %s WHERE scope_type = ? AND scope_ref = ? AND active = 1 ORDER BY id DESC LIMIT ? OFFSET ?'):format(list,self._table), {scopeType,scopeRef,limit,offset})
    if type(result) ~= 'table' or not result.ok then return result end
    local out = {}; for i,row in ipairs(result.value or {}) do local value = self._base:_map(row); if not value then return Result.err(Codes.MAPPING_FAILED, 'blacklist row mapper returned an error') end; out[i] = value end
    return Result.ok(out,{limit=limit,offset=offset})
end
function Repository:create(value)
    if type(value) ~= 'table' then return invalid('blacklist entry must be a table') end
    local st, sr = scope(value.scopeType or value.scope_type), tostring(value.scopeRef or value.scope_ref or '')
    local wi, rr = integer(value.workerProfileId or value.worker_profile_id,1,2147483647), reason(value.reason)
    if not st or not text(sr,160) or not wi or not rr then return invalid('blacklist entry values are invalid') end
    return self._base:create({scope_type=st,scope_ref=sr,worker_profile_id=wi,reason=rr,active=1})
end
function Repository:updateExpectedVersion(id, version, changes) return self._base:updateExpectedVersion(id,version,changes) end
function Repository:deleteExpectedVersion(id, version) return self._base:updateExpectedVersion(id,version,{active=0}) end
Repository.findByKey = Repository.findByScopeWorker
NightShift.Repositories.Blacklist = Repository
return Repository
