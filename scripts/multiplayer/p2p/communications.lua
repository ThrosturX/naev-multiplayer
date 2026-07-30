-- Passive communications-outfit links. Directory discovery is MP2P/1 and
-- each selected system is observed through an ordinary MP2G/2 gameplay peer.
-- luacheck: globals naev player system rnd _ pilot
local directory_codec = require "multiplayer.p2p.codec"
local gameplay_codec = require "multiplayer.p2p.gameplay_codec"
local Object = require "multiplayer.p2p.objects"
local enet = require "enet"
local fmt = require "format"

local communications = {}

local SHORT_RANGE = 2
local EXTENDED_RANGE = 5
local WIDE_SYSTEM_CAP = 8
local MAX_EVENTS_PER_UPDATE = 24
local MAX_OUTBOX = 16
local DIRECTORY_REFRESH = 30
local DIRECTORY_RECONNECT = 5
local DIRECTORY_TIMEOUT = 8
local TARGET_QUERY_INTERVAL = 5
local TARGET_RECONNECT = 2
local TARGET_TIMEOUT = 8
local TARGET_IDLE_TIMEOUT = 12
local CAPABILITY_REFRESH = 1
local CANONICAL_CHANNEL = 2
local TRANSMITTER_SHIP = "Distress Beacon"

local OUTFIT_SNIFFER = "Communications Sniffer"
local OUTFIT_SHORT = "Short-Range Communications Sniffer"
local OUTFIT_WIDE = "Wide-Area Communications Sniffer"
local OUTFIT_SUITE = "Augmented Communications Suite"
local OUTFIT_EXTENDED = "Extended Communications Suite"

local runtime
local remote_senders = {}
local selected_systems = {}

local function now ()
   return naev.ticks()
end

local function display_text ( text )
   return tostring(text):gsub("#","＃")
end

local function fitted_capabilities ()
   local p=player.pilot()
   if not p or not p:exists() then return end
   local capabilities={}
   local fitted=p:outfits()
   for slot in pairs(fitted) do
      local o=fitted[slot]
      local name=o and o:nameRaw()
      if name==OUTFIT_SNIFFER then
         capabilities.receive_relay=true
      elseif name==OUTFIT_SHORT then
         capabilities.receive_range=math.max(
            capabilities.receive_range or 0,SHORT_RANGE)
      elseif name==OUTFIT_WIDE then
         capabilities.receive_wide=true
      elseif name==OUTFIT_SUITE then
         capabilities.receive_range=math.max(
            capabilities.receive_range or 0,SHORT_RANGE)
         capabilities.send_range=math.max(
            capabilities.send_range or 0,SHORT_RANGE)
      elseif name==OUTFIT_EXTENDED then
         capabilities.receive_range=math.max(
            capabilities.receive_range or 0,EXTENDED_RANGE)
         capabilities.send_range=math.max(
            capabilities.send_range or 0,EXTENDED_RANGE)
      end
   end
   local actives=p:actives()
   for index=1,#actives do
      local active=actives[index]
      local name=active.outfit and active.outfit:nameRaw()
      if active.active==true
            and (name==OUTFIT_SUITE or name==OUTFIT_EXTENDED) then
         capabilities.transmit_active=true
      end
   end
   if next(capabilities) then return capabilities end
end

local function capability_key ( capabilities )
   return table.concat({
      capabilities.receive_relay and "1" or "0",
      tostring(capabilities.receive_range or 0),
      capabilities.receive_wide and "1" or "0",
      tostring(capabilities.send_range or 0),
   },":")
end

local function jump_distance ( current_name, source_name )
   local origin=system.exists(current_name)
   local source=system.exists(source_name)
   if not origin or not source then return end
   local distance=origin:jumpDist(source,false,true)
   if not distance or distance==math.huge then return end
   return math.floor(distance)
end

local function distance_sender ( distance, sender )
   if type(distance)~="number" then return display_text(sender) end
   return fmt.f(_("{sender} ({distance} {unit})"),{
      distance=distance,
      unit=distance==1 and _("jump") or _("jumps"),
      sender=display_text(sender),
   })
end

local function local_transmitter_owner ()
   local config=naev.cache().multiplayer_p2p_config
   local node=type(config)=="table" and config.node_id or nil
   if type(node)=="string" and node:match("^[%x]+$") then return node.."a" end
end

