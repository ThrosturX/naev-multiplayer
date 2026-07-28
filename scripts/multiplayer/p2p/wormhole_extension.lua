-- Isolated extension for directory-backed wormholes. It wraps the persistent-
-- object runtime without changing MP2P/1 or MP2G/2 message formats.
local Object = require "multiplayer.p2p.objects"
local Runtime = require "multiplayer.p2p.object_runtime"
local WormholeRuntime = require "multiplayer.p2p.wormhole_runtime"
local Wormholes = require "multiplayer.p2p.wormhole_objects"

if Runtime._wormhole_extension then return Runtime end
Runtime._wormhole_extension=true

local old_new=Runtime.new
local old_spawn=Runtime.spawn
local old_remove_local=Runtime.remove_local
local old_clear_local=Runtime.clear_local
local old_finish_query=Runtime.finish_query
local old_complete_create=Runtime.complete_create
local old_fail_create=Runtime.fail_create
local old_update=Runtime.update
local old_stop=Runtime.stop

local function refund ( pending )
   if not pending or pending.refunded then return end
   pending.refunded=true
   local p=player.pilot()
   if not p or not p:exists() then return end
   local fuel=tonumber(pending.fuel_cost) or 0
   local energy=tonumber(pending.energy_cost) or 0
   if fuel>0 then p:setFuel(p:fuel()+fuel) end
   if energy>0 then p:addEnergy(energy) end
end

local function failed_message ( reason )
   return string.format(_("%s Fuel and energy refunded."),reason)
end

local function finite_number ( value )
   value=tonumber(value)
   if value and value==value and value>-math.huge and value<math.huge then
      return value
   end
end

local function clear_pending_cache ( pending )
   local cache=naev.cache()
   if not pending or not cache.multiplayer_wormhole_pending
         or cache.multiplayer_wormhole_pending==pending.object_id then
      cache.multiplayer_wormhole_pending=nil
   end
end

local function activation_result ( pending, ok, started )
   if not pending or type(pending.activation_id)~="string" then return end
   local cache=naev.cache()
   local activation=cache.multiplayer_wormhole_activation_pending
   if type(activation)=="table" and activation.id==pending.activation_id then
      cache.multiplayer_wormhole_activation_pending=nil
   end
   cache.multiplayer_wormhole_activation_result={
      id=pending.activation_id,
      ok=ok and true or false,
      generator=pending.generator,
      started=started,
   }
end

local function generator_name ( pending )
   if pending and pending.generator=="emergency" then
      return _("Emergency wormhole")
   end
   return _("Unstable wormhole")
end

function Runtime.new ( options )
   local self=old_new(options)
   self.wormholes=WormholeRuntime.new{
      current_system=options.current_system,
   }
   return self
end

function Runtime:spawn ( object )
   if Wormholes.is_wormhole(object) then
      return self.wormholes:spawn(object)
   end
   return old_spawn(self,object)
end

function Runtime:remove_local ( object_id, explode )
   local wormhole_removed=self.wormholes:remove_object(object_id)
   return old_remove_local(self,object_id,explode) or wormhole_removed
end

function Runtime:clear_local ()
   old_clear_local(self)
   self.wormholes:leave()
end

function Runtime:finish_query ( message )
   local query=self.pending_requests[message.request]
   local valid=query and query.action=="query"
      and query.system==message.system
   if valid then
      local received=0
      for _object_id in pairs(query.objects) do received=received+1 end
      valid=received==message.count
   end
   old_finish_query(self,message)
   if valid then self.wormholes:reconcile(query.objects) end
end

function Runtime:complete_create ( request, pending, object_id )
   if pending.kind~="wormhole" then
      return old_complete_create(self,request,pending,object_id)
   end
   if pending.object and pending.object.id==object_id then
      self:remember(pending.object)
      self:spawn(pending.object)
   end
   self.pending_requests[request]=nil
   clear_pending_cache(pending)
   activation_result(pending,true,self.now())
   player.msg("#g"..string.format(_("%s opened to %s."),
      generator_name(pending),pending.target_system).."#0")
end

