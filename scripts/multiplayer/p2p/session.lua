-- MP2G/2 host-star gameplay runtime. Directory discovery stays on MP2P/1 and
-- persistent objects stay on their independent ObjectRuntime transport.
local directory_codec = require "multiplayer.p2p.codec"
local gameplay_codec = require "multiplayer.p2p.gameplay_codec"
local core = require "multiplayer.p2p.core"
local reconcile = require "multiplayer.p2p.reconcile"
local identity = require "multiplayer.p2p.identity"
local status = require "multiplayer.p2p.status"
local ObjectRuntime = require "multiplayer.p2p.object_runtime"
local communications = require "multiplayer.p2p.communications"
local enet = require "enet"
local ai_setup = require "ai.core.setup"

local MAX_EVENTS_PER_FRAME = 40
local HANDSHAKE_TIMEOUT = 10
local TRANSPORT_IDLE_TIMEOUT = 7
local DIRECTORY_RESPONSE_TIMEOUT = 10
local WORLD_INTERVAL = 1/15
local WORLD_CHANNEL = 1
local CANONICAL_CHANNEL = 2
local HEARTBEAT_INTERVAL = 1
local CLAIM_INTERVAL = 5
local LIVENESS_INTERVAL = 1
local REDIAL_INTERVAL = 2
local MANIFEST_INTERVAL = 0.1
local MANIFEST_QUERY_COOLDOWN = 1
local HOST_ALONE_GRACE = 6
local AGGRESSION_GRACE = 20
local ACTIVITY_QUERY_INTERVAL = 30
local ACTIVITY_RETENTION = 15*60
local AMBIENT_INSPECTION_CAP = 4
local PARTICIPANT_VISIBILITY_CAP = 8
local RECONCILE_DISTANCE = 2000
local RECONCILE_POSITION_BIAS = 0.5
-- ENet's default MTU is 1392 bytes and Naev's Lua binding does not expose
-- unreliable fragmentation. Leave room for protocol and path overhead.
local WORLD_PACKET_BUDGET = 1200

local session = {
   running=false,
   peers={},
   endpoints={},
   peer_meta={},
   players={},
   npcs={},
   craft={},
   player_manifests={},
   player_states={},
   dead_players={},
   outfit_messages={},
   present_players={},
   host_welcomed={},
   greeted_hosts={},
   authority={},
   authority_by_local={},
   origins={},
   replica_by_local={},
   generation=0,
   sequence=0,
   manifest_cache={},
   manifest_order={},
   manifest_cursor=1,
   manifest_queries={},
   pending_states={},
   pending_state_count=0,
   npc_announcement_queue={},
   npc_announcement_seen={},
   npc_order={},
   npc_order_seen={},
   npc_cursor=1,
   owned_order={},
   owned_cursor=1,
   priority_queues={{},{},{}},
   priority_seen={{},{},{}},
   priority_cursor={1,1,1},
   target_interests={},
   interest_entities={},
   interest_order={},
   interest_seen={},
   activity={},
   activity_received=0,
   encode_errors={},
   npc_factions={},
   npc_faction_counter=0,
   player_state_keys={
      "x","y","vx","vy","dir","armour","shield","stress","energy",
      "target","weapset","accel","turn","reverse","primary","secondary",
   },
   last_activity_query=0,
   directory_probe_deadline=nil,
   indicators=status.new(function () return player.pilot() end),
}

local function now ()
   return naev.ticks()
end

local function exists ( p )
   return p~=nil and p:exists()
end

local function local_player_name ()
   local p=player.pilot()
   local name=exists(p) and p:name() or nil
   if type(name)=="string" and name~="" then return name end
   return player.name()
end

local function display_text ( text )
   return tostring(text):gsub("#","＃")
end

