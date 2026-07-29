-- Persistent space objects use their own MP2P/1 ENet client and never enter
-- the MP2G/2 gameplay registry.
local codec = require "multiplayer.p2p.codec"
local Object = require "multiplayer.p2p.objects"
local ObjectClient = require "multiplayer.p2p.object_client"
local Transient = require "multiplayer.p2p.transient"
local fmt = require "format"

local Runtime = {}
Runtime.__index = Runtime

local REQUEST_TIMEOUT = 10
local QUERY_TIMEOUT = 4
local RECONCILE_TIMEOUT = 30
local SUBSCRIPTION_REFRESH = 30
local BUOY_BROADCAST_INTERVAL = 30
local MAX_RELAY_QUEUE = 16

local buoy_faction
local relay_faction

local function exists ( p )
   return p~=nil and p:exists()
end

local function display_text ( text )
   return tostring(text):gsub("#","＃")
end

function Runtime.new ( options )
   return setmetatable({
      settings=assert(options.settings),
      now=assert(options.now),
      player_name=assert(options.player_name),
      current_system=assert(options.current_system),
      running=false,
      client=nil,
      local_objects={},
      local_pilot_ids={},
      local_order={},
      local_cursor=1,
      known_by_system={},
      pending_requests={},
      pending_deletes={},
      consumptions={},
      relay_queue={},
      request_sequence=0,
      subscription_system=nil,
      confirmed_system=nil,
      confirmed_at=-math.huge,
      last_retry=0,
   },Runtime)
end

function Runtime:peer ()
   if self.client and self.client:available() then return self.client end
end

function Runtime:publish_capability ()
   naev.cache().multiplayer_p2p_objects=
      self.running and self:peer()~=nil or false
end

function Runtime:next_request ()
   self.request_sequence=self.request_sequence+1
   return self.request_sequence
end

function Runtime:send ( message )
   local peer=self:peer()
   local packet=peer and codec.encode(message)
   if not packet then return false end
   peer:send(packet,0,"reliable")
   return true
end

function Runtime:physical_endpoint ( object )
   local system_name=self:current_system()
   if not system_name or (object.kind~="message_buoy"
         and object.kind~="signal_relay") then return end
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible and endpoint.system==system_name then
         return endpoint
      end
   end
end

function Runtime:remember ( object )
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible then
         local known=self.known_by_system[endpoint.system]
         if not known then
            known={}
            self.known_by_system[endpoint.system]=known
         end
         known[object.id]=object
      end
   end
end

function Runtime:forget ( object_id )
   for system_name,known in pairs(self.known_by_system) do
      known[object_id]=nil
      if next(known)==nil then self.known_by_system[system_name]=nil end
   end
end

local function remove_local_order ( self, object_id )
   for index,id in ipairs(self.local_order) do
      if id==object_id then
         table.remove(self.local_order,index)
         if index<self.local_cursor then
            self.local_cursor=self.local_cursor-1
         end
         break
      end
   end
   if self.local_cursor<1 or self.local_cursor>#self.local_order then
      self.local_cursor=1
   end
end

function Runtime:remove_local ( object_id, explode )
   local entry=self.local_objects[object_id]
   if not entry then return false end
   entry.removing=true
   if entry.hook then hook.rm(entry.hook) end
   if entry.local_id then self.local_pilot_ids[entry.local_id]=nil end
   self.local_objects[object_id]=nil
   remove_local_order(self,object_id)
   if exists(entry.pilot) then
      if explode then entry.pilot:explode()
      else entry.pilot:rm() end
   end
   return true
end