function communications.observe ( message, direct_name, current_name )
   if type(message)~="table" then return false end
   local kind=message.type
   if kind~="chat" and kind~="player_manifest" and kind~="leave" then
      return false
   end
   if player.isLanded() then return false end
   local capabilities=fitted_capabilities()
   if not capabilities then return false end

   if kind=="player_manifest" then
      if type(message.owner)=="string" and type(message.name)=="string"
            and message.name~="" then
         remote_senders[message.owner]={
            name=message.name,
            augmented=type(message.origin)=="string"
               and message.origin:match("%.communications$")~=nil,
         }
      end
      return false
   elseif kind=="leave" then
      if type(message.owner)=="string" then remote_senders[message.owner]=nil end
      return false
   elseif type(message.system)~="string"
         or type(message.text)~="string" then return false end

   if message.owner==local_transmitter_owner() then return false end
   if type(current_name)~="string" or current_name==""
         or message.system==current_name then return false end

   local accepted=capabilities.receive_relay
      and selected_systems[message.system]==true
   if not accepted and capabilities.receive_range then
      local distance=jump_distance(current_name,message.system)
      accepted=distance~=nil and distance<=capabilities.receive_range
   end
   if not accepted and capabilities.receive_wide then
      accepted=selected_systems[message.system]==true
   end
   if not accepted then return false end

   local record=remote_senders[message.owner]
   local sender=record and record.name or direct_name or _("Unknown transmitter")
   local label=record and record.augmented and display_text(sender)
      or distance_sender(jump_distance(current_name,message.system),sender)
   player.msg(fmt.f(_("Comm {sender}> \"{text}\""),{
      sender=label,text=display_text(message.text),
   }))
   return true
end

local function valid_settings ( settings )
   return type(settings)=="table" and settings.enabled==true
      and type(settings.directory)=="string" and settings.directory~=""
      and type(settings.node_id)=="string"
      and settings.node_id:match("^[%x]+$")~=nil
end

local function local_sender_name ()
   local p=player.pilot()
   local name=p and p:name() or nil
   if type(name)=="string" and name~="" then return name end
   return player.name()
end

local function send_packet ( peer, message, wire_codec )
   local packet=(wire_codec or directory_codec).encode(message)
   if not packet or not peer then return false end
   peer:send(packet,0,"reliable")
   return true
end

local function owns_target_observation ( target, epoch )
   -- Only a claimed target can consume chat. Keeping ownership aligned with
   -- that receive guard leaves the ordinary gameplay path as an exact fallback.
   return target~=nil and target.peer~=nil
      and target.verified==true and target.ready==true
      and target.epoch==epoch
end

function communications.owns_observation ( message )
   if type(message)~="table" or type(message.system)~="string"
         or not runtime then return false end
   return owns_target_observation(
      runtime.targets[message.system],message.epoch)
end

communications._owns_target_observation=owns_target_observation

local function disconnect_peer ( peer )
   if not peer then return end
   local meta=runtime and runtime.peers[peer]
   if meta and meta.role=="directory" then
      runtime.directory_peer=nil
      runtime.directory_verified=false
      runtime.activity_deadline=nil
      runtime.scan_deadline=nil
   elseif meta and meta.target then
      local target=runtime.targets[meta.target]
      if target and target.peer==peer then
         target.peer=nil
         target.verified=false
         target.ready=false
         target.epoch=nil
         target.last_attempt=now()
      end
      if meta.endpoint and target then
         target.candidates[meta.endpoint]=nil
      end
   end
   if runtime then runtime.peers[peer]=nil end
   peer:disconnect_now()
end

local function stop_runtime ()
   if not runtime then return end
   for peer in pairs(runtime.peers) do peer:disconnect_now() end
   runtime=nil
   selected_systems={}
end