local function random_id ()
   local parts={}
   for _index=1,4 do
      parts[#parts+1]=string.format("%08x",rnd.rnd(0,0x7fffffff))
   end
   return table.concat(parts)
end

local function normalize_endpoint ( endpoint )
   if type(endpoint)~="string" then return nil end
   endpoint=endpoint:match("^%s*(.-)%s*$")
   if endpoint=="" then return "" end
   local host,port=endpoint:match("^([^%s:]+)%s*:%s*(%d+)$")
   if not host then host,port=endpoint:match("^(%S+)%s+(%d+)$") end
   port=tonumber(port)
   if not host or not port or port<1 or port>65535 then return nil end
   return host..":"..tostring(math.floor(port))
end

session.normalize_endpoint=normalize_endpoint

function session.defaults ( settings )
   settings=settings or {}
   settings.enabled=settings.enabled==true
   settings.listen_port=math.max(0,
      math.min(65535,tonumber(settings.listen_port) or 0))
   local directory=settings.directory==nil
      and "79.76.110.205:60939" or settings.directory
   settings.directory=normalize_endpoint(directory) or ""
   local bootstrap={}
   for _index,endpoint in ipairs(settings.bootstrap or {}) do
      local normalized=normalize_endpoint(endpoint)
      if normalized and normalized~="" then bootstrap[#bootstrap+1]=normalized end
   end
   settings.bootstrap=bootstrap
   settings.recent=settings.recent or {}
   settings.node_id=settings.node_id or random_id()
   return settings
end

function session.get_settings ()
   return session.settings
end

local function current_system ()
   return session.machine and session.machine.system or nil
end

local function is_host ()
   return session.machine and session.machine.state=="host"
end

local function local_entity ()
   return session.settings.node_id.."."..tostring(session.visit or "0")..".player"
end

local function clear_local_controls ()
   local cache=naev.cache()
   cache.accel=0
   cache.left=0
   cache.right=0
   cache.reverse=0
   cache.primary=0
   cache.secondary=0
   session.input_down={}
end

local function set_ambient_spawning ( enabled )
   enabled=enabled==true
   if session.ambient_spawning==enabled then return end
   pilot.toggleSpawn(enabled)
   session.ambient_spawning=enabled
end

local function lock_autonav ( locked )
   if locked then
      if not session.autonav_locked then session.autonav_locked=true end
      naev.keyEnable("speed",false)
      session.enforce_time_controls()
   else
      if not session.autonav_locked then return end
      session.autonav_locked=nil
      naev.keyEnable("speed",true)
      player.autonavSetSpeed()
      player.setSpeed()
   end
end

local function has_remote_member ()
   if not session.machine then return false end
   for node in pairs(session.machine.members) do
      if node~=session.settings.node_id then return true end
   end
   return false
end

local function no_other_players_discovered ( current )
   if has_remote_member() then return false end
   for _peer,meta in pairs(session.peer_meta) do
      if meta.verified and meta.protocol=="gameplay" then return false end
   end
   for _index,entry in ipairs(session.activity or {}) do
      if entry.active and entry.system~=current then return false end
   end
   return true
end

local function refresh_time_controls ( stamp )
   if not current_system() then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   local unresolved=session.machine.state=="discovering"
      or session.machine.state=="recovering"
   local remote=has_remote_member() or session.machine.state=="guest"
   if unresolved or remote then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(true)
      return
   end
   if not is_host() then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(true)
      return
   end
   stamp=stamp or now()
   if session.skip_host_grace then
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   session.solo_since=session.solo_since or stamp
   local deadline=session.solo_since+HOST_ALONE_GRACE
   session.indicators:host_alone(deadline,stamp)
   lock_autonav(stamp<deadline)
end

local function endpoint_valid ( endpoint )
   return normalize_endpoint(endpoint)==endpoint
end

local function endpoint_is_local_listener ( endpoint )
   if not session.endpoint then return false end
   local host,port=endpoint:match("^([^:]+):(%d+)$")
   local own_port=session.endpoint:match(":(%d+)$")
   if not port or port~=own_port then return false end
   host=host:lower()
   return host=="localhost" or host=="127.0.0.1" or host=="0.0.0.0"
end

local function reject_peer ( peer, reason, quiet )
   local endpoint=session.peers[peer]
   local meta=session.peer_meta[peer]
   if meta and meta.protocol=="gameplay" and session.machine
         and session.machine.state=="guest"
         and meta.node==session.machine.host then
      session.needs_host_join=true
   end
   if not quiet then print("P2P: rejected peer: "..tostring(reason)) end
   peer:disconnect_now()
   session.peers[peer]=nil
   session.peer_meta[peer]=nil
   if endpoint then session.endpoints[endpoint]=nil end
end

local function encode_packet ( codec, message )
   local packet,err=codec.encode(message)
   if packet then return packet end
   local signature=table.concat({
      tostring(codec.VERSION),tostring(message and message.type),tostring(err),
   },":")
   if not session.encode_errors[signature] then
      session.encode_errors[signature]=true
      print("P2P: unable to encode "..tostring(codec.VERSION).." "
         ..tostring(message and message.type)..": "..tostring(err))
   end
end

local function send_packet ( peer, codec, message, reliable )
   if not peer then return false end
   local packet=encode_packet(codec,message)
   if not packet then return false end
   local result=peer:send(packet,0,reliable and "reliable" or "unreliable")
   return result and result>=0 or false
end

local function send_game ( peer, message, reliable )
   return send_packet(peer,gameplay_codec,message,reliable)
end

function session._send_game_state ( peer, message )
   if not peer then return false end
   local packet=encode_packet(gameplay_codec,message)
   if not packet then return false end
   local result=peer:send(packet,WORLD_CHANNEL,"unreliable")
   return result and result>=0 or false
end

local function send_directory ( peer, message )
   return send_packet(peer,directory_codec,message,true)
end

local function connect_endpoint ( endpoint, protocol, expected_node )
   if not endpoint_valid(endpoint) or endpoint_is_local_listener(endpoint)
         or session.endpoints[endpoint] then return false end
   local peer=session.host:connect(
      endpoint,protocol=="gameplay" and CANONICAL_CHANNEL+1 or 1)
   if not peer then return false end
   session.endpoints[endpoint]=peer
   session.peers[peer]=endpoint
   session.peer_meta[peer]={
      protocol=protocol,
      expected_node=expected_node,
      outbound=true,
      verified=false,
      connected_at=now(),
   }
   return true
end

local function connect_directory ()
   if session.settings.directory~="" then
      connect_endpoint(session.settings.directory,"directory")
   end
end

local function connect_gameplay ( endpoint, expected_node )
   return connect_endpoint(endpoint,"gameplay",expected_node)
end

local function connect_known_peers ()
   connect_directory()
   for _index,endpoint in ipairs(session.settings.bootstrap) do
      connect_gameplay(endpoint)
   end
   for _index,entry in ipairs(session.settings.recent) do
      connect_gameplay(entry.endpoint)
   end
end

local function peer_for_node ( node )
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="gameplay" and meta.verified
            and meta.node==node then return peer end
   end
end

local function connected_node ( node )
   for _peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="gameplay"
            and (meta.node==node or meta.expected_node==node) then
         return true
      end
   end
   return false
end

local function broadcast_gameplay ( message, reliable )
   local packet=encode_packet(gameplay_codec,message)
   if not packet then return false end
   session.host:broadcast(
      packet,CANONICAL_CHANNEL,reliable and "reliable" or "unreliable")
   return true
end

local function broadcast_world_packet ( packet )
   -- Gameplay peers negotiate channel 1 while the directory has only channel
   -- 0. ENet reuses one packet across all gameplay peers without leaking
   -- MP2G/2 traffic onto the directory connection. Receivers enforce the
   -- accepted host and authority epoch.
   session.host:broadcast(packet,WORLD_CHANNEL,"unreliable")
   return true
end

local function fanout_control ( message, except )
   local packet=encode_packet(gameplay_codec,message)
   if not packet then return false end
   local sent=false
   for peer,meta in pairs(session.peer_meta) do
      if peer~=except and meta.protocol=="gameplay" and meta.verified then
         local result=peer:send(packet,0,"reliable")
         if result and result>=0 then sent=true end
      end
   end
   return sent
end

local function send_host ( message, reliable )
   if not session.machine or session.machine.state~="guest"
         or not session.machine.host then return false end
   local peer=peer_for_node(session.machine.host)
   if not peer then
      local endpoint=session.member_endpoints
         and session.member_endpoints[session.machine.host]
      if endpoint then connect_gameplay(endpoint,session.machine.host) end
      return false
   end
   return send_game(peer,message,reliable)
end

local function gameplay_base ( kind )
   return {
      type=kind,
      node=session.settings.node_id,
      system=current_system(),
      visit=session.visit,
      epoch=session.machine and session.machine.claim or "-",
   }
end

local function directory_query ()
   if not current_system() then return end
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="directory" and meta.verified then
         send_directory(peer,{
            type="query",node=session.settings.node_id,
            system=current_system(),
         })
      end
   end
end

local function publish_directory_claim ()
   if not is_host() then return end
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="directory" and meta.verified then
         send_directory(peer,{
            type="claim",node=session.settings.node_id,
            system=current_system(),claim=session.machine.claim,
            endpoint=session.endpoint,
         })
      end
   end
end

local function publish_directory_leave ( system_name )
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="directory" and meta.verified then
         send_directory(peer,{
            type="leave",node=session.settings.node_id,system=system_name,
         })
      end
   end
end

local function outfit_names ( p )
   local names={}
   for _index,o in ipairs(p:outfitsList()) do
      names[#names+1]=gameplay_codec.escape(o:nameRaw())
   end
   return table.concat(names,",")
end

local function outfit_slots ( p )
   local slots={}
   for index,o in pairs(p:outfits()) do
      if type(index)=="number" and o then
         slots[#slots+1]={
            index=index,
            value=tostring(index)..":"
               ..gameplay_codec.escape(o:nameRaw()),
         }
      end
   end
   table.sort(slots,function ( a,b ) return a.index<b.index end)
   local values={}
   for index,entry in ipairs(slots) do values[index]=entry.value end
   return table.concat(values,",")
end

local function weapon_sets ( p )
   local sets={}
   for id=1,10 do
      local slots={}
      for _index,slot in ipairs(p:weapsetList(id)) do
         slot=tonumber(slot)
         if slot and slot>=1 and slot<=512 then
            slots[#slots+1]=tostring(math.floor(slot))
         end
      end
      sets[#sets+1]=tostring(id)..":"..table.concat(slots,".")
   end
   return table.concat(sets,";")
end

local function install_weapon_sets ( p, packed )
   if packed==nil then return end
   p:weapsetCleanup()
   local installed=p:outfits()
   for line in packed:gmatch("([^;]+)") do
      local id,slots=line:match("^(%d+):(.*)$")
      id=tonumber(id)
      if id and id>=1 and id<=10 then
         for value in slots:gmatch("(%d+)") do
            local slot=tonumber(value)
            if slot and slot>=1 and slot<=512 and installed[slot] then
               p:weapsetAdd(id,slot)
            end
         end
      end
   end
end

local function ship_fallback_names ( s )
   local names,seen={},{}
   local inherited=s:inherits()
   while inherited and #names<16 do
      local name=inherited:nameRaw()
      if type(name)~="string" or name=="" or seen[name] then break end
      seen[name]=true
      names[#names+1]=gameplay_codec.escape(name)
      inherited=inherited:inherits()
   end
   local base_type=s:baseType()
   if #names<16 and type(base_type)=="string" and base_type~=""
         and not seen[base_type] and ship.exists(base_type) then
      names[#names+1]=gameplay_codec.escape(base_type)
   end
   return table.concat(names,",")
end

local function resource_get ( getter, name )
   local ok,value=pcall(getter,name)
   if ok then return value end
end

local function resolve_proxy_ship ( message )
   if resource_get(ship.get,message.ship) then return message.ship,true end
   for encoded in (message.ship_fallbacks or ""):gmatch("([^,]+)") do
      local name=gameplay_codec.unescape(encoded)
      if name and resource_get(ship.get,name) then return name,true end
   end
   if resource_get(ship.get,"Plowshare") then return "Plowshare",false end
end

local function replica_outfit_allowed ( o )
   -- Fighter craft have their own owner-generated manifests. A replica carrier
   -- must never launch a second speculative copy.
   return o:type()~="Fighter Bay"
end

local function install_outfits ( p, message, compatible )
   local used_slots=false
   if not compatible then
      for item in (message.slots or ""):gmatch("([^,]+)") do
         local index,encoded=item:match("^(%d+):(.+)$")
         index=tonumber(index)
         local name=encoded and gameplay_codec.unescape(encoded)
         local o=name and outfit.exists(name) or nil
         if index and index>=1 and index<=512 and o
               and replica_outfit_allowed(o) then
            p:outfitAddSlot(o,index,true,true)
            used_slots=true
         end
      end
   end
   if used_slots then return end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=gameplay_codec.unescape(item)
      local o=name and outfit.exists(name) or nil
      if o and replica_outfit_allowed(o) then
         p:outfitAdd(o,1,true,compatible and false or nil)
      end
   end
end

local function pilot_owned ( p )
   if p:withPlayer() then return true end
   local seen={}
   while exists(p) and not seen[p] do
      seen[p]=true
      local leader=p:leader()
      if not leader then return false end
      if leader==player.pilot() then return true end
      p=leader
   end
   return false
end

local function local_id ( p )
   if exists(p) then return tostring(p:id()) end
   return nil
end

local function new_entity_id ( owner, p, kind )
   session.generation=session.generation+1
   return table.concat({
      owner,
      session.visit or "0",
      kind=="npc" and "n" or "c",
      tostring(session.generation),
      local_id(p) or "0",
   },".")
end

local function target_entity ( target )
   if not exists(target) then return "-" end
   if target==player.pilot() then return local_entity() end
   local id=local_id(target)
   local replica=session.replica_by_local[id]
   if replica then return replica end
   local authoritative=session.authority_by_local[id]
   if authoritative then return authoritative end
   local object_id=session.objects and session.objects:entity_for_pilot(target)
   return object_id or "-"
end

local function entity_pilot ( entity )
   if not entity or entity=="-" then return nil end
   if entity==local_entity() then return player.pilot() end
   for _id,entry in pairs(session.players) do
      if _id==entity and exists(entry.pilot) then return entry.pilot end
   end
   local entry=session.npcs[entity] or session.craft[entity]
      or session.authority[entity]
   if entry and exists(entry.pilot) then return entry.pilot end
   return session.objects and session.objects:pilot_for_id(entity) or nil
end

function session._local_accel_control ( p, manual, stamp, vx, vy )
   stamp=stamp or now()
   local speed=math.sqrt(vx*vx+vy*vy)
   if manual then
      session.local_motion_sample={
         stamp=stamp,vx=vx,vy=vy,speed=speed,inferred=false,
      }
      return 1
   end
   local sample=session.local_motion_sample
   if sample and stamp-sample.stamp<1/120 then
      return sample.inferred and 1 or 0
   end
   local inferred=false
   local autonav=player.autonav()
   if autonav then
      local dir=p:dir()
      local forward_x,forward_y=math.cos(dir),math.sin(dir)
      local forward_speed=vx*forward_x+vy*forward_y
      local drift_speed=p:speed()
      if sample then
         local elapsed=math.max(1/120,math.min(0.25,stamp-sample.stamp))
         local forward_accel=((vx-sample.vx)*forward_x
            +(vy-sample.vy)*forward_y)/elapsed
         local accel_threshold=math.max(1,p:accel()*0.05)
         inferred=forward_accel>accel_threshold
            or (speed>drift_speed+1
               and forward_speed>speed*0.25
               and speed>=sample.speed-math.max(1,p:accel()*elapsed*0.05))
      else
         inferred=speed>drift_speed+1 and forward_speed>speed*0.25
      end
   end
   session.local_motion_sample={
      stamp=stamp,vx=vx,vy=vy,speed=speed,inferred=inferred,
   }
   return inferred and 1 or 0
end

local function state_record ( p, entity, include_controls, stamp )
   local x,y=p:pos():get()
   local vx,vy=p:vel():get()
   local armour,shield,stress=p:health()
   local target=target_entity(p:target())
   local record={
      entity=entity,x=x,y=y,vx=vx,vy=vy,dir=p:dir(),
      armour=armour,shield=shield,stress=stress,energy=p:energy(),
      target=target,weapset=1,accel=0,turn=0,reverse=0,
      primary=0,secondary=0,
   }
   if include_controls then
      local cache=naev.cache()
      record.weapset=session.local_weapset or 1
      record.accel=session._local_accel_control(
         p,cache.accel and cache.accel~=0,stamp,vx,vy)
      record.turn=((cache.right and cache.right~=0) and 1 or 0)
         -((cache.left and cache.left~=0) and 1 or 0)
      record.reverse=(cache.reverse and cache.reverse~=0) and 1 or 0
      record.primary=(cache.primary and cache.primary~=0) and 1 or 0
      record.secondary=(cache.secondary and cache.secondary~=0) and 1 or 0
   end
   return record
end

local function pack_state ( record )
   return table.concat({
      record.entity,record.x,record.y,record.vx,record.vy,record.dir,
      record.armour,record.shield,record.stress,record.energy,
      record.target or "-",record.weapset or 1,record.accel or 0,
      record.turn or 0,record.reverse or 0,
      record.primary or 0,record.secondary or 0,
   },",")
end

local function unpack_state ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=17 or not fields[1]:match("^[%w_%.%-]+$") then return nil end
   local record={
      entity=fields[1],
      x=tonumber(fields[2]),y=tonumber(fields[3]),
      vx=tonumber(fields[4]),vy=tonumber(fields[5]),
      dir=tonumber(fields[6]),armour=tonumber(fields[7]),
      shield=tonumber(fields[8]),stress=tonumber(fields[9]),
      energy=tonumber(fields[10]),target=fields[11],
      weapset=tonumber(fields[12]),accel=tonumber(fields[13]),
      turn=tonumber(fields[14]),reverse=tonumber(fields[15]),
      primary=tonumber(fields[16]),secondary=tonumber(fields[17]),
   }
   for _index,key in ipairs({
      "x","y","vx","vy","dir","armour","shield","stress","energy",
      "weapset","accel","turn","reverse","primary","secondary",
   }) do
      local value=record[key]
      if not value or value~=value then return nil end
   end
   if math.abs(record.x)>1e9 or math.abs(record.y)>1e9
         or math.abs(record.vx)>1e7 or math.abs(record.vy)>1e7
         or math.abs(record.dir)>1e6
         or record.armour<0 or record.armour>1e9
         or record.shield<0 or record.shield>1e9
         or record.stress<0 or record.stress>1e9
         or record.energy<0 or record.energy>1e9 then return nil end
   if #record.entity>255 or #record.target>255
         or (record.target~="-"
            and not record.target:match("^[%w_%.%-]+$"))
         or record.weapset<1 or record.weapset>10
         or record.accel<0 or record.accel>1
         or record.turn< -1 or record.turn>1
         or record.reverse<0 or record.reverse>1
         or record.primary<0 or record.primary>1
         or record.secondary<0 or record.secondary>1 then return nil end
   return record
end

local function object_state_record ( p, entity )
   local x,y=p:pos():get()
   local vx,vy=p:vel():get()
   local armour,shield,stress=p:health()
   return {
      entity=entity,x=x,y=y,vx=vx,vy=vy,dir=p:dir(),
      armour=armour,shield=shield,stress=stress,
   }
end

local function pack_object_state ( record )
   return table.concat({
      record.entity,record.x,record.y,record.vx,record.vy,record.dir,
      record.armour,record.shield,record.stress,
   },",")
end

local function unpack_object_state ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=9 or not fields[1]:match("^[%w_%.%-]+$") then return nil end
   local record={
      entity=fields[1],
      x=tonumber(fields[2]),y=tonumber(fields[3]),
      vx=tonumber(fields[4]),vy=tonumber(fields[5]),
      dir=tonumber(fields[6]),
      armour=tonumber(fields[7]),shield=tonumber(fields[8]),
      stress=tonumber(fields[9]),
   }
   for _index,key in ipairs({
      "x","y","vx","vy","dir","armour","shield","stress",
   }) do
      local value=record[key]
      if not value or value~=value then return nil end
   end
   if #record.entity>255
         or math.abs(record.x)>1e9 or math.abs(record.y)>1e9
         or math.abs(record.vx)>1e7 or math.abs(record.vy)>1e7
         or math.abs(record.dir)>1e6
         or record.armour<0 or record.armour>1e9
         or record.shield<0 or record.shield>1e9
         or record.stress<0 or record.stress>1e9 then return nil end
   return record
end

local function player_manifest ()
   local p=player.pilot()
   if not exists(p) then return nil end
   local entity=local_entity()
   if session.dead_players[entity] then return nil end
   local record=state_record(p,entity,true)
   local current_ship=p:ship()
   local message=gameplay_base("player_manifest")
   message.owner=session.settings.node_id
   message.entity=entity
   message.origin=session.settings.node_id.."."..session.visit..".player"
   message.ship=current_ship:nameRaw()
   message.ship_fallbacks=ship_fallback_names(current_ship)
   message.name=local_player_name()
   message.outfits=outfit_names(p)
   if message.outfits=="" then message.outfits="-" end
   message.slots=outfit_slots(p)
   if message.slots=="" then message.slots="-" end
   message.weapsets=weapon_sets(p)
   if message.weapsets=="" then message.weapsets="-" end
   for key,value in pairs(record) do
      if key~="entity" then message[key]=value end
   end
   return message
end

local function authority_manifest ( entry )
   local p=entry.pilot
   if not exists(p) then return nil end
   local message=gameplay_base("entity_manifest")
   message.kind=entry.kind
   message.owner=entry.owner
   message.entity=entry.entity
   message.origin=entry.origin
   message.ship=p:ship():nameRaw()
   message.name=p:name()
   message.faction=p:faction():nameRaw()
   message.ai=entry.ai or p:ainame() or "dummy"
   message.outfits=outfit_names(p)
   if message.outfits=="" then message.outfits="-" end
   message.slots=outfit_slots(p)
   if message.slots=="" then message.slots="-" end
   local leader=p:leader()
   message.leader=exists(leader) and target_entity(leader) or "-"
   local record=state_record(p,entry.entity,false)
   for key,value in pairs(record) do
      if key~="entity" then message[key]=value end
   end
   return message
end

function session._pack_npc_announcement ( entry, record )
   local description=entry.description
   if not description then return nil end
   local slots=description.slots or "-"
   local outfits=slots~="-" and "-" or (description.outfits or "-")
   return table.concat({
      "n",pack_state(record),
      gameplay_codec.escape(description.owner),
      gameplay_codec.escape(description.origin),
      gameplay_codec.escape(description.ship),
      gameplay_codec.escape(description.name),
      gameplay_codec.escape(description.faction),
      gameplay_codec.escape(description.ai),
      gameplay_codec.escape(outfits),
      gameplay_codec.escape(slots),
      gameplay_codec.escape(description.leader or "-"),
   },",")
end

function session._unpack_npc_announcement ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=27 or fields[1]~="n" then return nil end
   local dynamic={}
   for index=2,18 do dynamic[#dynamic+1]=fields[index] end
   local record=unpack_state(table.concat(dynamic,","))
   if not record then return nil end
   local decoded={}
   for index=19,27 do
      decoded[index]=gameplay_codec.unescape(fields[index])
      if not decoded[index] then return nil end
   end
   local owner,origin,ship_name,name,faction_name,ai_name,
      outfits,slots,leader=decoded[19],decoded[20],decoded[21],
      decoded[22],decoded[23],decoded[24],decoded[25],decoded[26],decoded[27]
   if #owner<1 or #owner>64 or not owner:match("^[%x]+$")
         or #origin<1 or #origin>255
         or not origin:match("^[%w_%.%-]+$")
         or #ship_name<1 or #ship_name>240
         or ship_name:find("[%z\1-\31\127]")
         or #name<1 or #name>240 or name:find("[%z\1-\31\127]")
         or #faction_name<1 or #faction_name>240
         or faction_name:find("[%z\1-\31\127]")
         or #ai_name<1 or #ai_name>240
         or not ai_name:match("^[%w_%-]+$")
         or #outfits>12000 or outfits:find("[%z\1-\31\127]")
         or #slots>12000 or slots:find("[%z\1-\31\127]")
         or (leader~="-" and (#leader>255
            or not leader:match("^[%w_%.%-]+$"))) then
      return nil
   end
   return record,{
      kind="npc",owner=owner,entity=record.entity,origin=origin,
      ship=ship_name,name=name,faction=faction_name,ai=ai_name,
      outfits=outfits,slots=slots,leader=leader,
      x=record.x,y=record.y,vx=record.vx,vy=record.vy,dir=record.dir,
      armour=record.armour,shield=record.shield,stress=record.stress,
      energy=record.energy,target=record.target,weapset=record.weapset,
      accel=record.accel,turn=record.turn,reverse=record.reverse,
      primary=record.primary,secondary=record.secondary,
   }
end

local function canonical_copy ( message )
   local copy={}
   for key,value in pairs(message) do copy[key]=value end
   copy.node=session.settings.node_id
   copy.system=current_system()
   copy.visit=session.visit
   copy.epoch=session.machine.claim
   return copy
end

local player_limits={
   position_gain=1.5,correction_speed=400,velocity_rate=12,
   acceleration=2400,direction_rate=30,direction_speed=8,
   max_prediction=0,rest_source_speed=0,follow_velocity=true,
}
local npc_limits={
   position_gain=1.5,correction_speed=250,velocity_rate=8,
   acceleration=600,direction_rate=30,direction_speed=8,
   max_dt=0.25,max_prediction=0.125,prediction_fraction=0.5,
}
local craft_limits={
   position_gain=2,correction_speed=400,velocity_rate=10,
   acceleration=1200,direction_rate=30,direction_speed=8,
   max_dt=0.25,max_prediction=0.125,prediction_fraction=0.5,
}

local function reconcile_arrival ( entry, record, limits, stamp )
   local p=entry.pilot
   if not exists(p) then return false end
   stamp=stamp or now()
   local elapsed=math.max(1/60,
      math.min(0.25,stamp-(entry.last_record_at or stamp-1/15)))
   entry.last_record_at=stamp
   local prediction_age=math.min(
      limits.max_prediction or 0,
      elapsed*(limits.prediction_fraction or 0))
   local x,y=p:pos():get()
   local vx,vy=p:vel():get()
   local dir=p:dir()
   local wanted={
      x=record.x,y=record.y,vx=record.vx,vy=record.vy,dir=record.dir,
   }
   local catchup_x,catchup_y,catchup=
      reconcile.catchup_position(x,y,wanted.x,wanted.y,
         RECONCILE_DISTANCE,RECONCILE_POSITION_BIAS)
   if catchup then
      p:setPos(vec2.new(catchup_x,catchup_y))
      x,y=catchup_x,catchup_y
   end
   local corrected_vx,corrected_vy,corrected_dir=
      reconcile.steer_values(
         x,y,vx,vy,dir,wanted,elapsed,prediction_age,limits)
   local exact_rest=corrected_vx==0 and corrected_vy==0
      and (vx~=0 or vy~=0)
   if exact_rest or math.abs(corrected_vx-vx)>0.01
         or math.abs(corrected_vy-vy)>0.01 then
      p:setVel(vec2.new(corrected_vx,corrected_vy))
   end
   if math.abs(math.sin((corrected_dir-dir)/2))>0.00025 then
      p:setDir(corrected_dir)
   end
   return true
end

local function apply_health_energy ( entry, record )
   local p=entry.pilot
   entry.applied=entry.applied or {}
   local applied=entry.applied
   local armour,shield,stress=p:health()
   if math.abs(armour-record.armour)>0.01
         or math.abs(shield-record.shield)>0.01
         or math.abs(stress-record.stress)>0.01 then
      p:setHealth(record.armour,record.shield,record.stress)
   end
   if math.abs(p:energy()-record.energy)>0.01 then
      p:setEnergy(record.energy)
   end
   applied.armour=record.armour
   applied.shield=record.shield
   applied.stress=record.stress
   applied.energy=record.energy
end

local function mark_player_aggression ( owner )
   local manifest=session.player_manifests[owner]
   local entity=manifest and manifest.entity
   local entry=entity and session.players[entity]
   if not entry or not exists(entry.pilot) then return end
   local stamp=now()
   entry.last_aggression=stamp
   session.indicators:mark_aggression(stamp+AGGRESSION_GRACE,stamp)
   if not entry.hostile then
      entry.pilot:setHostile(true)
      entry.hostile=true
   end
end

local attack_tasks={
   attack=true,
   attack_forced=true,
   attack_forced_kill=true,
}

function session._sync_replica_attack_task ( entry, target )
   if not entry or entry.kind~="npc" or not exists(entry.pilot) then
      return false
   end
   local p=entry.pilot
   local task=p:taskname()
   if not attack_tasks[task] or p:taskdata()==target then return false end
   p:taskClear()
   if target then p:pushtask(task,target) end
   return true
end

local function apply_target ( entry, entity )
   local target=entity_pilot(entity)
   if entity~="-" and not target then return nil,false end
   local current=entry.pilot:target()
   if current and not exists(current) then current=nil end
   if current~=target then entry.pilot:setTarget(target) end
   session._sync_replica_attack_task(entry,target)
   entry.applied=entry.applied or {}
   entry.applied.target=entity
   return target,true
end

local function apply_player_controls ( entry, record )
   local p=entry.pilot
   local target=apply_target(entry,record.target)
   local memory=p:memory()
   local old_primary=memory.p2p_primary==true
   local old_secondary=memory.p2p_secondary==true
   memory.p2p_accel=record.accel==1 and 1 or 0
   memory.p2p_turn=math.max(-1,math.min(1,record.turn or 0))
   memory.p2p_reverse=record.reverse==1
   memory.p2p_primary=record.primary==1
   memory.p2p_secondary=record.secondary==1
   memory.p2p_weapset=record.weapset
   if memory.p2p_primary and not old_primary then
      memory.p2p_primary_edges=math.min(4,
         (memory.p2p_primary_edges or 0)+1)
      p:fillAmmo()
   end
   if memory.p2p_secondary and not old_secondary then
      memory.p2p_secondary_edges=math.min(4,
         (memory.p2p_secondary_edges or 0)+1)
      p:fillAmmo()
   end
   if target==player.pilot()
         and (memory.p2p_primary or memory.p2p_secondary) then
      mark_player_aggression(entry.owner)
   end
end

local function apply_player_record ( record, stamp, world_sequence )
   if record.entity==local_entity() then return true end
   if session.dead_players[record.entity] then return true end
   local entry=session.players[record.entity]
   if not entry or not exists(entry.pilot) then return false end
   if world_sequence
         and world_sequence<=(entry.world_sequence or -1) then return false end
   if world_sequence then entry.world_sequence=world_sequence end
   if not reconcile_arrival(entry,record,player_limits,stamp) then return false end
   apply_player_controls(entry,record)
   apply_health_energy(entry,record)
   return true
end

function session._apply_outfit_toggle ( message )
   if message.owner==session.settings.node_id then return true end
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then return false end
   local slot=math.floor(message.slot)
   entry.outfit_sequences=entry.outfit_sequences or {}
   if message.seq<=(entry.outfit_sequences[slot] or -1) then return false end
   local valid=false
   for _index,active in ipairs(entry.pilot:actives()) do
      if tonumber(active.slot)==slot then
         valid=true
         break
      end
   end
   if not valid then return nil,"invalid_slot" end
   entry.pilot:outfitToggle(slot,message.on==1)
   entry.outfit_sequences[slot]=message.seq
   return true
end

local function apply_entity_record ( record, stamp, world_sequence )
   if session.authority[record.entity] then return true end
   local entry=session.npcs[record.entity] or session.craft[record.entity]
   if not entry or not exists(entry.pilot) then return false end
   if world_sequence
         and world_sequence<=(entry.world_sequence or -1) then return false end
   if world_sequence then entry.world_sequence=world_sequence end
   local limits=entry.kind=="npc" and npc_limits or craft_limits
   if not reconcile_arrival(entry,record,limits,stamp) then return false end
   apply_health_energy(entry,record)
   apply_target(entry,record.target)
   return true
end

local function apply_object_state ( record, stamp, world_sequence )
   local entry=session.objects
      and session.objects:state_entry(record.entity)
   if not entry then return false end
   if world_sequence
         and world_sequence<=(entry.world_sequence or -1) then return false end
   if world_sequence then entry.world_sequence=world_sequence end
   if not reconcile_arrival(entry,record,npc_limits,stamp) then return false end
   local armour,shield,stress=entry.pilot:health()
   if math.abs(armour-record.armour)>0.01
         or math.abs(shield-record.shield)>0.01
         or math.abs(stress-record.stress)>0.01 then
      entry.pilot:setHealth(record.armour,record.shield,record.stress)
   end
   return true
end

local function remove_replica ( entity, removal )
   local entry=session.players[entity] or session.npcs[entity]
      or session.craft[entity]
   if not entry then return false end
   if entry.local_id and session.replica_by_local[entry.local_id]==entity then
      session.replica_by_local[entry.local_id]=nil
   end
   if entry.origin and session.origins[entry.origin]==entity then
      session.origins[entry.origin]=nil
   end
   session.players[entity]=nil
   session.npcs[entity]=nil
   session.craft[entity]=nil
   session.manifest_cache[entity]=nil
   if exists(entry.pilot) then
      if removal=="death" then
         -- pilot:explode() deletes immediately. Let Naev enter pilot_dead on
         -- its next update so all peers show the normal death animation.
         entry.pilot:setNoDeath(false)
         entry.pilot:setHealth(0,0,0)
      elseif removal then
         entry.pilot:explode()
      else
         entry.pilot:rm()
      end
   end
   return true
end

function session._mark_player_dead ( owner, entity )
   if type(owner)~="string" or type(entity)~="string"
         or session.dead_players[entity] then return false end
   session.dead_players[entity]=true
   session.player_states[owner]=nil
   session.outfit_messages[owner]=nil
   session.manifest_cache[entity]=nil
   session.manifest_queries[entity]=nil
   if session.pending_states[entity] then
      session.pending_states[entity]=nil
      session.pending_state_count=math.max(
         0,session.pending_state_count-1)
   end
   local local_player_entity=session.settings and session.visit
      and local_entity() or nil
   if entity~=local_player_entity then remove_replica(entity,"death") end
   return true
end

local player_faction
local craft_factions={}

local function owner_craft_faction ( owner )
   local fac=craft_factions[owner]
   if fac then return fac end
   local raw="P2P Craft "..owner
   fac=resource_get(faction.get,raw)
   if not fac then
      local display=session.identities
         and session.identities:display_name(owner) or owner
      fac=faction.dynAdd(nil,raw,(display or owner).." Craft",
         {ai="escort",clear_allies=true,clear_enemies=true})
   end
   craft_factions[owner]=fac
   return fac
end

function session._replica_npc_faction ( message )
   local fac=resource_get(faction.get,message.faction)
   if fac then return fac end
   local key=message.owner.."\0"..message.faction
   fac=session.npc_factions[key]
   if fac then return fac end
   session.npc_faction_counter=session.npc_faction_counter+1
   local raw="P2P NPC "..message.owner.." "
      ..tostring(session.npc_faction_counter)
   fac=faction.dynAdd(nil,raw,display_text(message.faction),{
      ai="dummy",clear_allies=true,clear_enemies=true,
   })
   session.npc_factions[key]=fac
   print("P2P: using a local replica faction for "
      ..display_text(message.faction))
   return fac
end

local function replace_origin_generation ( message )
   local old=session.origins[message.origin]
   if old and old~=message.entity then remove_replica(old,true) end
   session.origins[message.origin]=message.entity
end

local function remote_player_name ( owner, fallback )
   local name=session.identities
      and session.identities:display_name(owner) or nil
   return display_text(name or fallback or owner)
end

local function announce_player_join ( owner, fallback )
   if owner==session.settings.node_id or session.present_players[owner] then
      return
   end
   session.present_players[owner]=true
   local name=remote_player_name(owner,fallback)
   player.msg("#g"..string.format(_("%s joined the system."),name).."#0")
   print("P2P: "..name.." joined the system")
end

local function announce_player_leave ( owner )
   if owner==session.settings.node_id or not session.present_players[owner] then
      return
   end
   local name=remote_player_name(owner)
   session.present_players[owner]=nil
   player.msg("#o"..string.format(_("%s left the system."),name).."#0")
   print("P2P: "..name.." left the system")
end

local function introduction_text ( identify )
   local text="This is "
   if not identify then text="I am " end
   text=text..player.name()..", captain of "..local_player_name()
   if identify then return text..". Identify yourself." end
   return text.."!"
end

local function spawn_player_manifest ( message )
   if message.owner==session.settings.node_id then return true end
   if session.dead_players[message.entity] then return true end
   replace_origin_generation(message)
   local existing=session.players[message.entity]
   if existing and exists(existing.pilot) then
      existing.manifest=message
      announce_player_join(message.owner,message.name)
      return true
   end
   if existing then remove_replica(message.entity,false) end
   local proxy_ship,compatible=resolve_proxy_ship(message)
   if not proxy_ship then return false end
   if not player_faction then
      player_faction=faction.dynAdd(nil,"P2P Players","P2P Players",
         {ai="p2p_remote_control",clear_allies=true,clear_enemies=true})
   end
   local display=session.identities:display_name(message.owner)
      or display_text(message.name)
   local p=pilot.add(proxy_ship,player_faction,
      vec2.new(message.x or 0,message.y or 0),display,
      {ai="p2p_remote_control",naked=true})
   if not p then return false end
   install_outfits(p,message,not compatible)
   install_weapon_sets(p,message.weapsets)
   p:fillAmmo()
   p:setNoDeath(true)
   if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
   if message.dir then p:setDir(message.dir) end
   ai_setup.setup(p)
   local entry={
      kind="player",owner=message.owner,entity=message.entity,
      origin=message.origin,pilot=p,manifest=message,
      local_id=tostring(p:id()),applied={},
   }
   session.players[message.entity]=entry
   session.replica_by_local[entry.local_id]=message.entity
   if message.armour then
      apply_health_energy(entry,message)
      apply_player_controls(entry,message)
   end
   announce_player_join(message.owner,message.name)
   return true
end

local function resolve_waiting_leaders ( entity )
   local waiting=session.waiting_leaders[entity]
   if not waiting then return end
   session.waiting_leaders[entity]=nil
   local leader=entity_pilot(entity)
   if not leader then return end
   for child in pairs(waiting) do
      local entry=session.npcs[child] or session.craft[child]
      if entry and exists(entry.pilot) then entry.pilot:setLeader(leader) end
   end
end

local function bind_leader ( entry, leader_id )
   if not leader_id or leader_id=="-" then return end
   local leader=entity_pilot(leader_id)
   if leader then
      entry.pilot:setLeader(leader)
      return
   end
   local waiting=session.waiting_leaders[leader_id] or {}
   waiting[entry.entity]=true
   session.waiting_leaders[leader_id]=waiting
end

local function add_npc_order ( entity )
   if session.npc_order_seen[entity] then return end
   session.npc_order_seen[entity]=true
   session.npc_order[#session.npc_order+1]=entity
end

function session._apply_owned_craft_ai_policy ( p )
   -- Replicas are created before their network leader is bound, so set the
   -- lifecycle policy directly instead of relying on inheritance. Autonomous
   -- aggression is disabled on non-owner simulations; reliable e_attack
   -- orders still push their explicit forced-attack task.
   local memory=p:memory()
   memory.atk_kill=false
   memory.aggressive=false
end

function session._log_replica_failure ( message )
   local signature=table.concat({
      "replica",message.kind or "-",message.ship or "-",
      message.faction or "-",message.ai or "-",
   },":")
   if session.encode_errors[signature] then return end
   session.encode_errors[signature]=true
   print("P2P: unable to create "..tostring(message.kind)
      .." replica "..display_text(message.name or message.entity)
      .." (ship "..display_text(message.ship)
      ..", faction "..display_text(message.faction or "-")
      ..", AI "..display_text(message.ai or "-")..")")
end

local function spawn_entity_manifest ( message )
   if message.owner==session.settings.node_id then return true end
   replace_origin_generation(message)
   local container=message.kind=="npc" and session.npcs or session.craft
   local existing=container[message.entity]
   if existing and exists(existing.pilot) then
      if message.kind=="npc" then
         existing.description=message
         existing.cached_state=message
         existing.peer_owned=message.owner~=session.machine.host
      else
         existing.manifest=message
         session._apply_owned_craft_ai_policy(existing.pilot)
      end
      return true
   end
   if existing then remove_replica(message.entity,false) end
   if not resource_get(ship.get,message.ship) then return false end
   local fac
   if message.kind=="npc" then
      fac=session._replica_npc_faction(message)
   else
      fac=owner_craft_faction(message.owner)
   end
   if not fac then return false end
   local ai=message.kind=="npc" and message.ai or "escort"
   local p=pilot.add(message.ship,fac,
      vec2.new(message.x or 0,message.y or 0),message.name,
      {ai=ai,naked=true})
   if not p then return false end
   install_outfits(p,message,false)
   p:setNoDeath(true)
   if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
   if message.dir then p:setDir(message.dir) end
   ai_setup.setup(p)
   if message.kind=="craft" then session._apply_owned_craft_ai_policy(p) end
   local entry={
      kind=message.kind,owner=message.owner,entity=message.entity,
      origin=message.origin,pilot=p,
      local_id=tostring(p:id()),applied={},
   }
   if message.kind=="npc" then
      entry.description=message
      entry.cached_state=message
      entry.peer_owned=message.owner~=session.machine.host
      add_npc_order(message.entity)
   else
      entry.manifest=message
   end
   container[message.entity]=entry
   session.replica_by_local[entry.local_id]=message.entity
   if message.armour then apply_health_energy(entry,message) end
   bind_leader(entry,message.leader)
   resolve_waiting_leaders(message.entity)
   return true
end

local function remove_authority_hooks ( entry )
   for _index,h in ipairs(entry.hooks or {}) do hook.rm(h) end
   entry.hooks={}
end

local function unregister_authority ( entry )
   remove_authority_hooks(entry)
   if session.authority_by_local[entry.local_id]==entry.entity then
      session.authority_by_local[entry.local_id]=nil
   end
   if session.origins[entry.origin]==entry.entity then
      session.origins[entry.origin]=nil
   end
   session.manifest_cache[entry.entity]=nil
   session.authority[entry.entity]=nil
end

local function cache_manifest ( message )
   if not message or (message.type~="player_manifest"
         and message.type~="entity_manifest") then return false end
   if message.type=="player_manifest"
         and session.dead_players[message.entity] then return false end
   if message.type=="entity_manifest" and message.kind~="craft" then
      return false
   end
   local packet=encode_packet(gameplay_codec,message)
   if not packet then return false end
   if not session.manifest_cache[message.entity] then
      session.manifest_order[#session.manifest_order+1]=message.entity
   end
   local cached={message=message,packet=packet}
   session.manifest_cache[message.entity]=cached
   return cached
end

local function broadcast_manifest ( cached )
   if not cached then return false end
   session.host:broadcast(cached.packet,CANONICAL_CHANNEL,"reliable")
   return true
end

function session._refresh_player_manifest_state ( stored )
   if not stored then return nil end
   local message=canonical_copy(stored)
   local record=session.player_states[message.owner]
   if message.owner==session.settings.node_id then
      local p=player.pilot()
      if exists(p) then
         record=state_record(p,local_entity(),true)
      end
   end
   if record then
      for _index,key in ipairs(session.player_state_keys) do
         message[key]=record[key]
      end
   end
   return message
end

local function host_reliable ( message )
   return broadcast_gameplay(message,true)
end

local function publish_player_death ( owner, entity )
   if not session._mark_player_dead(owner,entity) then return false end
   session.sequence=session.sequence+1
   local message=gameplay_base("entity_remove")
   message.kind="player"
   message.owner=owner
   message.entity=entity
   message.seq=session.sequence
   message.reason="death"
   if is_host() then return host_reliable(message) end
   return send_host(message,true)
end

local function publish_entity_manifest ( entry )
   local message=authority_manifest(entry)
   if not message then return false end
   if entry.kind=="npc" then
      entry.description=message
   else
      entry.manifest=message
   end
   if is_host() then
      if entry.kind=="npc" then return true end
      return broadcast_manifest(cache_manifest(message))
   end
   return send_host(message,true)
end

local function register_authority ( p, kind, owner, origin, entity, peer_owned )
   if not exists(p) or p==player.pilot() then return nil end
   local id=local_id(p)
   if session.authority_by_local[id] or session.replica_by_local[id]
         or (session.objects and session.objects:entity_for_pilot(p)) then
      return nil
   end
   entity=entity or new_entity_id(owner,p,kind)
   origin=origin or owner.."."..session.visit.."."..kind.."."..id
   local entry={
      kind=kind,owner=owner,origin=origin,entity=entity,pilot=p,
      local_id=id,ai=p:ainame() or "dummy",hooks={},
      peer_owned=kind=="npc" and peer_owned==true,
   }
   session.authority[entity]=entry
   session.authority_by_local[id]=entity
   session.origins[origin]=entity
   if kind=="npc" then
      add_npc_order(entity)
      if not session.npc_announcement_seen[entity] then
         session.npc_announcement_seen[entity]=true
         session.npc_announcement_queue[
            #session.npc_announcement_queue+1]=entity
      end
   else
      session.world_craft_order[#session.world_craft_order+1]=entity
   end
   session.owned_order[#session.owned_order+1]=entity
   session.audit_order[#session.audit_order+1]=entity
   entry.hooks={
      hook.pilot(p,"death","P2P_SESSION_PILOT_DEATH",entity),
      hook.pilot(p,"jump","P2P_SESSION_PILOT_JUMP",entity),
      hook.pilot(p,"land","P2P_SESSION_PILOT_LAND",entity),
   }
   publish_entity_manifest(entry)
   return entry
end

function session._admit_local_pilot ( p )
   if not exists(p) or p==player.pilot() then return end
   local id=local_id(p)
   if not id or session.authority_by_local[id]
         or session.replica_by_local[id]
         or (session.objects and session.objects:entity_for_pilot(p)) then
      return
   end
   if pilot_owned(p) then
      return register_authority(p,"craft",session.settings.node_id)
   end
   if is_host() then
      return register_authority(p,"npc",session.settings.node_id)
   end
   if session.machine.state=="guest"
         or session.machine.state=="recovering" then
      return register_authority(
         p,"npc",session.settings.node_id,nil,nil,true)
   end
end

function session._admit_player_target ( p )
   if not exists(p) then return false end
   return session._admit_local_pilot(p:target())~=nil
end

local function broadcast_npc_announcement ( entry )
   if not entry or not exists(entry.pilot) or not entry.description then
      return false
   end
   local record=entry.cached_state
      or state_record(entry.pilot,entry.entity,false)
   local line=session._pack_npc_announcement(entry,record)
   if not line then return false end
   session.sequence=session.sequence+1
   local world=gameplay_base("world")
   world.seq=session.sequence
   local batches,err,oversized=gameplay_codec.encode_world_batches(world,{
      players={},entities={line},objects={},
   },WORLD_PACKET_BUDGET)
   if not batches then return false,err end
   for _index,batch in ipairs(batches) do
      host_reliable(batch.message)
   end
   for _index,packed in ipairs(oversized or {}) do
      local fallback=canonical_copy(world)
      fallback.players="-"
      fallback.entities=packed
      fallback.objects="-"
      host_reliable(fallback)
   end
   return true
end

function session.pilot_created ( p )
   if not session.running or not current_system() or not exists(p) then return end
   local id=local_id(p)
   if not id then return end
   session.pending_creations[id]=p
   if session.creation_safe_pending then return end
   session.creation_safe_pending=true
   -- hook.safe accepts one custom argument. Keep pilots in a runtime-only
   -- queue and pass only the visit generation to the deferred callback.
   hook.safe("P2P_SESSION_PILOT_DEFERRED",session.lifecycle_generation)
end

function session.pilot_attacked ( victim, attacker )
   if not session.running or not current_system() then return false end
   local admitted=session._admit_local_pilot(victim)~=nil
   if attacker~=victim and session._admit_local_pilot(attacker) then
      admitted=true
   end
   return admitted
end

function session.player_died ( p )
   if not session.running or not current_system()
         or not exists(p) or p~=player.pilot() then return false end
   local armour=p:health()
   if armour>0 then return false end
   return publish_player_death(
      session.settings.node_id,local_entity())
end

function session.pilot_created_deferred ( generation )
   if generation~=session.lifecycle_generation then return end
   session.creation_safe_pending=nil
   local pending=session.pending_creations
   session.pending_creations={}
   local registered_npcs=0
   local registered_craft=0
   for id,p in pairs(pending) do
      if exists(p) and p~=player.pilot()
            and not session.replica_by_local[id]
            and not session.authority_by_local[id]
            and not (session.objects
               and session.objects:entity_for_pilot(p)) then
         if pilot_owned(p) then
            if register_authority(
                  p,"craft",session.settings.node_id) then
               registered_craft=registered_craft+1
            end
         elseif is_host() then
            if register_authority(p,"npc",session.settings.node_id) then
               registered_npcs=registered_npcs+1
            end
         elseif session.machine.state=="guest"
               or session.machine.state=="recovering" then
            if register_authority(
                  p,"npc",session.settings.node_id,nil,nil,true) then
               registered_npcs=registered_npcs+1
            end
         end
      end
   end
   if is_host() and not session.incremental_creation_logged
         and registered_npcs+registered_craft>0 then
      session.incremental_creation_logged=true
      print("P2P: registered incremental population ("
         ..tostring(registered_npcs).." NPC, "
         ..tostring(registered_craft).." craft)")
   end
end

function session.pilot_departed ( p, reason, entity )
   if not session.running or not p or p==player.pilot() then return end
   local id=local_id(p)
   local resolved=entity or (id and session.authority_by_local[id])
   if entity and id and session.authority_by_local[id]~=entity then return end
   local entry=resolved and session.authority[resolved]
   if not entry then return end
   unregister_authority(entry)
   session.sequence=session.sequence+1
   local message=gameplay_base("entity_remove")
   message.kind=entry.kind
   message.owner=entry.owner
   message.entity=entry.entity
   message.seq=session.sequence
   message.reason=reason or "removed"
   if is_host() then host_reliable(message)
   else send_host(message,true) end
end

local function pilot_leader_depth ( p )
   local depth=0
   local cursor=p
   local seen={}
   while exists(cursor) and cursor~=player.pilot()
         and not seen[cursor] and depth<64 do
      seen[cursor]=true
      cursor=cursor:leader()
      if cursor then depth=depth+1 end
   end
   return depth
end

local function ordered_population_scan ()
   local ordered={}
   for _index,p in ipairs(pilot.get()) do
      if exists(p) then
         local id=local_id(p)
         ordered[#ordered+1]={
            pilot=p,depth=pilot_leader_depth(p),
            id=tonumber(id) or math.huge,
         }
      end
   end
   table.sort(ordered,function ( a,b )
      if a.depth~=b.depth then return a.depth<b.depth end
      return a.id<b.id
   end)
   return ordered
end

local function scan_initial_host_population ()
   for _index,item in ipairs(ordered_population_scan()) do
      local p=item.pilot
      if exists(p) and p~=player.pilot() then
         local id=local_id(p)
         if not session.replica_by_local[id]
               and not (session.objects and session.objects:entity_for_pilot(p)) then
            if pilot_owned(p) then
               register_authority(p,"craft",session.settings.node_id)
            else
               register_authority(p,"npc",session.settings.node_id)
            end
         end
      end
   end
end

local function remove_guest_ambient_once ()
   for _index,item in ipairs(ordered_population_scan()) do
      local p=item.pilot
      if exists(p) and p~=player.pilot() then
         local id=local_id(p)
         if not session.replica_by_local[id]
               and not session.authority_by_local[id]
               and not (session.objects
                  and session.objects:entity_for_pilot(p)) then
            if pilot_owned(p) then
               register_authority(p,"craft",session.settings.node_id)
            else
               p:rm()
            end
         end
      end
   end
end

local function refresh_host_manifest_cache ()
   local host_manifest=player_manifest()
   if host_manifest then cache_manifest(host_manifest) end
   for owner,manifest in pairs(session.player_manifests) do
      if owner~=session.settings.node_id
            and not session.dead_players[manifest.entity] then
         cache_manifest(canonical_copy(manifest))
      end
   end
   for _entity,entry in pairs(session.authority) do
      local manifest=entry.kind~="npc"
         and (entry.manifest or authority_manifest(entry)) or nil
      if manifest then
         entry.manifest=manifest
         cache_manifest(manifest)
      end
   end
   for _entity,entry in pairs(session.craft) do
      if entry.owner~=session.settings.node_id and entry.manifest then
         cache_manifest(canonical_copy(entry.manifest))
      end
   end
end

local function publish_participant_manifests ()
   if not is_host() then return end
   local host_manifest=player_manifest()
   if host_manifest then broadcast_manifest(cache_manifest(host_manifest)) end
   for owner,stored in pairs(session.player_manifests) do
      if owner~=session.settings.node_id
            and not session.dead_players[stored.entity] then
         local manifest=session._refresh_player_manifest_state(stored)
         session.player_manifests[owner]=manifest
         broadcast_manifest(cache_manifest(manifest))
      end
   end
   for _owner,states in pairs(session.outfit_messages) do
      for _slot,message in pairs(states) do
         if message.on==1 then host_reliable(message) end
      end
   end
end

local function publish_manifest_tick ()
   if not is_host() then return false end
   local order=session.manifest_order
   local count=#order
   if count==0 then return false end
   local inspected=0
   while inspected<math.min(count,8) do
      if session.manifest_cursor>count then session.manifest_cursor=1 end
      local entity=order[session.manifest_cursor]
      session.manifest_cursor=session.manifest_cursor+1
      inspected=inspected+1
      local cached=session.manifest_cache[entity]
      if cached then
         if cached.message.type=="player_manifest" then
            cached=cache_manifest(
               session._refresh_player_manifest_state(cached.message))
         end
         broadcast_manifest(cached)
         return true
      end
   end
   return false
end

local function npc_entry ( entity )
   local entry=session.authority[entity] or session.npcs[entity]
   if entry and entry.kind=="npc" then return entry end
end

local function remember_priority ( entity, class )
   local entry=npc_entry(entity)
   if not entry then return end
   if entry.priority_class==class then return end
   entry.priority_class=class
   if not session.priority_seen[class][entity] then
      local queue=session.priority_queues[class]
      queue[#queue+1]=entity
      session.priority_seen[class][entity]=true
   end
end

local function participant_entity ( entity )
   if entity==local_entity() then return true end
   local entry=session.players[entity]
   return entry~=nil
end

local function classify_npc_record ( entry, record )
   if record.target~="-" and participant_entity(record.target)
         and (record.primary==1 or record.secondary==1) then
      remember_priority(entry.entity,1)
   elseif record.target~="-" and (session.craft[record.target]
         or (session.authority[record.target]
            and session.authority[record.target].kind=="craft")) then
      remember_priority(entry.entity,3)
   else
      entry.priority_class=nil
   end
end

local function select_priority_class ( class )
   local queue=session.priority_queues[class]
   local count=#queue
   if count==0 then return nil end
   local at=session.priority_cursor[class] or 1
   for _index=1,math.min(count,8) do
      if at>count then at=1 end
      local entity=queue[at]
      at=at+1
      local entry=npc_entry(entity)
      if entry and entry.priority_class==class and exists(entry.pilot) then
         session.priority_cursor[class]=at
         return entry
      end
   end
   session.priority_cursor[class]=at
end

local clear_interest

local function select_interest_npc ( stamp )
   local count=#session.interest_order
   if count==0 then return nil end
   local at=session.interest_cursor or 1
   for _index=1,math.min(count,8) do
      if at>count then at=1 end
      local node=session.interest_order[at]
      at=at+1
      local interest=session.target_interests[node]
      if interest and stamp<interest.expires then
         local entry=npc_entry(interest.entity)
         if entry and exists(entry.pilot) then
            session.interest_cursor=at
            return entry
         end
      elseif interest then
         clear_interest(node)
      end
   end
   session.interest_cursor=at
end

local function select_priority_npc ( stamp, include_priority )
   local queue=session.npc_announcement_queue
   while #queue>0 do
      local entity=table.remove(queue,1)
      session.npc_announcement_seen[entity]=nil
      local entry=npc_entry(entity)
      if entry and exists(entry.pilot) then
         return entry
      end
   end
   if not include_priority then return nil end
   return select_priority_class(1)
      or select_interest_npc(stamp)
      or select_priority_class(3)
end

local function detectable_by_participant ( p )
   local pp=player.pilot()
   if exists(pp) and pp:inrange(p) then return true end
   local inspected=1
   for _entity,entry in pairs(session.players) do
      if inspected>=PARTICIPANT_VISIBILITY_CAP then break end
      if exists(entry.pilot) then
         inspected=inspected+1
         if entry.pilot:inrange(p) then return true end
      end
   end
   return false
end

local function select_ambient_npc ( skip )
   local count=#session.npc_order
   if count==0 then return nil end
   local inspected=0
   while inspected<AMBIENT_INSPECTION_CAP and inspected<count do
      if session.npc_cursor>count then session.npc_cursor=1 end
      local entity=session.npc_order[session.npc_cursor]
      session.npc_cursor=session.npc_cursor+1
      inspected=inspected+1
      local entry=npc_entry(entity)
      if entry and entry~=skip
            and exists(entry.pilot) and detectable_by_participant(entry.pilot) then
         return entry
      end
   end
end

local function selected_npc_record ( entry )
   if session.authority[entry.entity]==entry then
      return state_record(entry.pilot,entry.entity,false)
   end
   if not exists(entry.pilot) then return entry.cached_state end
   local record=state_record(entry.pilot,entry.entity,false)
   local cached=entry.cached_state
   if cached then
      -- Relay the host proxy's current motion rather than coordinates cached
      -- when the owner's packet arrived. Lifecycle and combat state remain
      -- owner authoritative.
      record.armour=cached.armour
      record.shield=cached.shield
      record.stress=cached.stress
      record.energy=cached.energy
      record.target=cached.target
      record.weapset=cached.weapset
      record.accel=cached.accel
      record.turn=cached.turn
      record.reverse=cached.reverse
      record.primary=cached.primary
      record.secondary=cached.secondary
   end
   return record
end

local function select_world_craft ()
   local order=session.world_craft_order
   local count=#order
   if count==0 then return nil end
   local inspected=0
   while inspected<math.min(count,4) do
      if session.world_craft_cursor>count then session.world_craft_cursor=1 end
      local entity=order[session.world_craft_cursor]
      session.world_craft_cursor=session.world_craft_cursor+1
      inspected=inspected+1
      local authority=session.authority[entity]
      if authority and authority.kind=="craft" and exists(authority.pilot) then
         return state_record(authority.pilot,entity,false)
      end
      local replica=session.craft[entity]
      if replica and replica.cached_state then
         return selected_npc_record(replica)
      end
   end
end

local function select_object_state ()
   if not session.objects then return end
   local object_id,p=session.objects:next_state_pilot()
   if object_id and exists(p) then return object_state_record(p,object_id) end
end

local function player_state_message ( record )
   session.sequence=session.sequence+1
   local message=gameplay_base("player_state")
   message.entity=record.entity
   message.seq=session.sequence
   for key,value in pairs(record) do
      if key~="entity" then message[key]=value end
   end
   return message
end

local function publish_local_control ( force, record )
   if not current_system() then return false end
   if session.dead_players[local_entity()] then return false end
   record=record or state_record(player.pilot(),local_entity(),true)
   local signature=table.concat({
      record.target,record.weapset,record.accel,
      record.turn,record.reverse,record.primary,record.secondary,
   },":")
   if not force and signature==session.local_control_signature then
      return false
   end
   session.local_control_signature=signature
   session.control_sequence=(session.control_sequence or 0)+1
   local message=gameplay_base("player_control")
   message.owner=session.settings.node_id
   message.entity=local_entity()
   message.seq=session.control_sequence
   message.x=record.x
   message.y=record.y
   message.vx=record.vx
   message.vy=record.vy
   message.dir=record.dir
   message.energy=record.energy
   message.target=record.target
   message.weapset=record.weapset
   message.accel=record.accel
   message.turn=record.turn
   message.reverse=record.reverse
   message.primary=record.primary
   message.secondary=record.secondary
   if is_host() then
      return host_reliable(message)
   end
   return send_host(message,true)
end

function session._publish_outfit_toggle ( slot, on )
   session.outfit_sequence=(session.outfit_sequence or 0)+1
   local message=gameplay_base("outfit_toggle")
   message.owner=session.settings.node_id
   message.entity=local_entity()
   message.seq=session.outfit_sequence
   message.slot=slot
   message.on=on and 1 or 0
   if is_host() then
      local states=session.outfit_messages[message.owner] or {}
      states[slot]=message
      session.outfit_messages[message.owner]=states
      return host_reliable(message)
   end
   return send_host(message,true)
end

function session._publish_outfit_edges ()
   local p=player.pilot()
   if not exists(p) or not current_system() then return false end
   local previous=session.local_outfit_states or {}
   local current={}
   local changed=false
   for _index,active in ipairs(p:actives()) do
      local slot=tonumber(active.slot)
      if slot and slot>=1 and slot<=512 then
         local on=active.active==true
         current[slot]=on
         if previous[slot]~=nil and previous[slot]~=on then
            session._publish_outfit_toggle(slot,on)
            changed=true
         elseif previous[slot]==nil and on then
            session._publish_outfit_toggle(slot,true)
            changed=true
         end
      end
   end
   for slot,on in pairs(previous) do
      if on and current[slot]==nil then
         session._publish_outfit_toggle(slot,false)
         changed=true
      end
   end
   session.local_outfit_states=current
   return changed
end

local function publish_owned_entity_tick ()
   if is_host() then return false end
   local order=session.owned_order
   local count=#order
   if count==0 then return false end
   local inspected=0
   while inspected<math.min(count,8) do
      if session.owned_cursor>count then session.owned_cursor=1 end
      local entity=order[session.owned_cursor]
      session.owned_cursor=session.owned_cursor+1
      inspected=inspected+1
      local entry=session.authority[entity]
      if entry and entry.owner==session.settings.node_id
            and exists(entry.pilot) then
         local record=state_record(entry.pilot,entity,false)
         entry.cached_state=record
         session.sequence=session.sequence+1
         local message=gameplay_base("entity_state")
         message.kind=entry.kind
         message.owner=session.settings.node_id
         message.entity=entity
         message.seq=session.sequence
         message.state=pack_state(record)
         return session._send_game_state(
            peer_for_node(session.machine.host),message)
      end
   end
   return false
end

local function collect_player_lines ()
   local ordered={}
   for owner,record in pairs(session.player_states) do
      if not session.dead_players[record.entity] then
         ordered[#ordered+1]={owner=owner,record=record}
      end
   end
   table.sort(ordered,function ( a,b ) return a.owner<b.owner end)
   local lines={}
   for _index,item in ipairs(ordered) do
      lines[#lines+1]=pack_state(item.record)
   end
   return lines
end

local publish_target_interest

local function host_world_tick ( stamp )
   local p=player.pilot()
   if not exists(p) then return end
   if session.dead_players[local_entity()] then return end
   session._admit_player_target(p)
   local local_record=state_record(p,local_entity(),true,stamp)
   if local_record.armour<=0 then
      publish_player_death(session.settings.node_id,local_entity())
      return
   end
   session.player_states[session.settings.node_id]=local_record
   publish_target_interest(local_record,stamp)
   publish_local_control(false,local_record)
   session._publish_outfit_edges()
   publish_owned_entity_tick()

   session.world_tick=(session.world_tick or 0)+1
   local entity_lines={}
   -- Reserve every third primary slot for the ambient ring. Important NPCs
   -- still receive two thirds of the primary slots, while no engagement can
   -- starve the rest of the host population.
   local first=select_priority_npc(stamp,session.world_tick%3~=0)
   if not first then first=select_ambient_npc() end
   if first then
      local record=selected_npc_record(first)
      if record then
         classify_npc_record(first,record)
         local packed=session._pack_npc_announcement(first,record)
         if packed then entity_lines[#entity_lines+1]=packed end
      end
   end
   local ambient=select_ambient_npc(first)
   if ambient then
      local record=selected_npc_record(ambient)
      if record then
         classify_npc_record(ambient,record)
         local packed=session._pack_npc_announcement(ambient,record)
         if packed then entity_lines[#entity_lines+1]=packed end
      end
   end
   local craft_record=select_world_craft()
   if craft_record then entity_lines[#entity_lines+1]=pack_state(craft_record) end
   local object_record=select_object_state()

   session.sequence=session.sequence+1
   local world=gameplay_base("world")
   world.seq=session.sequence
   local batches,err,oversized=gameplay_codec.encode_world_batches(world,{
      players=collect_player_lines(),
      entities=entity_lines,
      objects=object_record and {pack_object_state(object_record)} or {},
   },WORLD_PACKET_BUDGET)
   if not batches then
      local signature="world_batch:"..tostring(err)
      if not session.encode_errors[signature] then
         session.encode_errors[signature]=true
         print("P2P: unable to encode bounded world frame: "..tostring(err))
      end
      return
   end
   for _index,batch in ipairs(batches) do
      broadcast_world_packet(batch.packet)
   end
   for _index,line in ipairs(oversized or {}) do
      local fallback=canonical_copy(world)
      fallback.players="-"
      fallback.entities=line
      fallback.objects="-"
      host_reliable(fallback)
   end
   if not session.world_tx_logged then
      session.world_tx_logged=true
      print("P2P: canonical world stream active (native broadcast, "
         ..tostring(#batches).." datagrams)")
   end
end

local function guest_world_tick ( stamp )
   if session.machine.state~="guest" or not peer_for_node(session.machine.host) then
      return
   end
   local p=player.pilot()
   if not exists(p) then return end
   if session.dead_players[local_entity()] then return end
   session._admit_player_target(p)
   local record=state_record(p,local_entity(),true,stamp)
   if record.armour<=0 then
      publish_player_death(session.settings.node_id,local_entity())
      return
   end
   session.player_states[session.settings.node_id]=record
   publish_target_interest(record,stamp)
   publish_local_control(false,record)
   session._publish_outfit_edges()
   local peer=peer_for_node(session.machine.host)
   if peer then session._send_game_state(peer,player_state_message(record)) end
   publish_owned_entity_tick()
end

function session._broadcast_player_state ( record )
   session.sequence=session.sequence+1
   local world=gameplay_base("world")
   world.seq=session.sequence
   local batches,err=gameplay_codec.encode_world_batches(world,{
      players={pack_state(record)},entities={},objects={},
   },WORLD_PACKET_BUDGET)
   if not batches then
      local signature="player_broadcast:"..tostring(err)
      if not session.encode_errors[signature] then
         session.encode_errors[signature]=true
         print("P2P: unable to broadcast player state: "..tostring(err))
      end
      return false
   end
   for _index,batch in ipairs(batches) do
      broadcast_world_packet(batch.packet)
   end
   return true
end

local function request_entity_manifest ( entity, stamp )
   if session.machine.state~="guest" or not entity or entity=="-" then
      return false
   end
   stamp=stamp or now()
   if stamp-(session.manifest_queries[entity] or -math.huge)
         <MANIFEST_QUERY_COOLDOWN then return false end
   session.manifest_queries[entity]=stamp
   session.sequence=session.sequence+1
   local message=gameplay_base("entity_query")
   message.entity=entity
   message.seq=session.sequence
   return send_host(message,true)
end

local function remember_pending_state ( record, stamp, sequence, kind )
   if not session.pending_states[record.entity] then
      if session.pending_state_count>=256 then return false end
      session.pending_state_count=session.pending_state_count+1
   end
   session.pending_states[record.entity]={
      record=record,stamp=stamp,sequence=sequence,kind=kind,
   }
   return true
end

local function take_pending_state ( entity )
   local pending=session.pending_states[entity]
   if pending then
      session.pending_states[entity]=nil
      session.pending_state_count=math.max(
         0,session.pending_state_count-1)
   end
   return pending
end

local function parse_world_records ( packed, callback, stamp, sequence, kind )
   if packed=="-" then return end
   local count=0
   for line in packed:gmatch("([^;]+)") do
      count=count+1
      if count>128 then break end
      local record=unpack_state(line)
      if record and callback(record,stamp,sequence)==false
            and record.entity~=local_entity()
            and not session.players[record.entity]
            and not session.npcs[record.entity]
            and not session.craft[record.entity]
            and not session.authority[record.entity] then
         remember_pending_state(record,stamp,sequence,kind)
         request_entity_manifest(record.entity,stamp)
      end
   end
end

function session._parse_world_entities ( packed, stamp, sequence )
   if packed=="-" then return end
   local count=0
   for line in packed:gmatch("([^;]+)") do
      count=count+1
      if count>128 then break end
      if line:sub(1,2)=="n," then
         local record,description=session._unpack_npc_announcement(line)
         if record and description
               and record.entity~=local_entity() then
            local known=session.npcs[record.entity]
            if known or spawn_entity_manifest(description) then
               apply_entity_record(record,stamp,sequence)
               if not session.incremental_replica_logged then
                  session.incremental_replica_logged=true
                  print("P2P: receiving complete round-robin NPC announcements")
               end
            else
               session._log_replica_failure(description)
            end
         end
      else
         local record=unpack_state(line)
         if record and apply_entity_record(record,stamp,sequence)==false
               and record.entity~=local_entity()
               and not session.craft[record.entity]
               and not session.authority[record.entity] then
            remember_pending_state(record,stamp,sequence,"entity")
            request_entity_manifest(record.entity,stamp)
         end
      end
   end
end

local function apply_world ( message )
   local stamp=now()
   parse_world_records(
      message.players,apply_player_record,stamp,message.seq,"player")
   session._parse_world_entities(message.entities,stamp,message.seq)
   if message.objects~="-" then
      local count=0
      for line in message.objects:gmatch("([^;]+)") do
         count=count+1
         if count>32 then break end
         local record=unpack_object_state(line)
         if record then apply_object_state(record,stamp,message.seq) end
      end
   end
end

local function apply_player_control_message ( message )
   if message.owner==session.settings.node_id then return true end
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then return false end
   if message.seq<=(entry.control_sequence or -1) then return false end
   local target=entity_pilot(message.target)
   if message.target~="-" and not target then return nil,"absent" end
   entry.control_sequence=message.seq
   reconcile_arrival(entry,message,player_limits,now())
   apply_player_controls(entry,message)
   if entry.applied.energy~=message.energy then
      entry.pilot:setEnergy(message.energy)
      entry.applied.energy=message.energy
   end
   return true
end

local function apply_craft_order ( message )
   local target=entity_pilot(message.target)
   local manifest=session.player_manifests[message.owner]
   local leader=manifest and entity_pilot(manifest.entity)
   if not leader then return end
   local recipients={}
   for _entity,entry in pairs(session.craft) do
      if entry.owner==message.owner and exists(entry.pilot) then
         recipients[#recipients+1]=entry.pilot
      end
   end
   if #recipients==0 or (message.order=="e_attack" and not target) then return end
   if target==player.pilot() then
      mark_player_aggression(message.owner)
      for _index,p in ipairs(recipients) do p:setHostile(true) end
   end
   leader:msg(recipients,message.order,target)
end

local function entity_absent ( peer, entity )
   session.sequence=session.sequence+1
   local message=gameplay_base("entity_absent")
   message.entity=entity
   message.seq=session.sequence
   send_game(peer,message,true)
end

clear_interest = function ( node )
   local old=session.target_interests[node]
   if old then
      local count=(session.interest_entities[old.entity] or 1)-1
      session.interest_entities[old.entity]=count>0 and count or nil
   end
   session.target_interests[node]=nil
end

local function remember_interest ( node, entity )
   if entity=="-" then
      clear_interest(node)
      return
   end
   local old=session.target_interests[node]
   if old and old.entity~=entity then clear_interest(node); old=nil end
   if not session.interest_seen[node] then
      session.interest_order[#session.interest_order+1]=node
      session.interest_seen[node]=true
   end
   if not old then
      session.interest_entities[entity]=
         (session.interest_entities[entity] or 0)+1
   end
   session.target_interests[node]={entity=entity,expires=now()+5}
end

local function promote_guest_population ()
   local promoted={}
   for old_entity,entry in pairs(session.npcs) do
      if not entry.peer_owned and exists(entry.pilot) then
         local entity=new_entity_id(
            session.settings.node_id,entry.pilot,"npc")
         promoted[#promoted+1]={
            old_entity=old_entity,pilot=entry.pilot,kind="npc",entity=entity,
            origin=entry.origin,
            ai=entry.description.ai,
            depth=pilot_leader_depth(entry.pilot),
            id=tonumber(entry.local_id) or math.huge,
         }
      end
   end
   table.sort(promoted,function ( a,b )
      if a.depth~=b.depth then return a.depth<b.depth end
      return a.id<b.id
   end)
   for _index,item in ipairs(promoted) do
      local old=session.npcs[item.old_entity]
      session.npcs[item.old_entity]=nil
      if old and session.replica_by_local[old.local_id]==item.old_entity then
         session.replica_by_local[old.local_id]=nil
      end
      if session.origins[item.origin]==item.old_entity then
         session.origins[item.origin]=nil
      end
      item.pilot:taskClear()
      item.pilot:changeAI(item.ai)
      ai_setup.setup(item.pilot)
      item.pilot:taskClear()
      item.pilot:setNoDeath(false)
      register_authority(item.pilot,item.kind,
         session.settings.node_id,item.origin,item.entity)
   end
   session.promoted_visit=true
   set_ambient_spawning(false)
end

local function demote_host_population ()
   local demoted={}
   for entity,entry in pairs(session.authority) do
      if entry.kind=="npc" and not entry.peer_owned and exists(entry.pilot) then
         remove_authority_hooks(entry)
         entry.pilot:setNoDeath(true)
         demoted[#demoted+1]=entry
         session.authority[entity]=nil
         session.authority_by_local[entry.local_id]=nil
      end
   end
   for _index,entry in ipairs(demoted) do
      session.npcs[entry.entity]=entry
      session.replica_by_local[entry.local_id]=entry.entity
      session.origins[entry.origin]=entry.entity
   end
   set_ambient_spawning(false)
end

local function reset_delivery_state ()
   session.world_sequence_received=-1
   session.manifest_cache={}
   session.manifest_order={}
   session.manifest_cursor=1
   session.manifest_queries={}
   session.pending_states={}
   session.pending_state_count=0
   session.npc_announcement_queue={}
   session.npc_announcement_seen={}
   session.target_interests={}
   session.interest_entities={}
   session.interest_order={}
   session.interest_seen={}
   session.interest_cursor=1
   session.local_interest=nil
   session.last_interest=nil
   session.local_control_signature=nil
   session.input_down={}
   session.local_outfit_states=nil
   session.outfit_messages={}
end

local function become_host ( failover )
   reset_delivery_state()
   if failover then
      promote_guest_population()
   end
   if not failover and not session.host_inventory_scanned then
      session.host_inventory_scanned=true
      set_ambient_spawning(true)
      scan_initial_host_population()
   end
   for entity,entry in pairs(session.authority) do
      if entry.kind=="npc" and exists(entry.pilot)
            and not session.npc_announcement_seen[entity] then
         session.npc_announcement_seen[entity]=true
         session.npc_announcement_queue[
            #session.npc_announcement_queue+1]=entity
      end
   end
   for entity,entry in pairs(session.npcs) do
      if entry.peer_owned and exists(entry.pilot)
            and not session.npc_announcement_seen[entity] then
         session.npc_announcement_seen[entity]=true
         session.npc_announcement_queue[
            #session.npc_announcement_queue+1]=entity
      end
   end
   refresh_host_manifest_cache()
   publish_participant_manifests()
   publish_directory_claim()
   local action=failover and "elected replacement system host"
      or "claimed system host"
   print("P2P: "..action.." for "..tostring(current_system())
      .." (epoch "..tostring(session.machine.claim)..")")
end

local function join_host ( old_state )
   reset_delivery_state()
   session.needs_host_join=nil
   if old_state=="host" then demote_host_population() end
   set_ambient_spawning(false)
   if not session.guest_population_pruned then
      session.guest_population_pruned=true
      remove_guest_ambient_once()
   end
   local host=session.machine.host
   print("P2P: joined system host "
      ..remote_player_name(host).." for "..tostring(current_system())
      .." (epoch "..tostring(session.machine.claim)..")")
   local endpoint=session.member_endpoints[host]
   if endpoint and not connected_node(host) then connect_gameplay(endpoint,host) end
   session.sequence=session.sequence+1
   local join=gameplay_base("join")
   join.seq=session.sequence
   send_host(join,true)
   local manifest=player_manifest()
   if manifest then send_host(manifest,true) end
   for _entity,entry in pairs(session.authority) do
      if entry.owner==session.settings.node_id
            and (entry.kind=="craft" or entry.peer_owned) then
         local entity_manifest=authority_manifest(entry)
         if entity_manifest then send_host(entity_manifest,true) end
      end
   end
   if not session.greeted_hosts[host] then
      session.sequence=session.sequence+1
      local greeting=gameplay_base("chat")
      greeting.owner=session.settings.node_id
      greeting.seq=session.sequence
      greeting.text=introduction_text(false)
      if send_host(greeting,true) then session.greeted_hosts[host]=true end
   end
end

local chat_sound
local function play_chat_sound ()
   if not chat_sound then chat_sound=audio.new("snd/sounds/hail.opus") end
   chat_sound:play()
end

local function show_chat ( owner, text )
   if owner==session.settings.node_id then
      pilot.comm(display_text(local_player_name()),display_text(text))
   else
      local manifest=session.player_manifests[owner]
      local entry=manifest and session.players[manifest.entity]
      local relay_chat=manifest
         and manifest.ship=="Signal Relay"
         and type(manifest.origin)=="string"
         and manifest.origin:match("%.relay$")

      local object_pilot=session.objects and session.objects.chat_pilot
         and session.objects:chat_pilot(manifest)

      if relay_chat then
         -- A missing object_pilot means there is no operational local relay.
         if object_pilot and exists(object_pilot) then
            object_pilot:broadcast(display_text(text),true)
         end
         return
      elseif entry and exists(entry.pilot) then
         entry.pilot:broadcast(display_text(text),true)
      else
         pilot.comm(session.identities:display_name(owner) or owner,
            display_text(text))
      end
   end
   play_chat_sound()
end

local function directory_feature ( meta, name )
   return meta and type(meta.features)=="string"
      and (","..meta.features..","):find(","..name..",",1,true)~=nil
end

local function request_activity_from_directory ()
   local sent=false
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="directory" and meta.verified
            and directory_feature(meta,"activity") then
         sent=send_directory(peer,{
            type="activity_query",node=session.settings.node_id,
         }) or sent
      end
   end
   session.last_activity_query=now()
   if sent then
      session.directory_probe_deadline=
         session.last_activity_query+DIRECTORY_RESPONSE_TIMEOUT
   end
   return sent
end

local function apply_directory_activity ( message )
   local received=now()
   local activity={}
   if message.entries~="-" then
      for line in message.entries:gmatch("([^;]+)") do
         if #activity>=20 then break end
         local encoded,active,age=line:match("^([^,]+),([01]),(%d+)$")
         local system_name=encoded and directory_codec.unescape(encoded)
         age=tonumber(age)
         if system_name and system_name~="" and #system_name<=240
               and age and age>=0 and age<=86400 then
            activity[#activity+1]={
               system=system_name,active=active=="1",seen=received-age,
            }
         end
      end
   end
   session.activity=activity
   session.activity_received=received
   session.directory_probe_deadline=nil
   naev.cache().multiplayer_activity={
      received=received,entries=activity,
   }
end

local function handle_directory_message ( peer, message )
   local meta=session.peer_meta[peer]
   if message.type=="hello" then
      if message.cap~="directory" or message.node==session.settings.node_id then
         reject_peer(peer,"invalid directory hello")
         return
      end
      meta.verified=true
      meta.node=message.node
      meta.features=message.features or ""
      meta.last_receive=now()
      directory_query()
      if is_host() then publish_directory_claim() end
      if directory_feature(meta,"activity") then
         request_activity_from_directory()
      end
      return
   end
   if not meta.verified or message.node~=meta.node then return end
   if message.type=="punch" and message.system==current_system()
         and message.peer~=session.settings.node_id then
      session.member_endpoints[message.peer]=message.endpoint
      connect_gameplay(message.endpoint,message.peer)
   elseif message.type=="hint" and message.system==current_system()
         and message.host~=session.settings.node_id then
      session.member_endpoints[message.host]=message.endpoint
      session.machine.topology:remember_hint(
         message.system,message.host,message.endpoint,
         message.claim,now()+message.ttl)
      connect_gameplay(message.endpoint,message.host)
   elseif message.type=="activity" then
      apply_directory_activity(message)
   end
end

local function gameplay_hello ( peer )
   send_game(peer,{
      type="hello",node=session.settings.node_id,
      name=local_player_name(),endpoint=session.endpoint,
   },true)
   if current_system() then
      local query=gameplay_base("query")
      query.epoch=nil
      send_game(peer,query,true)
   end
end

local function directory_hello ( peer )
   send_directory(peer,{
      type="hello",node=session.settings.node_id,cap="player",
      name=local_player_name(),endpoint=session.endpoint,
   })
end

local function verify_gameplay_hello ( peer, message )
   local meta=session.peer_meta[peer]
   if message.node==session.settings.node_id then
      reject_peer(peer,"self connection")
      return false
   end
   if meta.expected_node and meta.expected_node~=message.node then
      reject_peer(peer,"unexpected node identity")
      return false
   end
   local duplicate
   for other,other_meta in pairs(session.peer_meta) do
      if other~=peer and other_meta.protocol=="gameplay"
            and other_meta.verified and other_meta.node==message.node then
         duplicate=other
         break
      end
   end
   if duplicate then
      local duplicate_meta=session.peer_meta[duplicate]
      local prefer_outbound=session.settings.node_id<message.node
      if meta.outbound==prefer_outbound
            and duplicate_meta.outbound~=prefer_outbound then
         reject_peer(duplicate,"duplicate connection",true)
      else
         reject_peer(peer,"duplicate connection",true)
         return false
      end
   end
   local accepted,err=session.identities:add(message.node,message.name)
   if not accepted and err=="node changed player name" then
      accepted,err=session.identities:update(message.node,message.name)
   end
   if not accepted then
      reject_peer(peer,err)
      return false
   end
   meta.verified=true
   meta.node=message.node
   meta.name=message.name
   meta.last_receive=now()
   local observed=session.peers[peer]
   local endpoint=endpoint_valid(observed) and observed or message.endpoint
   if endpoint_valid(endpoint) then
      session.member_endpoints[message.node]=endpoint
      session.machine.topology:add_peer(endpoint)
      session.settings.recent=session.machine.topology:serialize_peers()
   end
   refresh_time_controls()
   if current_system() then
      local query=gameplay_base("query")
      query.epoch=nil
      send_game(peer,query,true)
      if is_host() then
         local claim=gameplay_base("claim")
         claim.epoch=session.machine.claim
         claim.endpoint=session.endpoint
         send_game(peer,claim,true)
      end
   end
   return true
end

local remove_owner_population

local function accept_claim_message ( message )
   if message.node==session.settings.node_id
         or message.system~=current_system() then return false end
   local old_state=session.machine.state
   local old_host=session.machine.host
   local old_claim=session.machine.claim
   local candidate={
      node=message.node,system=message.system,visit=message.visit,
      claim=message.epoch,endpoint=message.endpoint,
   }
   local accepted=session.machine:accept_claim(candidate)
   if not accepted then return false end
   session.member_endpoints[message.node]=message.endpoint
   session.machine.topology:remember_hint(
      message.system,message.node,message.endpoint,message.epoch,now()+60)
   local changed=old_state~="guest" or old_host~=message.node
      or old_claim~=message.epoch
   if changed or (session.machine.state=="guest"
         and session.machine.host==message.node
         and session.needs_host_join) then
      local departed=old_host or session.recovering_from
      if changed and departed and departed~=message.node then
         if old_state=="recovering" then announce_player_leave(departed) end
         remove_owner_population(departed,false)
      end
      session.recovering_from=nil
      join_host(old_state)
   end
   refresh_time_controls()
   return true
end

remove_owner_population = function ( owner, explode )
   local entities={}
   for entity,entry in pairs(session.players) do
      if entry.owner==owner then entities[#entities+1]=entity end
   end
   for entity,entry in pairs(session.craft) do
      if entry.owner==owner then entities[#entities+1]=entity end
   end
   for entity,entry in pairs(session.npcs) do
      if entry.peer_owned and entry.owner==owner then
         entities[#entities+1]=entity
      end
   end
   for _index,entity in ipairs(entities) do remove_replica(entity,explode) end
   session.player_manifests[owner]=nil
   session.player_states[owner]=nil
   session.outfit_messages[owner]=nil
   session.host_welcomed[owner]=nil
   session.greeted_hosts[owner]=nil
   clear_interest(owner)
end

local function host_replace_member_visit ( node, visit, _except )
   if not is_host() then return false end
   local old_visit=session.machine.member_visits[node]
   if not old_visit or old_visit==visit then return false end
   announce_player_leave(node)
   remove_owner_population(node,false)
   session.machine:remove_member(node)
   local leave=gameplay_base("leave")
   leave.owner=node
   host_reliable(leave)
   return true
end

local function canonical_player_manifest ( message )
   local copy=canonical_copy(message)
   copy.owner=message.owner
   return copy
end

local function handle_host_player_manifest ( peer, meta, message )
   if message.owner~=meta.node or message.node~=meta.node
         or message.epoch~=session.machine.claim
         or not message.origin:match("^"..meta.node.."%.") then return end
   if session.dead_players[message.entity] then return end
   local known=session.identities:raw_name(message.owner)
   if known~=message.name then return end
   local canonical=canonical_player_manifest(message)
   session.player_manifests[message.owner]=canonical
   if not spawn_player_manifest(message) then
      reject_peer(peer,"unable to create remote player proxy")
      return
   end
   broadcast_manifest(cache_manifest(canonical))
   if not session.host_welcomed[message.owner] then
      session.sequence=session.sequence+1
      local welcome=gameplay_base("chat")
      welcome.owner=session.settings.node_id
      welcome.seq=session.sequence
      welcome.text=introduction_text(true)
      if send_game(peer,welcome,true) then
         session.host_welcomed[message.owner]=true
      end
   end
end

local function handle_host_entity_manifest ( peer, meta, message )
   if (message.kind~="craft" and message.kind~="npc")
         or message.owner~=meta.node
         or message.epoch~=session.machine.claim then return end
   if not message.entity:match("^"..message.owner.."%.")
         or not message.origin:match("^"..message.owner.."%.") then return end
   if spawn_entity_manifest(message) then
      local canonical=canonical_copy(message)
      if message.kind=="npc" then
         local entry=session.npcs[message.entity]
         if not entry then return end
         entry.description=canonical
         entry.cached_state=message
         entry.peer_owned=true
         add_npc_order(message.entity)
         if not session.npc_announcement_seen[message.entity] then
            session.npc_announcement_seen[message.entity]=true
            session.npc_announcement_queue[
               #session.npc_announcement_queue+1]=message.entity
         end
         classify_npc_record(entry,message)
         broadcast_npc_announcement(entry)
         if not session.guest_owned_npc_logged then
            session.guest_owned_npc_logged=true
            print("P2P: relaying guest-owned NPC population")
         end
      else
         session.world_craft_order[
            #session.world_craft_order+1]=message.entity
         local entry=session.craft[message.entity]
         if entry then entry.manifest=canonical end
         broadcast_manifest(cache_manifest(canonical))
      end
   elseif message.kind=="npc" then
      session._log_replica_failure(message)
   end
end

local function handle_entity_remove ( peer, meta, message )
   if message.kind=="player" then
      if message.reason~="death" then return end
      if is_host() then
         if message.owner~=meta.node then return end
         local manifest=session.player_manifests[message.owner]
         if not manifest or manifest.entity~=message.entity then return end
         if session._mark_player_dead(message.owner,message.entity) then
            host_reliable(canonical_copy(message))
         end
      elseif meta.node==session.machine.host then
         session._mark_player_dead(message.owner,message.entity)
      end
      return
   end
   if is_host() then
      if message.owner~=meta.node
            or (message.kind~="craft" and message.kind~="npc") then return end
      local container=message.kind=="npc" and session.npcs or session.craft
      local entry=container[message.entity]
      if entry and entry.owner==message.owner then
         remove_replica(message.entity,
            message.reason=="death" or message.reason=="exploded")
      end
      host_reliable(canonical_copy(message))
   elseif meta.node==session.machine.host then
      local entry=session.npcs[message.entity] or session.craft[message.entity]
      if entry and entry.owner==message.owner then
         remove_replica(message.entity,
            message.reason=="absent" or message.reason=="death"
               or message.reason=="exploded")
      end
   end
end

local function handle_gameplay_message ( peer, message )
   local meta=session.peer_meta[peer]
   if message.type=="hello" then
      verify_gameplay_hello(peer,message)
      return
   end
   if not meta.verified or message.node~=meta.node then return end
   meta.last_receive=now()
   if message.type=="query" then
      if message.system==current_system() and is_host() then
         local claim=gameplay_base("claim")
         claim.endpoint=session.endpoint
         send_game(peer,claim,true)
      end
      return
   elseif message.type=="claim" then
      accept_claim_message(message)
      return
   end
   local current=current_system()
   if not current or message.system~=current then
      if current and (message.type=="chat"
            or message.type=="player_manifest" or message.type=="leave") then
         local direct_name=message.owner==meta.node and meta.name or nil
         communications.observe(message,direct_name,current)
      end
      return
   end
   if message.type=="heartbeat" then
      host_replace_member_visit(message.node,message.visit,peer)
      session.machine:observe_member(
         message.node,message.visit,
         message.accepted_host,message.accepted_epoch,now())
      if session.machine.state=="guest"
            and message.node==session.machine.host then
         session.recovering_from=nil
      end
      if message.endpoint and endpoint_valid(message.endpoint) then
         session.member_endpoints[message.node]=message.endpoint
      end
      refresh_time_controls()
      return
   end
   local active_visit=session.machine.member_visits[message.node]
   if active_visit and message.visit~=active_visit then
      if not (is_host() and message.type=="join") then return end
      host_replace_member_visit(message.node,message.visit,peer)
   end
   session.machine:observe_member(message.node,message.visit,nil,nil,now())
   if message.type=="leave" then
      if is_host() and message.owner~=meta.node then return end
      if not is_host() then
         if message.epoch~=session.machine.claim then return end
         if meta.node~=session.machine.host
               and message.owner~=meta.node then return end
         if message.owner==session.settings.node_id then return end
      end
      session.machine:remove_member(message.owner)
      announce_player_leave(message.owner)
      remove_owner_population(message.owner,false)
      session.identities:remove(message.owner)
      if is_host() then host_reliable(canonical_copy(message)) end
      refresh_time_controls()
      return
   end
   if is_host() then
      if message.epoch~=session.machine.claim then return end
      if message.type=="join" then
         publish_participant_manifests()
      elseif message.type=="entity_query" then
         local npc=npc_entry(message.entity)
         local cached=session.manifest_cache[message.entity]
         if npc and exists(npc.pilot) then
            if not session.npc_announcement_seen[message.entity] then
               session.npc_announcement_seen[message.entity]=true
               session.npc_announcement_queue[
                  #session.npc_announcement_queue+1]=message.entity
            end
         elseif cached then
            if cached.message.type=="player_manifest" then
               cached=cache_manifest(
                  session._refresh_player_manifest_state(cached.message))
            end
            broadcast_manifest(cached)
         else
            entity_absent(peer,message.entity)
         end
      elseif message.type=="player_manifest" then
         handle_host_player_manifest(peer,meta,message)
      elseif message.type=="entity_manifest" then
         handle_host_entity_manifest(peer,meta,message)
      elseif message.type=="entity_remove" then
         handle_entity_remove(peer,meta,message)
      elseif message.type=="player_state" then
         local manifest=session.player_manifests[meta.node]
         local entry=manifest and session.players[manifest.entity]
         if manifest and manifest.entity==message.entity
               and message.armour<=0 then
            publish_player_death(meta.node,message.entity)
         elseif manifest and manifest.entity==message.entity and entry
               and message.seq>(entry.state_sequence or -1) then
            entry.state_sequence=message.seq
            session.player_states[meta.node]=message
            apply_player_record(message,now())
            session._broadcast_player_state(message)
         end
      elseif message.type=="player_control" then
         if message.owner~=meta.node then return end
         local ok,err=apply_player_control_message(message)
         if not ok and err=="absent" then
            entity_absent(peer,message.target)
         elseif ok then
            host_reliable(canonical_copy(message))
         end
      elseif message.type=="outfit_toggle" then
         if message.owner~=meta.node then return end
         local ok=session._apply_outfit_toggle(message)
         if ok then
            local canonical=canonical_copy(message)
            local states=session.outfit_messages[message.owner] or {}
            states[message.slot]=canonical
            session.outfit_messages[message.owner]=states
            host_reliable(canonical)
         elseif ok==false and not session.players[message.entity] then
            entity_absent(peer,message.entity)
         end
      elseif message.type=="entity_state" then
         if message.owner~=meta.node then return end
         local container=message.kind=="npc" and session.npcs or session.craft
         local entry=container[message.entity]
         local record=unpack_state(message.state)
         if entry and entry.owner==meta.node and record
               and record.entity==message.entity
               and message.seq>(entry.state_sequence or -1) then
            entry.state_sequence=message.seq
            entry.cached_state=record
            apply_entity_record(record,now())
            if message.kind=="npc" then classify_npc_record(entry,record) end
         elseif not entry then
            entity_absent(peer,message.entity)
         end
      elseif message.type=="craft_order" then
         if message.owner~=meta.node then return end
         if message.target~="-" and not entity_pilot(message.target) then
            entity_absent(peer,message.target)
            return
         end
         apply_craft_order(message)
         host_reliable(canonical_copy(message))
      elseif message.type=="target_interest" then
         if message.owner~=meta.node then return end
         if message.target~="-"
               and not entity_pilot(message.target) then
            clear_interest(meta.node)
            entity_absent(peer,message.target)
         else
            remember_interest(meta.node,message.target)
            host_reliable(canonical_copy(message))
         end
      elseif message.type=="chat" and message.owner==meta.node then
         show_chat(message.owner,message.text)
         host_reliable(canonical_copy(message))
      end
      return
   end

   if session.machine.state~="guest" or meta.node~=session.machine.host
         or message.epoch~=session.machine.claim then return end
   if message.type=="player_manifest" then
      if session.dead_players[message.entity] then return end
      session.player_manifests[message.owner]=message
      session.manifest_queries[message.entity]=nil
      if message.owner~=session.settings.node_id then
         local known=session.identities:raw_name(message.owner)
         if not known then session.identities:add(message.owner,message.name) end
         if not spawn_player_manifest(message) then
            reject_peer(peer,"unable to create remote player proxy")
            return
         end
         local pending=take_pending_state(message.entity)
         if pending and pending.kind=="player" then
            apply_player_record(
               pending.record,pending.stamp,pending.sequence)
         end
      end
   elseif message.type=="entity_manifest" then
      if message.kind~="craft" then return end
      session.manifest_queries[message.entity]=nil
      if not spawn_entity_manifest(message) then
         reject_peer(peer,"unable to create remote "
            ..tostring(message.kind).." replica")
         return
      end
      local pending=take_pending_state(message.entity)
      if pending and pending.kind=="entity" then
         apply_entity_record(
            pending.record,pending.stamp,pending.sequence)
      end
      if not session.incremental_replica_logged then
         session.incremental_replica_logged=true
         print("P2P: accepted authoritative "..tostring(message.kind)
            .." manifest")
      end
   elseif message.type=="entity_remove" then
      take_pending_state(message.entity)
      handle_entity_remove(peer,meta,message)
   elseif message.type=="player_control" then
      apply_player_control_message(message)
   elseif message.type=="outfit_toggle" then
      session._apply_outfit_toggle(message)
   elseif message.type=="craft_order"
         and message.owner~=session.settings.node_id then
      apply_craft_order(message)
   elseif message.type=="target_interest"
         and message.owner~=session.settings.node_id then
      remember_interest(message.owner,message.target)
   elseif message.type=="world" then
      session.world_sequence_received=math.max(
         message.seq,session.world_sequence_received or -1)
      apply_world(message)
      if not session.world_rx_logged then
         session.world_rx_logged=true
         print("P2P: receiving canonical world stream")
      end
   elseif message.type=="entity_absent" then
      session.manifest_queries[message.entity]=nil
      take_pending_state(message.entity)
      remove_replica(message.entity,true)
   elseif message.type=="chat"
         and message.owner~=session.settings.node_id then
      show_chat(message.owner,message.text)
   end
end

local function disconnect_gameplay_peers ()
   local peers={}
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="gameplay" then peers[#peers+1]=peer end
   end
   for _index,peer in ipairs(peers) do
      reject_peer(peer,"system lifecycle reset",true)
   end
end

local function service_transport ( stamp )
   local processed=0
   while processed<MAX_EVENTS_PER_FRAME do
      local event=session.host:service(0)
      if not event then break end
      processed=processed+1
      if event.type=="connect" then
         local meta=session.peer_meta[event.peer]
         if not meta then
            session.peers[event.peer]=tostring(event.peer)
            meta={
               protocol="gameplay",outbound=false,verified=false,
               connected_at=stamp,
            }
            session.peer_meta[event.peer]=meta
         end
         if meta.protocol=="directory" then directory_hello(event.peer)
         else gameplay_hello(event.peer) end
      elseif event.type=="receive" then
         local meta=session.peer_meta[event.peer]
         if meta then
            local codec=meta.protocol=="directory"
               and directory_codec or gameplay_codec
            local message,err=codec.decode(event.data)
            if not message then
               reject_peer(event.peer,"malformed packet: "..tostring(err),true)
            elseif meta.protocol=="directory" then
               handle_directory_message(event.peer,message)
            else
               handle_gameplay_message(event.peer,message)
            end
         end
      elseif event.type=="disconnect" then
         local endpoint=session.peers[event.peer]
         local meta=session.peer_meta[event.peer]
         if meta and meta.protocol=="gameplay"
               and session.machine.state=="guest"
               and meta.node==session.machine.host then
            session.needs_host_join=true
         end
         session.peers[event.peer]=nil
         session.peer_meta[event.peer]=nil
         if endpoint then session.endpoints[endpoint]=nil end
      end
   end
end

local function publish_claim ()
   if not is_host() then return end
   local claim=gameplay_base("claim")
   claim.endpoint=session.endpoint
   fanout_control(claim)
   publish_directory_claim()
   session.last_claim=now()
end

local function publish_heartbeat ( stamp )
   if not current_system() then return end
   session.heartbeat_sequence=(session.heartbeat_sequence or 0)+1
   local heartbeat=gameplay_base("heartbeat")
   heartbeat.seq=session.heartbeat_sequence
   heartbeat.endpoint=session.endpoint
   heartbeat.accepted_host=session.machine.host
   heartbeat.accepted_epoch=session.machine.claim
   fanout_control(heartbeat)
   session.machine:observe_member(
      session.settings.node_id,session.visit,
      heartbeat.accepted_host,heartbeat.accepted_epoch,stamp)
end

local function redial_host_and_members ()
   if not current_system() then return end
   if session.machine.state=="guest" and session.machine.host then
      local endpoint=session.member_endpoints[session.machine.host]
      if endpoint and not connected_node(session.machine.host) then
         connect_gameplay(endpoint,session.machine.host)
      end
   end
   for node,endpoint in pairs(session.member_endpoints) do
      if node~=session.settings.node_id and not connected_node(node) then
         connect_gameplay(endpoint,node)
      end
   end
   connect_known_peers()
   directory_query()
end

local function audit_one_authority ()
   local order=session.audit_order
   local count=#order
   if count==0 then return end
   if session.audit_cursor>count then session.audit_cursor=1 end
   local entity=order[session.audit_cursor]
   session.audit_cursor=session.audit_cursor+1
   local entry=session.authority[entity]
   if entry and not exists(entry.pilot) then
      session.pilot_departed(entry.pilot,"removed",entity)
   end
end

local function reconcile_participant_liveness ( stamp )
   local stale={}
   for node in pairs(session.machine.members) do
      if node~=session.settings.node_id
            and stamp-(session.machine.member_seen[node] or -math.huge)
               >core.MEMBER_LEASE then
         stale[#stale+1]=node
      end
   end
   for _index,node in ipairs(stale) do
      session.machine:remove_member(node)
      announce_player_leave(node)
      remove_owner_population(node,false)
      session.identities:remove(node)
      if is_host() then
         session.sequence=session.sequence+1
         local leave=gameplay_base("leave")
         leave.owner=node
         host_reliable(leave)
      end
   end
   local aggression_deadline
   for _entity,entry in pairs(session.players) do
      if entry.last_aggression
            and stamp-entry.last_aggression>=AGGRESSION_GRACE then
         if exists(entry.pilot) then entry.pilot:setHostile(false) end
         entry.last_aggression=nil
         entry.hostile=nil
      elseif entry.last_aggression then
         aggression_deadline=math.max(aggression_deadline or 0,
            entry.last_aggression+AGGRESSION_GRACE)
      end
   end
   session.indicators:reconcile_aggression(aggression_deadline,stamp)
end

local function liveness_tick ( stamp )
   local stale={}
   for peer,meta in pairs(session.peer_meta) do
      if not meta.verified
            and stamp-(meta.connected_at or stamp)>=HANDSHAKE_TIMEOUT then
         stale[#stale+1]=peer
      elseif meta.verified and meta.protocol=="gameplay"
            and stamp-(meta.last_receive or stamp)>=TRANSPORT_IDLE_TIMEOUT then
         stale[#stale+1]=peer
      end
   end
   for _index,peer in ipairs(stale) do
      reject_peer(peer,"application liveness timeout",true)
   end
   reconcile_participant_liveness(stamp)
   audit_one_authority()
   session.indicators:update(stamp)
   refresh_time_controls(stamp)
   session.enforce_time_controls()
   if session.directory_probe_deadline
         and stamp>=session.directory_probe_deadline then
      session.directory_probe_deadline=nil
   end
end

local function election_tick ( stamp )
   local old_state=session.machine.state
   local old_host=session.machine.host
   local action=session.machine:tick(stamp)
   if action=="claim" then
      local departed=old_host or session.recovering_from
      if departed and departed~=session.settings.node_id then
         announce_player_leave(departed)
         remove_owner_population(departed,false)
      end
      session.recovering_from=nil
      become_host(old_state=="recovering")
      publish_claim()
      refresh_time_controls(stamp)
   elseif action=="recover" or action=="query" then
      if action=="recover" then session.recovering_from=old_host end
      local query=gameplay_base("query")
      query.epoch=nil
      for peer,meta in pairs(session.peer_meta) do
         if meta.protocol=="gameplay" and meta.verified then
            send_game(peer,query,true)
         end
      end
      redial_host_and_members()
      refresh_time_controls(stamp)
   end
end

local function reset_runtime_tables ()
   session.players={}
   session.npcs={}
   session.craft={}
   session.player_manifests={}
   session.player_states={}
   session.dead_players={}
   session.outfit_messages={}
   session.present_players={}
   session.host_welcomed={}
   session.greeted_hosts={}
   session.authority={}
   session.authority_by_local={}
   session.origins={}
   session.replica_by_local={}
   session.manifest_cache={}
   session.manifest_order={}
   session.manifest_cursor=1
   session.manifest_queries={}
   session.pending_states={}
   session.pending_state_count=0
   session.npc_announcement_queue={}
   session.npc_announcement_seen={}
   session.npc_order={}
   session.npc_order_seen={}
   session.npc_cursor=1
   session.owned_order={}
   session.owned_cursor=1
   session.world_craft_order={}
   session.world_craft_cursor=1
   session.audit_order={}
   session.audit_cursor=1
   session.priority_queues={{},{},{}}
   session.priority_seen={{},{},{}}
   session.priority_cursor={1,1,1}
   session.target_interests={}
   session.interest_entities={}
   session.interest_order={}
   session.interest_seen={}
   session.interest_cursor=1
   session.waiting_leaders={}
   session.pending_creations={}
   session.creation_safe_pending=nil
   session.incremental_creation_logged=nil
   session.incremental_replica_logged=nil
   session.guest_owned_npc_logged=nil
   session.world_tx_logged=nil
   session.world_rx_logged=nil
   session.needs_host_join=nil
   session.local_control_signature=nil
   session.local_outfit_states=nil
   session.local_motion_sample=nil
   session.control_sequence=0
   session.outfit_sequence=0
   session.heartbeat_sequence=0
   session.world_tick=0
   session.world_sequence_received=-1
   session.recovering_from=nil
   session.host_inventory_scanned=nil
   session.guest_population_pruned=nil
   session.promoted_visit=nil
   session.encode_errors={}
   craft_factions={}
   session.npc_factions={}
   session.npc_faction_counter=0
end

local function clear_authority_hooks ()
   for _entity,entry in pairs(session.authority) do
      remove_authority_hooks(entry)
   end
end

local function clear_replicas ()
   local entities={}
   for entity in pairs(session.players) do entities[#entities+1]=entity end
   for entity in pairs(session.npcs) do entities[#entities+1]=entity end
   for entity in pairs(session.craft) do entities[#entities+1]=entity end
   for _index,entity in ipairs(entities) do remove_replica(entity,false) end
end

function session.start ( settings )
   if session.running then return true end
   clear_local_controls()
   session.settings=session.defaults(settings)
   local ok,host=pcall(
      enet.host_create,"*:"..tostring(session.settings.listen_port),
      64,CANONICAL_CHANNEL+1)
   if not ok or not host then
      return nil,"unable to create P2P host: "..tostring(host)
   end
   session.host=host
   session.endpoint=tostring(host:get_socket_address())
   session.machine=core.new(session.settings.node_id,now)
   session.machine:start()
   session.machine.topology:load_peers(session.settings.recent)
   session.identities=identity.new(
      session.settings.node_id,local_player_name())
   session.member_endpoints={}
   session.running=true
   session.ambient_spawning=true
   session.activity={}
   session.activity_received=0
   session.last_activity_query=0
   session.sequence=0
   session.generation=0
   session.lifecycle_generation=0
   session.objects=ObjectRuntime.new{
      settings=session.settings,
      now=now,
      player_name=local_player_name,
      current_system=current_system,
   }
   session.objects:start()
   reset_runtime_tables()
   connect_known_peers()
   local stamp=now()
   session.next_world=stamp
   session.next_heartbeat=stamp
   session.next_election=stamp
   session.next_liveness=stamp
   session.next_redial=stamp
   session.next_manifest=stamp
   session.next_activity=stamp
   session.last_claim=-math.huge
   print("P2P: MP2G/2 listener started")
   return true
end

function session.stop ()
   clear_local_controls()
   if not session.running then
      session.indicators:clear()
      lock_autonav(false)
      naev.cache().multiplayer_p2p_objects=false
      return
   end
   local leaving=current_system()
   if leaving then session.leave() end
   if session.objects then session.objects:stop() end
   for peer in pairs(session.peers) do peer:disconnect_now() end
   session.settings.recent=session.machine.topology:serialize_peers()
   session.machine:stop()
   session.running=false
   session.host=nil
   session.objects=nil
   session.peers={}
   session.endpoints={}
   session.peer_meta={}
   session.indicators:clear()
   lock_autonav(false)
end

local function locally_claimed ()
   return not naev.claimTest(system.cur())
end

function session.enter ( system_name )
   if not session.running then return nil,"not running" end
   if current_system()==system_name then
      refresh_time_controls()
      return true
   end
   session.leave()
   reset_runtime_tables()
   session.lifecycle_generation=session.lifecycle_generation+1
   session.visit_generation=(session.visit_generation or 0)+1
   session.visit=random_id()
      ..string.format("%x",session.visit_generation)
   session.machine:enter(system_name,session.visit)
   session.solo_since=nil
   session.local_weapset=1
   session.skip_host_grace=session.skip_next_host_grace==true
   session.skip_next_host_grace=nil
   set_ambient_spawning(false)
   session.objects:enter(system_name)
   connect_known_peers()
   directory_query()
   local query=gameplay_base("query")
   query.epoch=nil
   for peer,meta in pairs(session.peer_meta) do
      if meta.protocol=="gameplay" and meta.verified then
         send_game(peer,query,true)
      end
   end
   local stamp=now()
   session.next_world=stamp
   session.next_heartbeat=stamp
   session.next_election=stamp
   session.next_liveness=stamp
   session.next_redial=stamp
   session.next_manifest=stamp
   session.next_activity=stamp
   print("P2P: discovering MP2G/2 system host")
   if locally_claimed() then
      session.machine:new_claim()
      become_host(false)
      publish_claim()
   end
   refresh_time_controls(stamp)
   return true
end

function session.leave ()
   clear_local_controls()
   communications.stop()
   session.communications_active=nil
   if not session.machine or not current_system() then
      session.indicators:clear()
      lock_autonav(false)
      return
   end
   local system_name=current_system()
   local was_host=is_host()
   local leave=gameplay_base("leave")
   leave.owner=session.settings.node_id
   fanout_control(leave)
   if was_host then publish_directory_leave(system_name) end
   session.skip_next_host_grace=was_host
      and no_other_players_discovered(system_name)
   session.objects:leave()
   clear_authority_hooks()
   clear_replicas()
   disconnect_gameplay_peers()
   session.machine:leave()
   session.visit=nil
   session.lifecycle_generation=session.lifecycle_generation+1
   reset_runtime_tables()
   session.solo_since=nil
   session.indicators:clear()
   set_ambient_spawning(true)
   lock_autonav(false)
end

publish_target_interest = function ( record, stamp )
   local target=record.target or "-"
   if target==session.local_interest
         and stamp-(session.last_interest or -math.huge)<2 then return end
   session.local_interest=target
   session.last_interest=stamp
   session.sequence=session.sequence+1
   local message=gameplay_base("target_interest")
   message.owner=session.settings.node_id
   message.seq=session.sequence
   message.target=target
   remember_interest(session.settings.node_id,target)
   if is_host() then
      return host_reliable(message)
   end
   if session.machine.state~="guest" then return end
   send_host(message,true)
end

function session.send_chat ( text )
   if not session.running or not current_system()
         or type(text)~="string" or text=="" then return nil end
   session.sequence=session.sequence+1
   local message=gameplay_base("chat")
   message.owner=session.settings.node_id
   message.seq=session.sequence
   message.text=text:sub(1,1024)
   show_chat(message.owner,message.text)
   if is_host() then host_reliable(message)
   else send_host(message,true) end
   if communications.send(message.text,session.settings) then
      session.communications_active=true
   end
   return true
end

function session.request_activity ()
   if not session.running then return false end
   return request_activity_from_directory()
end

function session.recent_activity ()
   local stamp=now()
   local activity={}
   local fresh=stamp-(session.activity_received or 0)
      <=2*ACTIVITY_QUERY_INTERVAL
   for _index,entry in ipairs(session.activity or {}) do
      local age=math.max(0,math.floor(stamp-entry.seen))
      if age<=ACTIVITY_RETENTION then
         activity[#activity+1]={
            system=entry.system,active=entry.active and fresh,age=age,
         }
      end
   end
   return activity
end

function session.create_message_buoy ( text, slot )
   if not session.objects then
      return nil,_("The persistent-object service is unavailable.")
   end
   return session.objects:create_message_buoy(text,slot)
end

function session.create_signal_relay ( slot )
   if not session.objects then
      return nil,_("The persistent-object service is unavailable.")
   end
   return session.objects:create_signal_relay(slot)
end

function session.relay_chat ( text )
   return session.objects and session.objects:relay_chat(text) or false
end

function session.object_destroyed ( object_id, destroyed_pilot )
   return session.objects
      and session.objects:object_destroyed(object_id,destroyed_pilot)
      or false
end

function session.take_object_consumptions ()
   return session.objects and session.objects:take_object_consumptions() or {}
end

function session.update_object_client ()
   return session.objects and session.objects:update() or false
end

function session.update_signal_relay ()
   return session.objects and session.objects:update_signal_relay() or false
end

function session.object_service_pending ()
   return session.objects and session.objects:pending() or false
end

function session.publish_focus_entities ()
   -- Target interest is part of the one 15 Hz host scheduler in MP2G/2.
   return false
end

function session.input ( input_name, input_pressed )
   if not session.running then return end
   session.keep_simulation_live()
   if input_name=="speed" then
      if session.autonav_locked then session.enforce_time_controls() end
      return
   end
   local pressed=input_pressed==true
   local was_pressed=session.input_down[input_name]==true
   local selected=input_name:match("^weapset([0-9])$")
   if selected then
      session.input_down[input_name]=pressed or nil
      if pressed and not was_pressed then
         session.local_weapset=tonumber(selected)
         if session.local_weapset==0 then session.local_weapset=10 end
         publish_local_control(true)
         session._publish_outfit_edges()
      end
      return
   end
   if input_name=="e_attack" or input_name=="e_hold"
         or input_name=="e_return" or input_name=="e_clear" then
      session.input_down[input_name]=pressed or nil
      if not pressed or was_pressed then return end
      local target=target_entity(player.pilot():target())
      if input_name=="e_attack" and target=="-" then return end
      session.sequence=session.sequence+1
      local message=gameplay_base("craft_order")
      message.owner=session.settings.node_id
      message.seq=session.sequence
      message.order=input_name
      message.target=target
      if is_host() then
         host_reliable(message)
      else
         send_host(message,true)
      end
      return
   end
   local key
   if input_name=="accel" then key="accel"
   elseif input_name=="left" then key="left"
   elseif input_name=="right" then key="right"
   elseif input_name=="reverse" then key="reverse"
   elseif input_name=="primary" then key="primary"
   elseif input_name=="secondary" then key="secondary"
   else return end
   session.input_down[input_name]=pressed or nil
   if pressed==was_pressed then return end
   naev.cache()[key]=pressed and 1 or 0
   if (key=="primary" or key=="secondary") and pressed then
      local target=player.pilot():target()
      for _entity,entry in pairs(session.players) do
         if entry.pilot==target then
            mark_player_aggression(entry.owner)
            break
         end
      end
   end
   publish_local_control(true)
   session._publish_outfit_edges()
end

function session.enforce_time_controls ()
   if not session.autonav_locked then return end
   local _autonav,autonav_speed=player.autonav()
   if autonav_speed~=1 or player.speed()~=1 then
      player.autonavSetSpeed(1,1)
      player.setSpeed(1,1)
   end
end

function session.keep_simulation_live ()
   if not session.running or not current_system() or player.isLanded() then
      return false
   end
   local shared=has_remote_member()
      or session.machine.state=="guest"
      or session.machine.state=="recovering"
   if not shared then return false end
   naev.unpause()
   session.enforce_time_controls()
   return true
end

function session.update ( _dt )
   if not session.running then return end
   local stamp=now()
   -- Naev's autonav controller can raise its multiplier every frame without
   -- going through the speed input. Correct only while a shared visit is
   -- locked, before servicing the scheduled networking jobs.
   session.enforce_time_controls()
   service_transport(stamp)
   if session.communications_active then
      communications.update()
      session.communications_active=communications.active()
   end

   if stamp>=session.next_election then
      session.next_election=stamp+0.1
      election_tick(stamp)
   end
   if stamp>=session.next_manifest then
      session.next_manifest=stamp+MANIFEST_INTERVAL
      if is_host() and has_remote_member() then publish_manifest_tick() end
   end
   if stamp>=session.next_heartbeat then
      session.next_heartbeat=stamp+HEARTBEAT_INTERVAL
      publish_heartbeat(stamp)
   end
   if stamp>=session.next_world then
      session.next_world=stamp+WORLD_INTERVAL
      if is_host() then
         if has_remote_member() then host_world_tick(stamp) end
      elseif session.machine.state=="guest" then
         guest_world_tick(stamp)
      end
   end
   if stamp>=session.next_liveness then
      session.next_liveness=stamp+LIVENESS_INTERVAL
      liveness_tick(stamp)
   end
   if stamp>=session.next_redial then
      session.next_redial=stamp+REDIAL_INTERVAL
      redial_host_and_members()
   end
   if is_host() and stamp-session.last_claim>=CLAIM_INTERVAL then
      publish_claim()
   end
   if stamp>=session.next_activity then
      session.next_activity=stamp+ACTIVITY_QUERY_INTERVAL
      request_activity_from_directory()
   end
end

return session
