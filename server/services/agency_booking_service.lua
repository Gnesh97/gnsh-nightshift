NightShift = NightShift or {}
NightShift.Services = NightShift.Services or {}
local Result,Codes=NightShift.Result,NightShift.Errors.Codes
local Service={}; Service.__index=Service
local function bad(m) return Result.err(Codes.AGENCY_INVALID or Codes.PROVIDER_INVALID,m) end
local function text(v) return type(v)=='string' and v:match('%S') and #v<=200 end
local function unwrap(r) if type(r)~='table' then return nil,bad('agency booking dependency returned invalid result') end; if r.ok==false then return nil,r end; return r.ok==true and r.value or r end
function Service.new(o)
 o=o or {}; if type(o.agencyService)~='table' or type(o.agencyService.member)~='function' then return nil,bad('agency booking requires an agency service') end
 if type(o.bookingService)~='table' then return nil,bad('agency booking requires a booking service') end
 return setmetatable({_agency=o.agencyService,_booking=o.bookingService,_availability=o.workerAvailabilityService or o.workerAvailability,_offers={}},Service)
end
function Service:_member(agencyKey,workerRef) local r=self._agency:member(agencyKey,workerRef); if not r or not r.ok then return nil,r end; if r.value.optedIn~=true then return nil,Result.err(Codes.WORKER_AVAILABILITY_DENIED,'worker is not opted in to agency') end; return r.value end
function Service:route(source,agencyKey,workerRef,bookingId)
 if not text(agencyKey) or not text(workerRef) then return bad('agency booking routing input is invalid') end
 local m,e=self:_member(agencyKey,workerRef); if not m then return e end
 local agencyResult=self._agency:get(agencyKey); if not agencyResult or not agencyResult.ok then return agencyResult end
 local agency=agencyResult.value
 if self._availability and type(self._availability.get)=='function' then local a=self._availability:get(source); local v,ae=unwrap(a); if not v then return ae end; if v.available~=true or v.state~='AVAILABLE' then return Result.err(Codes.WORKER_AVAILABILITY_DENIED,'worker is not available for agency routing') end end
 local key=tostring(agencyKey)..':'..tostring(bookingId or 'pending')..':'..tostring(workerRef)
 local offer={routingKey=key,agencyKey=agencyKey,workerRef=workerRef,bookingId=bookingId,status='OFFERED',commissionRate=agency.commissionRate or 0,role=m.role}
 self._offers[key]=offer; return Result.ok(offer,{serverAuthoritative=true})
end
function Service:accept(workerRef,routingKey)
 local offer=self._offers[routingKey]; if not offer or offer.workerRef~=workerRef then return Result.err(Codes.AGENCY_NOT_FOUND or Codes.REPOSITORY_NOT_FOUND,'agency booking offer was not found') end
 if offer.status~='OFFERED' then return Result.err(Codes.AGENCY_CONFLICT or Codes.WORKER_MODE_CONFLICT,'agency booking offer is no longer open') end
 local accepted={routingKey=offer.routingKey,agencyKey=offer.agencyKey,workerRef=offer.workerRef,bookingId=offer.bookingId,status='ACCEPTED',commissionRate=offer.commissionRate,role=offer.role,commissionSnapshot={rate=offer.commissionRate,agencyKey=offer.agencyKey}}; self._offers[routingKey]=accepted; offer=accepted
 return Result.ok(offer,{accepted=true})
end
function Service:decline(workerRef,routingKey,reason)
 local offer=self._offers[routingKey]; if not offer or offer.workerRef~=workerRef then return Result.err(Codes.AGENCY_NOT_FOUND or Codes.REPOSITORY_NOT_FOUND,'agency booking offer was not found') end
 if offer.status~='OFFERED' then return Result.err(Codes.AGENCY_CONFLICT or Codes.WORKER_MODE_CONFLICT,'agency booking offer is no longer open') end
 local out={routingKey=offer.routingKey,agencyKey=offer.agencyKey,workerRef=workerRef,status='DECLINED',reason=text(reason) and reason or nil}; self._offers[routingKey]=out; return Result.ok(out,{declined=true})
end
NightShift.Services.AgencyBooking=Service; NightShift.AgencyBookingService=Service