local function parse_activity ( entries )
   local systems={}
   if entries=="-" then return systems end
   for line in entries:gmatch("([^;]+)") do
      local encoded,active=line:match("^([^,]+),([01]),%d+$")
      if active=="1" then
         local name=directory_codec.unescape(encoded)
         if name and name~="" then systems[#systems+1]=name end
      end
   end
   return systems
end

local function send_directory_hello ( peer )
   return send_packet(peer,{
      type="hello",node=runtime.node,cap="player",
      name=runtime.name,endpoint=runtime.endpoint,
   })
end

local function send_gameplay_hello ( peer, name )
   return send_packet(peer,{
      type="hello",node=runtime.node,name=name or runtime.name,
      endpoint=runtime.endpoint,
   },gameplay_codec)
end

local function connect_directory ()
   if not runtime or runtime.directory_peer
         or now()-runtime.last_directory_attempt<DIRECTORY_RECONNECT then
      return false
   end
   local peer=runtime.host:connect(runtime.settings.directory,1)
   runtime.last_directory_attempt=now()
   if not peer then return false end
   runtime.directory_peer=peer
   runtime.peers[peer]={
      role="directory",verified=false,connected_at=now(),
   }
   return true
end

local function request_activity ()
   if not runtime.directory_verified or not runtime.directory_peer then
      return false
   end
   runtime.activity_deadline=now()+DIRECTORY_TIMEOUT
   runtime.last_activity_request=now()
   return send_packet(runtime.directory_peer,{
      type="activity_query",node=runtime.node,
   })
end

local function target_query ( target )
   if not target.peer or not target.verified then return false end
   target.visit=target.visit or string.format("%x%08x",
      math.max(0,math.floor(now()*1000)),rnd.rnd(0,0x7fffffff))
   target.last_query=now()
   return send_packet(target.peer,{
      type="query",node=runtime.node,system=target.system,
      visit=target.visit,
   },gameplay_codec)
end

local function bind_target_peer ( peer, meta, target )
   if target.peer and target.peer~=peer then return false end
   meta.target=target.system
   meta.bound=true
   target.peer=peer
   target.expected_node=target.expected_node or meta.node
   target.verified=true
   target.ready=false
   target.last_receive=now()
   target_query(target)
   return true
end

local function bind_waiting_peer ( target )
   if not target.expected_node then return false end
   for peer,meta in pairs(runtime.peers) do
      if meta.role=="target" and meta.verified and not meta.bound
            and meta.node==target.expected_node
            and (not meta.target or meta.target==target.system) then
         bind_target_peer(peer,meta,target)
         return true
      end
   end
   return false
end

local function connect_candidate ( target, endpoint, expected_node )
   if type(endpoint)~="string" or endpoint=="" then return end
   if expected_node and target.expected_node
         and expected_node~=target.expected_node then
      target.expected_node=expected_node
      target.candidates={}
      if target.peer then disconnect_peer(target.peer) end
   else
      target.expected_node=expected_node or target.expected_node
   end
   if target.peer and target.verified then return end
   if target.candidates[endpoint] then return end
   if bind_waiting_peer(target) then return end
   target.candidates[endpoint]=true
   local peer=runtime.host:connect(endpoint,CANONICAL_CHANNEL+1)
   if not peer then
      target.candidates[endpoint]=nil
      return
   end
   runtime.peers[peer]={
      role="target",target=target.system,expected_node=expected_node,
      endpoint=endpoint,verified=false,connected_at=now(),
   }
end

local function request_target ( target )
   if not runtime.directory_verified or not runtime.directory_peer then
      return false
   end
   target.last_attempt=now()
   return send_packet(runtime.directory_peer,{
      type="query",node=runtime.node,system=target.system,
   })
end

local function reconcile_targets ( wanted, send_wanted )
   selected_systems={}
   for system_name in pairs(wanted) do selected_systems[system_name]=true end
   runtime.send_systems=send_wanted

   local removed={}
   for system_name,target in pairs(runtime.targets) do
      if not wanted[system_name] then
         if target.peer then disconnect_peer(target.peer) end
         removed[#removed+1]=system_name
      end
   end
   for index=1,#removed do
      runtime.targets[removed[index]]=nil
   end
   for system_name in pairs(wanted) do
      if not runtime.targets[system_name] then
         runtime.targets[system_name]={
            system=system_name,candidates={},last_attempt=-math.huge,
            last_query=-math.huge,last_receive=now(),
         }
      end
      request_target(runtime.targets[system_name])
   end
   runtime.selection_ready=true
end

local function range_systems ( active, origin_name, distance_cap )
   local targets={}
   if not distance_cap then return targets end
   for index=1,#active do
      local system_name=active[index]
      if system_name~=origin_name then
         local distance=jump_distance(origin_name,system_name)
         if distance and distance<=distance_cap then
            targets[#targets+1]={system=system_name,distance=distance}
         end
      end
   end
   table.sort(targets,function ( a, b )
      if a.distance~=b.distance then return a.distance<b.distance end
      return a.system<b.system
   end)
   return targets
end

local function complete_selection ()
   local wanted={}
   local send_wanted={}
   local capabilities=runtime.capabilities
   local ranged=range_systems(runtime.active_systems,runtime.origin,
      capabilities.receive_range)
   for index=1,#ranged do wanted[ranged[index].system]=true end

   if capabilities.receive_wide then
      local count=0
      for index=1,#runtime.active_systems do
         local system_name=runtime.active_systems[index]
         if system_name~=runtime.origin and count<WIDE_SYSTEM_CAP then
            if not wanted[system_name] then wanted[system_name]=true end
            count=count+1
         end
      end
   end
   if capabilities.receive_relay then
      for system_name in pairs(runtime.relay_systems) do
         wanted[system_name]=true
      end
   end
   local send_targets=range_systems(runtime.active_systems,runtime.origin,
      capabilities.send_range)
   for index=1,#send_targets do
      local target=send_targets[index]
      wanted[target.system]=true
      send_wanted[target.system]=true
   end
   reconcile_targets(wanted,send_wanted)
end

local function start_relay_scan ()
   runtime.scan_index=0
   runtime.scan_request=runtime.scan_request+1
   runtime.relay_systems={}
   local function next_scan ()
      runtime.scan_index=runtime.scan_index+1
      runtime.scan_system=runtime.active_systems[runtime.scan_index]
      while runtime.scan_system==runtime.origin do
         runtime.scan_index=runtime.scan_index+1
         runtime.scan_system=runtime.active_systems[runtime.scan_index]
      end
      if not runtime.scan_system then
         runtime.scan_deadline=nil
         complete_selection()
         return
      end
      runtime.scan_request=runtime.scan_request+1
      runtime.scan_deadline=now()+DIRECTORY_TIMEOUT
      send_packet(runtime.directory_peer,{
         type="object_query",node=runtime.node,
         system=runtime.scan_system,request=runtime.scan_request,
      })
   end
   runtime.next_scan=next_scan
   next_scan()
end

local function handle_activity ( message )
   runtime.activity_deadline=nil
   runtime.active_systems=parse_activity(message.entries)
   if runtime.capabilities.receive_relay then start_relay_scan()
   else complete_selection() end
end

local function handle_directory_message ( peer, message, meta )
   if message.type=="hello" then
      if meta.verified or message.cap~="directory"
            or message.node==runtime.node then
         disconnect_peer(peer)
         return
      end
      meta.verified=true
      meta.node=message.node
      runtime.directory_verified=true
      request_activity()
      return
   end
   if not meta.verified or message.node~=meta.node then return end
   if message.type=="activity" then
      handle_activity(message)
      return
   elseif message.type=="object_entry" and runtime.scan_deadline
         and message.request==runtime.scan_request then
      local object=Object.decode(message.object)
      if object and object.kind=="signal_relay" then
         for index=1,#object.endpoints do
            local endpoint=object.endpoints[index]
            if endpoint.visible and endpoint.system==runtime.scan_system then
               runtime.relay_systems[runtime.scan_system]=true
               break
            end
         end
      end
      return
   elseif message.type=="object_done" and runtime.scan_deadline
         and message.request==runtime.scan_request
         and message.system==runtime.scan_system then
      runtime.next_scan()
      return
   end
   local target=message.system and runtime.targets[message.system]
   if not target then return end
   if message.type=="hint" then
      connect_candidate(target,message.endpoint,message.host)
   elseif message.type=="punch" then
      connect_candidate(target,message.endpoint,message.peer)
   end
end

local function handle_target_hello ( peer, message, meta )
   if message.node==runtime.node
         or (meta.expected_node and meta.expected_node~=message.node) then
      disconnect_peer(peer)
      return
   end
   meta.verified=true
   meta.node=message.node
   meta.name=message.name
   local target=meta.target and runtime.targets[meta.target]
   if target then
      if target.expected_node and target.expected_node~=message.node then
         disconnect_peer(peer)
         return
      end
      bind_target_peer(peer,meta,target)
      return
   end
   for system_name in pairs(runtime.targets) do
      local candidate=runtime.targets[system_name]
      if candidate.expected_node==message.node then
         bind_target_peer(peer,meta,candidate)
         return
      end
   end
end

local function handle_target_message ( peer, message, meta )
   if message.type=="hello" then
      handle_target_hello(peer,message,meta)
      return
   end
   if not meta.verified or message.node~=meta.node or not meta.bound
         or not meta.target then
      return
   end
   local target=runtime.targets[meta.target]
   if not target or target.peer~=peer or message.system~=target.system then
      return
   end
   target.last_receive=now()
   if message.type=="claim" then
      target.epoch=message.epoch
      target.ready=true
      return
   end
   if not target.ready or message.epoch~=target.epoch then return end
   if message.type=="player_manifest" or message.type=="chat"
         or message.type=="leave" then
      local direct_name=message.owner==meta.node and meta.name or nil
      communications.observe(message,direct_name,runtime.origin)
   end
end

local function handle_receive ( peer, packet )
   local meta=runtime.peers[peer]
   if not meta then return end
   local wire_codec=meta.role=="directory"
      and directory_codec or gameplay_codec
   local message=wire_codec.decode(packet)
   if not message then return end
   if meta.role=="directory" then
      handle_directory_message(peer,message,meta)
   else
      handle_target_message(peer,message,meta)
   end
end

local function handle_connect ( peer )
   local meta=runtime.peers[peer]
   if not meta then
      meta={
         role="target",verified=false,connected_at=now(),
      }
      runtime.peers[peer]=meta
   end
   if meta.role=="directory" then send_directory_hello(peer)
   else send_gameplay_hello(peer) end
end

local function handle_disconnect ( peer )
   local meta=runtime.peers[peer]
   if not meta then return end
   if meta.role=="directory" then
      runtime.directory_peer=nil
      runtime.directory_verified=false
      runtime.activity_deadline=nil
      runtime.scan_deadline=nil
      runtime.peers[peer]=nil
      return
   end
   if meta.target then
      local target=runtime.targets[meta.target]
      if target and target.peer==peer then
         target.peer=nil
         target.verified=false
         target.ready=false
         target.epoch=nil
         target.last_attempt=now()
      end
      if target and meta.endpoint then
         target.candidates[meta.endpoint]=nil
      end
      runtime.peers[peer]=nil
      if target and not target.peer then bind_waiting_peer(target) end
      return
   end
   runtime.peers[peer]=nil
end

local function gate_position ( origin_name, target_name )
   local origin=system.get(origin_name)
   local target=system.get(target_name)
   local path=origin:jumpPath(target)
   local final_jump=path and path[#path]
   if not final_jump then return 0,0 end
   return final_jump:reverse():pos():get()
end

local function publish_chat ( target, text )
   local visit=string.format("%x%08x",
      math.max(0,math.floor(now()*1000)),rnd.rnd(0,0x7fffffff))
   local x,y=gate_position(runtime.origin,target.system)
   local name=distance_sender(
      jump_distance(runtime.origin,target.system),runtime.name)
   local base={
      node=runtime.node,system=target.system,visit=visit,epoch=target.epoch,
   }
   local join={
      type="join",node=base.node,system=base.system,visit=base.visit,
      epoch=base.epoch,seq=1,
   }
   local manifest={
      type="player_manifest",node=base.node,system=base.system,
      visit=base.visit,epoch=base.epoch,owner=runtime.node,
      entity=runtime.node.."."..visit..".player",
      origin=runtime.node.."."..visit..".communications",
      ship=TRANSMITTER_SHIP,name=name,outfits="-",slots="-",
      weapsets="1:",x=x,y=y,vx=0,vy=0,dir=0,armour=100,shield=0,
      stress=0,energy=100,target="-",weapset=1,accel=0,turn=0,
      reverse=0,primary=0,secondary=0,
   }
   local chat={
      type="chat",node=base.node,system=base.system,visit=base.visit,
      epoch=base.epoch,owner=runtime.node,seq=2,text=text,
   }
   local leave={
      type="leave",node=base.node,system=base.system,visit=base.visit,
      epoch=base.epoch,owner=runtime.node,
   }
   return send_gameplay_hello(target.peer,name)
      and send_packet(target.peer,join,gameplay_codec)
      and send_packet(target.peer,manifest,gameplay_codec)
      and send_packet(target.peer,chat,gameplay_codec)
      and send_packet(target.peer,leave,gameplay_codec)
end

local function process_outbox ()
   if not runtime.selection_ready or #runtime.outbox==0 then return end
   local stamp=now()
   local pending={}
   for index=1,#runtime.outbox do
      local request=runtime.outbox[index]
      if not request.targets then
         request.targets={}
         for system_name in pairs(runtime.send_systems) do
            request.targets[system_name]=false
         end
      end
      local waiting=false
      for system_name,sent in pairs(request.targets) do
         if not sent then
            local target=runtime.targets[system_name]
            if target and target.ready
                  and publish_chat(target,request.text) then
               request.targets[system_name]=true
            else
               waiting=true
            end
         end
      end
      if waiting and stamp<request.deadline then
         pending[#pending+1]=request
      end
   end
   runtime.outbox=pending
end

local function start_runtime ( settings, capabilities, origin )
   local ok,host=pcall(enet.host_create,"*:0",64,CANONICAL_CHANNEL+1)
   if not ok or not host then
      print("P2P: communications unavailable: "..tostring(host))
      return nil
   end
   local node=settings.node_id.."a"
   runtime={
      host=host,endpoint=tostring(host:get_socket_address()),
      settings={directory=settings.directory,node_id=settings.node_id},
      node=node,origin=origin,
      name=local_sender_name(),
      capabilities=capabilities,capability_key=capability_key(capabilities),
      peers={},targets={},send_systems={},
      outbox={},active_systems={},relay_systems={},
      directory_peer=nil,directory_verified=false,
      last_directory_attempt=-math.huge,last_activity_request=-math.huge,
      scan_request=0,selection_ready=false,last_capability_check=now(),
   }
   connect_directory()
   return true
end

local function ensure_runtime ( settings, force )
   local current=system.cur()
   local origin=current and current:nameRaw()
   if player.isLanded() or not origin or not valid_settings(settings) then
      stop_runtime()
      return false
   end
   if runtime and not force
         and now()-runtime.last_capability_check<CAPABILITY_REFRESH then
      return true
   end
   local capabilities=fitted_capabilities()
   if not capabilities then
      stop_runtime()
      return false
   end
   if runtime and (runtime.settings.directory~=settings.directory
         or runtime.settings.node_id~=settings.node_id
         or runtime.origin~=origin) then
      stop_runtime()
   end
   if not runtime then return start_runtime(settings,capabilities,origin) end
   local new_key=capability_key(capabilities)
   runtime.capabilities=capabilities
   runtime.last_capability_check=now()
   if new_key~=runtime.capability_key then
      runtime.capability_key=new_key
      runtime.selection_ready=false
      request_activity()
   end
   return true
end

function communications.send ( text, settings )
   if type(text)~="string" or text=="" or not ensure_runtime(settings,true)
         or not runtime.capabilities.send_range then return false end
   if not runtime.capabilities.transmit_active then
      return false
   end
   if #runtime.outbox>=MAX_OUTBOX then
      return false
   end
   runtime.outbox[#runtime.outbox+1]={
      text=text:sub(1,1024),
      deadline=now()+TARGET_TIMEOUT,
   }
   process_outbox()
   return true
end

function communications.update ( settings )
   if not ensure_runtime(settings,false) or not runtime.host then
      return false
   end
   local current_runtime=runtime
   local processed=0
   local event=current_runtime.host:service(0)
   while event and runtime==current_runtime do
      processed=processed+1
      if event.type=="connect" then handle_connect(event.peer)
      elseif event.type=="receive" then handle_receive(event.peer,event.data)
      elseif event.type=="disconnect" then handle_disconnect(event.peer) end
      if processed>=MAX_EVENTS_PER_UPDATE then break end
      event=current_runtime.host:service(0)
   end
   if runtime~=current_runtime then return end

   local stamp=now()
   if not runtime.directory_peer then connect_directory()
   elseif runtime.directory_verified
         and stamp-runtime.last_activity_request>=DIRECTORY_REFRESH then
      request_activity()
   end
   if runtime.activity_deadline and stamp>=runtime.activity_deadline then
      disconnect_peer(runtime.directory_peer)
   end
   if runtime.scan_deadline and stamp>=runtime.scan_deadline then
      runtime.next_scan()
   end
   for system_name in pairs(runtime.targets) do
      local target=runtime.targets[system_name]
      if target.peer and target.verified
            and stamp-target.last_receive>=TARGET_IDLE_TIMEOUT then
         disconnect_peer(target.peer)
      elseif target.peer and target.verified
            and stamp-target.last_query>=TARGET_QUERY_INTERVAL then
         target_query(target)
      elseif not target.peer
            and stamp-target.last_attempt>=TARGET_RECONNECT then
         request_target(target)
      end
   end
   local stale={}
   for peer,meta in pairs(runtime.peers) do
      if meta.connected_at and stamp-meta.connected_at>=TARGET_TIMEOUT
            and (not meta.verified
               or (meta.role=="target" and not meta.bound)) then
         stale[#stale+1]=peer
      end
   end
   for index=1,#stale do disconnect_peer(stale[index]) end
   process_outbox()
end

function communications.stop ()
   stop_runtime()
   remote_senders={}
end

return communications