function Runtime:fail_create ( request, code )
   local pending=self.pending_requests[request]
   if not pending or pending.kind~="wormhole" then
      return old_fail_create(self,request,code)
   end
   self.pending_requests[request]=nil
   refund(pending)
   clear_pending_cache(pending)
   activation_result(pending,false)
   local reasons={
      occupied=_("Another wormhole is already active."),
      capacity=_("The directory cannot accept more persistent objects."),
      duplicate=_("That wormhole object ID is already in use."),
      forbidden=_("The directory rejected the wormhole."),
      invalid=_("The directory rejected invalid wormhole data."),
      timeout=_("Wormhole deployment timed out."),
      missing=_("The directory did not retain the wormhole."),
   }
   local reason=reasons[code] or _("Wormhole deployment failed.")
   player.msg("#r"..failed_message(reason).."#0")
end

function Runtime:create_wormhole ( request )
   local system_name=self:current_system()
   if not self.running or not system_name or player.isLanded() then
      return nil,_("Wormholes can only be opened during P2P spaceflight.")
   end
   if not self:peer() then
      return nil,_("The the device refuses to operate due to stale sensor readings.")
   end
   if type(request)~="table" or request.source_system~=system_name
         or type(request.target_system)~="string"
         or request.target_system=="" or request.target_system==system_name then
      return nil,_("Invalid wormhole destination.")
   end
   local object_kind=request.object_kind or "two_way_wormhole"
   if object_kind~="one_way_wormhole" and object_kind~="two_way_wormhole" then
      return nil,_("Invalid wormhole type.")
   end
   for _request,pending in pairs(self.pending_requests) do
      if pending.kind=="wormhole" then
         return nil,_("A wormhole deployment is already in progress.")
      end
   end

   local source_x=finite_number(request.source_x)
   local source_y=finite_number(request.source_y)
   local source_dir=finite_number(request.source_dir) or 0
   local target_x=finite_number(request.target_x)
   local target_y=finite_number(request.target_y)
   local target_dir=finite_number(request.target_dir) or 0
   if not source_x or not source_y or not target_x or not target_y then
      return nil,_("Invalid wormhole coordinates.")
   end

   local random={}
   for _index=1,4 do
      random[#random+1]=string.format("%08x",rnd.rnd(0,0x7fffffff))
   end
   local object_id=self.settings.node_id.."_"..table.concat(random)
   local first=object_id.."_a"
   local second=object_id.."_b"
   local endpoints
   if object_kind=="one_way_wormhole" then
      endpoints={
         {id=first,system=system_name,x=source_x,y=source_y,
            dir=source_dir,role="entrance",visible=true,target=second},
         {id=second,system=request.target_system,x=target_x,y=target_y,
            dir=target_dir,role="destination",visible=false},
      }
   else
      endpoints={
         {id=first,system=system_name,x=source_x,y=source_y,
            dir=source_dir,role="mouth",visible=true,target=second},
         {id=second,system=request.target_system,x=target_x,y=target_y,
            dir=target_dir,role="mouth",visible=true,target=first},
      }
   end
   local object={
      id=object_id,kind=object_kind,owner=self.settings.node_id,
      created=math.max(0,math.floor(self.now())),revision=1,data={},
      endpoints=endpoints,
   }
   local packed,err=Object.encode(object)
   if not packed then return nil,tostring(err) end
   local request_id=self:next_request()
   local pending={
      kind="wormhole",action="create",object_id=object_id,
      object_kind=object_kind,generator=request.generator,
      activation_id=request.activation_id,
      system=system_name,target_system=request.target_system,
      object=object,packed=packed,
      fuel_cost=tonumber(request.fuel_cost) or 0,
      energy_cost=tonumber(request.energy_cost) or 0,
      deadline=self.now()+10,
   }
   self.pending_requests[request_id]=pending
   naev.cache().multiplayer_wormhole_pending=object_id
   if not self:send_create(request_id,pending) then
      self.pending_requests[request_id]=nil
      clear_pending_cache(pending)
      return nil,_("The wormhole directory is unavailable.")
   end
   return true
end

local function consume_activation_request ( self )
   local cache=naev.cache()
   local request=cache.multiplayer_wormhole_request
   if not request then return end
   cache.multiplayer_wormhole_request=nil
   local ok,err=self:create_wormhole(request)
   if ok then return end
   refund(request)
   clear_pending_cache(request)
   activation_result(request,false)
   if err then player.msg("#r"..failed_message(tostring(err)).."#0") end
end

function Runtime:update ()
   consume_activation_request(self)
   return old_update(self)
end

function Runtime:stop ()
   for request,pending in pairs(self.pending_requests) do
      if pending.kind=="wormhole" then
         self.pending_requests[request]=nil
         refund(pending)
         clear_pending_cache(pending)
         activation_result(pending,false)
      end
   end
   return old_stop(self)
end

return Runtime