function Runtime:clear_local ()
   local ids={}
   for object_id in pairs(self.local_objects) do ids[#ids+1]=object_id end
   for _index,object_id in ipairs(ids) do self:remove_local(object_id,false) end
end

function Runtime:spawn ( object )
   local endpoint=self:physical_endpoint(object)
   if not endpoint then return false end
   local old=self.local_objects[object.id]
   if old and old.object.revision>=object.revision
         and exists(old.pilot) then return true end
   if old then self:remove_local(object.id,false) end
   local ship_name,display_name,fac
   if object.kind=="message_buoy" then
      ship_name="Message Buoy"
      display_name="Message Buoy"
      if not buoy_faction then
         buoy_faction=faction.dynAdd(nil,"P2P Message Buoys","Message Buoys",
            {ai="dummy",clear_allies=true,clear_enemies=true})
      end
      fac=buoy_faction
   elseif object.kind=="signal_relay" then
      ship_name="Signal Relay"
      display_name="Signal Relay"
      if not relay_faction then
         relay_faction=faction.dynAdd(nil,"P2P Signal Relays","Signal Relays",
            {ai="dummy",clear_allies=true,clear_enemies=true})
      end
      fac=relay_faction
   else
      return false
   end
   local p=pilot.add(ship_name,fac,
      vec2.new(endpoint.x,endpoint.y),display_name,
      {ai="dummy",naked=true})
   if not p then return false end
   p:setDir(endpoint.dir)
   p:setFriendly(true)
   -- Persistent objects are peer-trusted, not gameplay-host authoritative.
   -- Any participant may destroy its local copy; the exact-ID directory
   -- deletion then removes every other copy idempotently.
   p:setVisplayer(true)
   p:setHilight(true)
   local local_id=tostring(p:id())
   local entry={
      object=object,pilot=p,local_id=local_id,
      announce_at=object.kind=="message_buoy" and self.now()+1 or nil,
   }
   self.local_objects[object.id]=entry
   self.local_pilot_ids[local_id]=object.id
   self.local_order[#self.local_order+1]=object.id
   entry.hook=hook.pilot(p,"death","P2P_OBJECT_DESTROYED",object.id)
   return true
end

function Runtime:spawn_known ( system_name )
   for _object_id,object in pairs(self.known_by_system[system_name] or {}) do
      self:spawn(object)
   end
end

function Runtime:entity_for_pilot ( p )
   if not exists(p) then return nil end
   return self.local_pilot_ids[tostring(p:id())]
end

function Runtime:pilot_for_id ( object_id )
   local entry=self.local_objects[object_id]
   if entry and exists(entry.pilot) then return entry.pilot end
end

function Runtime:signal_relay_pilot ()
   local selected_id,selected
   for object_id,entry in pairs(self.local_objects) do
      if entry.object.kind=="signal_relay" and exists(entry.pilot)
            and not entry.pilot:disabled()
            and (not selected_id or object_id<selected_id) then
         selected_id=object_id
         selected=entry.pilot
      end
   end
   return selected
end

function Runtime:chat_pilot ( manifest )
   if manifest and manifest.ship=="Signal Relay"
         and type(manifest.origin)=="string"
         and manifest.origin:match("%.relay$") then
      return self:signal_relay_pilot()
   end
end

function Runtime:state_entry ( object_id )
   local entry=self.local_objects[object_id]
   if entry and exists(entry.pilot) then return entry end
end

function Runtime:next_state_pilot ()
   local count=#self.local_order
   if count==0 then return end
   if self.local_cursor>count then self.local_cursor=1 end
   local object_id=self.local_order[self.local_cursor]
   self.local_cursor=self.local_cursor%count+1
   local entry=self.local_objects[object_id]
   if entry and exists(entry.pilot) then
      return object_id,entry.pilot
   end
end

function Runtime:complete_create ( request, pending, object_id )
   if pending.object and pending.object.id==object_id then
      self:remember(pending.object)
      self:spawn(pending.object)
   end
   self.pending_requests[request]=nil
   if pending.consume_outfit then
      self.consumptions[#self.consumptions+1]={
         slot=pending.slot,outfit=pending.consume_outfit,
      }
   end
   local relay=pending.object and pending.object.kind=="signal_relay"
   player.msg("#g"..(relay
      and _("Signal relay deployed.")
      or _("Message buoy deployed.")).."#0")
end

function Runtime:fail_create ( request, code )
   local pending=self.pending_requests[request]
   self.pending_requests[request]=nil
   local relay=pending and pending.object
      and pending.object.kind=="signal_relay"
   local reasons=relay and {
      capacity=_("The directory cannot accept more persistent objects."),
      duplicate=_("That object ID is already in use."),
      forbidden=_("The directory rejected the signal relay."),
      invalid=_("The directory rejected invalid signal relay data."),
      timeout=_("Signal relay deployment timed out."),
      missing=_("The directory did not retain the signal relay."),
   } or {
      occupied=_("This system already has a message buoy."),
      capacity=_("The directory cannot accept more persistent objects."),
      duplicate=_("That object ID is already in use."),
      forbidden=_("The directory rejected the message buoy."),
      invalid=_("The directory rejected invalid buoy data."),
      timeout=_("Message buoy deployment timed out."),
      missing=_("The directory did not retain the message buoy."),
   }
   player.msg("#r"..(reasons[code] or (relay
      and _("Signal relay deployment failed.")
      or _("Message buoy deployment failed."))).."#0")
end

function Runtime:reconcile_create ( object )
   if object.owner~=self.settings.node_id then return end
   for request,pending in pairs(self.pending_requests) do
      if (pending.action=="create" or pending.action=="create_reconcile")
            and pending.object_id==object.id and pending.system
            and Object.visible_in(object,pending.system) then
         self:complete_create(request,pending,object.id)
         return true
      end
   end
end

function Runtime:apply_entry ( message )
   local object=Object.decode(message.object)
   if not object then return end
   self:reconcile_create(object)
   if message.request==0 then
      self:remember(object)
      self:spawn(object)
      return
   end
   local pending=self.pending_requests[message.request]
   if not pending or pending.action~="query"
         or not Object.visible_in(object,pending.system) then return end
   pending.objects[object.id]=object
end

function Runtime:send_create ( request, pending )
   if not self:peer() then return false end
   pending.action="create"
   pending.deadline=self.now()+REQUEST_TIMEOUT
   if self:send{
         type="object_create",node=self.settings.node_id,
         request=request,object_id=pending.object_id,
         object=pending.packed,
      } then return true end
   pending.action="create_wait_delete"
   pending.deadline=self.now()+RECONCILE_TIMEOUT
   return false
end

function Runtime:query ()
   local system_name=self:current_system()
   if not self:peer() or not system_name then return false end
   for _request,pending in pairs(self.pending_requests) do
      if pending.action=="query" and pending.system==system_name then
         return false
      end
   end
   local request=self:next_request()
   self.pending_requests[request]={
      action="query",system=system_name,objects={},
      deadline=self.now()+QUERY_TIMEOUT,
   }
   self:send{
      type="object_query",node=self.settings.node_id,
      system=system_name,request=request,
   }
   return true
end

function Runtime:finish_query ( message )
   local pending=self.pending_requests[message.request]
   if not pending or pending.action~="query"
         or pending.system~=message.system then return end
   local received=0
   for _object_id in pairs(pending.objects) do received=received+1 end
   if received~=message.count then
      self.pending_requests[message.request]=nil
      self.confirmed_system=nil
      self.confirmed_at=-math.huge
      if self.client then self.client:invalidate() end
      return
   end
   self.pending_requests[message.request]=nil
   local occupied=false
   for _object_id,object in pairs(pending.objects) do
      if object.kind=="message_buoy"
            and Object.visible_in(object,pending.system) then
         occupied=true
         break
      end
   end
   local creations={}
   for request,creation in pairs(self.pending_requests) do
      if creation.action=="create_reconcile"
            and creation.system==message.system then
         creations[#creations+1]={request=request,pending=creation}
      end
   end
   for _index,creation in ipairs(creations) do
      local object=creation.pending.object
      if object and object.kind=="message_buoy" and occupied then
         self:fail_create(creation.request,"occupied")
      else
         self:send_create(creation.request,creation.pending)
      end
   end
   local previously_known=self.known_by_system[message.system] or {}
   for object_id in pairs(previously_known) do
      if not pending.objects[object_id] then self:forget(object_id) end
   end
   self.known_by_system[message.system]=nil
   for _object_id,object in pairs(pending.objects) do self:remember(object) end
   if self.subscription_system==message.system then
      self.confirmed_system=message.system
      self.confirmed_at=self.now()
   end
   if self:current_system()~=message.system then return end
   local stale={}
   for object_id in pairs(self.local_objects) do
      if not pending.objects[object_id] then stale[#stale+1]=object_id end
   end
   for _index,object_id in ipairs(stale) do
      self:remove_local(object_id,true)
   end
   for _object_id,object in pairs(pending.objects) do self:spawn(object) end
end

function Runtime:has_pending_delete ( system_name )
   for _object_id,entry in pairs(self.pending_deletes) do
      if not entry.system or entry.system==system_name then return true end
   end
   return false
end

function Runtime:send_pending_deletes ()
   if not self:peer() then return end
   for object_id,entry in pairs(self.pending_deletes) do
      if not entry.sent then
         local request=self:next_request()
         entry.sent=true
         entry.request=request
         self.pending_requests[request]={
            action="delete",object_id=object_id,
            deadline=self.now()+REQUEST_TIMEOUT,
         }
         self:send{
            type="object_delete",node=self.settings.node_id,
            request=request,object_id=object_id,
         }
      end
   end
end

function Runtime:send_waiting_creates ()
   if not self:peer() then return end
   for request,pending in pairs(self.pending_requests) do
      if pending.action=="create_wait_delete"
            and not self:has_pending_delete(pending.system) then
         self:send_create(request,pending)
      end
   end
end

function Runtime:apply_result ( message )
   local pending=self.pending_requests[message.request]
   if not pending then return end
   if pending.action=="create" or pending.action=="create_reconcile" then
      if message.action~="create"
            or message.object_id~=pending.object_id then return end
      if message.ok==1 then
         if pending.object then pending.object.revision=message.revision end
         self:complete_create(message.request,pending,message.object_id)
      else
         self:fail_create(message.request,message.code)
      end
   elseif pending.action=="delete" then
      if message.action~="delete"
            or message.object_id~=pending.object_id then return end
      self.pending_requests[message.request]=nil
      local queued=self.pending_deletes[pending.object_id]
      if message.ok==1 then
         self.pending_deletes[pending.object_id]=nil
         self:send_waiting_creates()
      elseif queued then
         queued.sent=false
      end
   end
end

function Runtime:on_message ( message )
   if message.type=="object_entry" then
      self:apply_entry(message)
   elseif message.type=="object_done" then
      self:finish_query(message)
   elseif message.type=="object_deleted" then
      self:forget(message.object_id)
      self:remove_local(message.object_id,true)
      self.pending_deletes[message.object_id]=nil
      self:send_waiting_creates()
   elseif message.type=="object_result" then
      self:apply_result(message)
   end
end

function Runtime:on_disconnect ()
   for request,pending in pairs(self.pending_requests) do
      if pending.action=="create" then
         pending.action="create_reconcile"
         pending.deadline=self.now()+RECONCILE_TIMEOUT
      elseif pending.action=="query" then
         self.pending_requests[request]=nil
      elseif pending.action=="delete" then
         self.pending_requests[request]=nil
         local queued=self.pending_deletes[pending.object_id]
         if queued then queued.sent=false; queued.request=nil end
      end
   end
   self.confirmed_system=nil
   self.confirmed_at=-math.huge
   self:publish_capability()
end

function Runtime:ensure_subscription ()
   if not self.subscription_system
         or self:current_system()~=self.subscription_system then return end
   if self.confirmed_system==self.subscription_system
         and self.now()-self.confirmed_at<SUBSCRIPTION_REFRESH then return end
   self:query()
end

function Runtime:process_deadlines ( stamp )
   local expired={}
   for request,pending in pairs(self.pending_requests) do
      if stamp>=pending.deadline then expired[#expired+1]=request end
   end
   for _index,request in ipairs(expired) do
      local pending=self.pending_requests[request]
      if pending and (pending.action=="query" or pending.action=="create"
            or pending.action=="delete")
            and self.client and self.client:available() then
         self.client:invalidate()
         return
      end
   end
   for _index,request in ipairs(expired) do
      local pending=self.pending_requests[request]
      if pending then
         if pending.action=="create" then
            pending.action="create_reconcile"
            pending.deadline=stamp+RECONCILE_TIMEOUT
            self:query()
         elseif pending.action=="create_reconcile" then
            pending.deadline=stamp+RECONCILE_TIMEOUT
            self:query()
         elseif pending.action=="create_wait_delete" then
            pending.deadline=stamp+RECONCILE_TIMEOUT
            self:send_waiting_creates()
         elseif pending.action=="delete" then
            self.pending_requests[request]=nil
            local queued=self.pending_deletes[pending.object_id]
            if queued then queued.sent=false; queued.request=nil end
         else
            self.pending_requests[request]=nil
         end
      end
   end
   if stamp-self.last_retry>=1 then
      self.last_retry=stamp
      self:send_pending_deletes()
      self:send_waiting_creates()
   end
end

function Runtime:start ()
   if self.running then return true end
   self.running=true
   if self.settings.directory~="" then
      self.client=ObjectClient.new{
         endpoint=self.settings.directory,
         node=self.settings.node_id,
         name=self.player_name(),
         now=self.now,
         on_ready=function ()
            self:publish_capability()
            self:send_pending_deletes()
            self.confirmed_system=nil
            self.confirmed_at=-math.huge
            self:ensure_subscription()
            self:send_waiting_creates()
         end,
         on_message=function ( message ) self:on_message(message) end,
         on_disconnect=function () self:on_disconnect() end,
      }
      local ok,err=self.client:start()
      if not ok then
         print("P2P: "..tostring(err))
         self.client=nil
      end
   end
   self:publish_capability()
   return true
end

function Runtime:stop ()
   Transient.stop("signal_relay")
   self.relay_queue={}
   self:clear_local()
   if self.client then self.client:stop() end
   self.client=nil
   self.running=false
   self.subscription_system=nil
   self.confirmed_system=nil
   self:publish_capability()
end

function Runtime:enter ( system_name )
   self.subscription_system=system_name
   self.confirmed_system=nil
   self.confirmed_at=-math.huge
   self:spawn_known(system_name)
   self:ensure_subscription()
end

function Runtime:leave ()
   Transient.stop("signal_relay")
   self.relay_queue={}
   self.subscription_system=nil
   self.confirmed_system=nil
   self.confirmed_at=-math.huge
   self:clear_local()
   for request,pending in pairs(self.pending_requests) do
      if pending.action=="query" then self.pending_requests[request]=nil end
   end
end

function Runtime:update ()
   if not self.running then return false end
   if self.client then self.client:update() end
   local stamp=self.now()
   self:process_deadlines(stamp)
   self:ensure_subscription()
   local missing={}
   for object_id,entry in pairs(self.local_objects) do
      if not exists(entry.pilot) then
         missing[#missing+1]={object_id=object_id,object=entry.object}
      elseif entry.announce_at and stamp>=entry.announce_at then
         entry.pilot:broadcast(
            display_text(entry.object.data.text),true)
         entry.announce_at=stamp+BUOY_BROADCAST_INTERVAL
      end
   end
   for _index,entry in ipairs(missing) do
      self:remove_local(entry.object_id,false)
      self:spawn(entry.object)
   end
   return true
end

function Runtime:pending ()
   return self.running and (next(self.pending_requests)~=nil
      or next(self.pending_deletes)~=nil
      or #self.relay_queue>0 or Transient.active("signal_relay"))
end

function Runtime:update_signal_relay ()
   if not self.running then return false end
   if Transient.active("signal_relay") then Transient.update() end
   if not Transient.active() then self:start_relay_chat() end
   return #self.relay_queue>0 or Transient.active("signal_relay")
end

function Runtime:take_object_consumptions ()
   local queue=self.consumptions
   self.consumptions={}
   return queue
end

local function relay_target_systems ( origin, systems )
   local targets={}
   local seen={}
   for _index,system_name in ipairs(systems) do
      if system_name~=origin and not seen[system_name] then
         seen[system_name]=true
         targets[#targets+1]=system_name
      end
   end
   table.sort(targets)
   return targets
end

local function relay_object ( packed, system_name, selected )
   local object=Object.decode(packed)
   if not object or object.kind~="signal_relay" then return selected end
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible and endpoint.system==system_name
            and (not selected or object.id<selected.object_id) then
         return {
            object_id=object.id,system=system_name,
            x=endpoint.x,y=endpoint.y,dir=endpoint.dir,
         }
      end
   end
   return selected
end

function Runtime:start_relay_chat ()
   if Transient.active() or #self.relay_queue==0 then return false end
   local request=table.remove(self.relay_queue,1)
   local ok,err=Transient.start{
      kind="signal_relay",
      directory=self.settings.directory,
      node_id=self.settings.node_id,
      node_suffix="c",
      origin_suffix=".relay",
      ship="Signal Relay",
      name="Signal Relay",
      text=request.text,
      target_systems=function ( systems )
         return relay_target_systems(request.origin,systems)
      end,
      inspect_object=relay_object,
      position=function ( target )
         return target.x,target.y,target.dir
      end,
      on_error=function ( message )
         print("P2P: signal relay: "..tostring(message))
      end,
      unsupported=_("The multiplayer directory does not support signal relays."),
   }
   if not ok and err then
      print("P2P: signal relay: "..tostring(err))
      return false
   end
   return true
end

function Runtime:relay_chat ( text )
   local origin=self:current_system()
   if type(text)~="string" or text=="" or not origin
         or not self:signal_relay_pilot() then return false end
   if #self.relay_queue>=MAX_RELAY_QUEUE then
      print("P2P: signal relay queue is full")
      return false
   end
   self.relay_queue[#self.relay_queue+1]={
      origin=origin,
      text=fmt.f(_("[{system}] {captain}: {text}"),{
         system=_(origin),captain=player.name(),text=text,
      }):sub(1,1024),
   }
   self:start_relay_chat()
   return true
end

function Runtime:create_message_buoy ( text, slot )
   local system_name=self:current_system()
   if not self.running or not system_name or player.isLanded() then
      return nil,_("Message buoys can only be deployed during P2P spaceflight.")
   end
   if type(text)~="string" then return nil,_("Invalid message.") end
   text=text:match("^%s*(.-)%s*$")
   if text=="" or #text>96 or text:find("[%z\1-\31\127]") then
      return nil,_("Enter a message without control characters.")
   end
   slot=tonumber(slot)
   local pp=player.pilot()
   local current=slot and pp:outfitSlot(slot) or nil
   if not current or current:nameRaw()~="Message Buoy" then
      return nil,_("The fitted message buoy could not be found.")
   end
   if not self:peer() then
      return nil,_("The configured directory does not support persistent objects.")
   end
   for _request,pending in pairs(self.pending_requests) do
      if (pending.action=="create" or pending.action=="create_reconcile"
            or pending.action=="create_wait_delete")
            and pending.system==system_name then
         return nil,_("A message buoy deployment is already in progress.")
      end
   end
   local random={}
   for _index=1,4 do
      random[#random+1]=string.format("%08x",rnd.rnd(0,0x7fffffff))
   end
   local object_id=self.settings.node_id.."_"..table.concat(random)
   local x,y=pp:pos():get()
   local object={
      id=object_id,kind="message_buoy",owner=self.settings.node_id,
      created=math.max(0,math.floor(self.now())),revision=1,
      data={text=text,captain=player.name()},
      endpoints={{
         id=object_id.."_physical",system=system_name,
         x=x,y=y,dir=pp:dir(),role="physical",visible=true,
      }},
   }
   local packed,err=Object.encode(object)
   if not packed then return nil,tostring(err) end
   local request=self:next_request()
   local waiting=self:has_pending_delete(system_name)
   self.pending_requests[request]={
      action=waiting and "create_wait_delete" or "create",
      object_id=object_id,slot=slot,consume_outfit="Message Buoy",
      system=system_name,object=object,packed=packed,
      deadline=self.now()+(waiting and RECONCILE_TIMEOUT
         or REQUEST_TIMEOUT),
   }
   if waiting then
      player.msg(_("Waiting for the destroyed message buoy to be removed…"))
   elseif not self:send_create(request,self.pending_requests[request]) then
      self.pending_requests[request]=nil
      return nil,_("The message buoy directory is unavailable.")
   end
   return true
end

function Runtime:create_signal_relay ( slot )
   local system_name=self:current_system()
   if not self.running or not system_name or player.isLanded() then
      return nil,_("Signal relays can only be deployed during P2P spaceflight.")
   end
   slot=tonumber(slot)
   local pp=player.pilot()
   local current=slot and pp:outfitSlot(slot) or nil
   if not current or current:nameRaw()~="Signal Relay" then
      return nil,_("The fitted signal relay could not be found.")
   end
   if not self:peer() then
      return nil,_("The configured directory does not support persistent objects.")
   end
   if self.confirmed_system~=system_name then
      self:ensure_subscription()
      return nil,_("Signal relay data for this system is still synchronizing.")
   end
   for _object_id,object in pairs(self.known_by_system[system_name] or {}) do
      if object.kind=="signal_relay" then
         return nil,_("This system already has a signal relay.")
      end
   end
   for _request,pending in pairs(self.pending_requests) do
      if (pending.action=="create" or pending.action=="create_reconcile"
            or pending.action=="create_wait_delete")
            and pending.system==system_name then
         return nil,_("A persistent-object deployment is already in progress.")
      end
   end
   local random={}
   for _index=1,4 do
      random[#random+1]=string.format("%08x",rnd.rnd(0,0x7fffffff))
   end
   local object_id=self.settings.node_id.."_"..table.concat(random)
   local x,y=pp:pos():get()
   local object={
      id=object_id,kind="signal_relay",owner=self.settings.node_id,
      created=math.max(0,math.floor(self.now())),revision=1,data={},
      endpoints={{
         id=object_id.."_physical",system=system_name,
         x=x,y=y,dir=pp:dir(),role="physical",visible=true,
      }},
   }
   local packed,err=Object.encode(object)
   if not packed then return nil,tostring(err) end
   local request=self:next_request()
   self.pending_requests[request]={
      action="create",object_id=object_id,slot=slot,
      consume_outfit="Signal Relay",system=system_name,
      object=object,packed=packed,deadline=self.now()+REQUEST_TIMEOUT,
   }
   if not self:send_create(request,self.pending_requests[request]) then
      self.pending_requests[request]=nil
      return nil,_("The signal relay directory is unavailable.")
   end
   return true
end

function Runtime:object_destroyed ( object_id, destroyed_pilot )
   local entry=self.local_objects[object_id]
   if not entry or entry.removing
         or (destroyed_pilot and entry.pilot~=destroyed_pilot) then
      return false
   end
   if entry.hook then hook.rm(entry.hook) end
   if entry.local_id then self.local_pilot_ids[entry.local_id]=nil end
   self.local_objects[object_id]=nil
   remove_local_order(self,object_id)
   self:forget(object_id)
   local endpoint=self:physical_endpoint(entry.object)
   self.pending_deletes[object_id]={
      sent=false,system=endpoint and endpoint.system,
   }
   self:send_pending_deletes()
   return true
end

return Runtime
