-- Persistent-object portion of the directory service. Transport and disk I/O
-- are injected by the parent directory process.
local Object = require "multiplayer.p2p.objects"
local Expiry = require "multiplayer.p2p.object_expiry"
local Wormholes = require "multiplayer.p2p.wormhole_objects"

local service = {}
service.__index = service

local function count ( values )
   local total=0
   for _id in pairs(values) do total=total+1 end
   return total
end

function service.new ( options )
   options=options or {}
   return setmetatable({
      node_id=assert(options.node_id),
      values=options.values or {},
      send=assert(options.send),
      dirty=options.dirty or function() end,
      now=options.now or os.time,
      subscriptions={},
   },service)
end

function service:disconnect ( peer )
   self.subscriptions[peer]=nil
end

function service:result ( peer, request, action, ok, code, object_id, revision )
   return self.send(peer,{
      type="object_result",
      node=self.node_id,
      request=request,
      action=action,
      ok=ok and 1 or 0,
      code=code,
      object_id=object_id,
      revision=revision,
   })
end

function service:push_entry ( object )
   local packed=assert(Object.encode(object))
   for peer,system_name in pairs(self.subscriptions) do
      if Object.visible_in(object,system_name) then
         self.send(peer,{type="object_entry",node=self.node_id,
            request=0,object=packed})
      end
   end
end

function service:push_delete ( object )
   for peer,system_name in pairs(self.subscriptions) do
      if Object.visible_in(object,system_name) then
         self.send(peer,{type="object_deleted",node=self.node_id,
            object_id=object.id,revision=object.revision})
      end
   end
end

function service:prune ()
   local stamp=math.floor(self.now())
   local expired={}
   for id,object in pairs(self.values) do
      if Expiry.expired(object,stamp) then
         expired[#expired+1]={id=id,object=object}
      end
   end
   table.sort(expired,function(a,b) return a.id<b.id end)
   if #expired==0 then return 0 end
   for _index,entry in ipairs(expired) do
      self.values[entry.id]=nil
      self:push_delete(entry.object)
   end
   self.dirty()
   return #expired
end

function service:query ( peer, message )
   self:prune()
   self.subscriptions[peer]=message.system
   local matches={}
   for _id,object in pairs(self.values) do
      if Object.visible_in(object,message.system) then matches[#matches+1]=object end
   end
   table.sort(matches,function(a,b) return a.id<b.id end)
   for _index,object in ipairs(matches) do
      self.send(peer,{type="object_entry",node=self.node_id,
         request=message.request,object=assert(Object.encode(object))})
   end
   return self.send(peer,{type="object_done",node=self.node_id,
      request=message.request,count=#matches,system=message.system})
end

function service:create ( peer, node, message )
   self:prune()
   if count(self.values)>=Object.MAX_OBJECTS then
      return self:result(peer,message.request,"create",false,"capacity",
         message.object_id or "-",1)
   end
   local object,err=Object.decode(message.object)
   if not object then
      return self:result(peer,message.request,"create",false,"invalid",
         message.object_id or "-",1)
   end
   if message.object_id~=object.id then
      return self:result(peer,message.request,"create",false,"invalid",
         message.object_id or "-",1)
   end
   object,err=Object.policy_create(object,node,self.values)
   if not object then
      local code=err=="system occupied" and "occupied"
         or err=="object id already exists" and "duplicate" or "forbidden"
      return self:result(peer,message.request,"create",false,code,
         message.object_id,1)
   end
   if Wormholes.is_wormhole(object) and Wormholes.any(self.values) then
      return self:result(peer,message.request,"create",false,"occupied",
         object.id,object.revision)
   end
   if object.kind=="message_buoy"
         and self.subscriptions[peer]~=object.endpoints[1].system then
      return self:result(peer,message.request,"create",false,"forbidden",
         object.id,object.revision)
   end
   if Wormholes.is_wormhole(object)
         and not Wormholes.visible_in(object,self.subscriptions[peer]) then
      return self:result(peer,message.request,"create",false,"forbidden",
         object.id,object.revision)
   end
   -- The validated logical object is installed in one assignment. Multi-mouth
   -- objects therefore cannot be observed or persisted half-created.
   object.created=math.floor(self.now())
   object.revision=1
   self.values[object.id]=object
   self.dirty()
   self:result(peer,message.request,"create",true,"created",
      object.id,object.revision)
   self:push_entry(object)
   return true
end

function service:delete ( peer, node, message )
   local object=self.values[message.object_id]
   if not object then
      return self:result(peer,message.request,"delete",true,"not_found",
         message.object_id,message.revision or 1)
   end
   local ok=Object.policy_delete(object,node)
   if not ok then
      return self:result(peer,message.request,"delete",false,"forbidden",
         object.id,object.revision)
   end
   self.values[object.id]=nil
   self.dirty()
   self:result(peer,message.request,"delete",true,"deleted",
      object.id,object.revision)
   self:push_delete(object)
   return true
end

function service:receive ( peer, node, message )
   if message.type=="object_query" then return self:query(peer,message) end
   if message.type=="object_create" then return self:create(peer,node,message) end
   if message.type=="object_delete" then return self:delete(peer,node,message) end
end

function service:dump ()
   return self.values
end

return service
