-- Isolated P2P runtime. Arena multiplayer does not depend on this module.
local codec = require "multiplayer.p2p.codec"
local core = require "multiplayer.p2p.core"
local Mesh = require "multiplayer.p2p.mesh"
local reconcile = require "multiplayer.p2p.reconcile"
local owned = require "multiplayer.p2p.owned"
local identity = require "multiplayer.p2p.identity"
local status = require "multiplayer.p2p.status"
local Object = require "multiplayer.p2p.objects"
local ObjectClient = require "multiplayer.p2p.object_client"
local enet = require "enet"
local fmt = require "format"
local ai_setup = require "ai.core.setup"

local MAX_EVENTS_PER_FRAME = 48
local HANDSHAKE_TIMEOUT = 10
local DIRECTORY_RESPONSE_TIMEOUT = 10
local TRANSPORT_IDLE_TIMEOUT = 7
local NPC_STATE_INTERVAL = 1/3
local INVENTORY_INTERVAL = 1
local NPC_ROUND_ROBIN_PER_TICK = 4
local NPC_TARGETS_PER_TICK = 4
local NPC_INTERESTS_PER_TICK = 8
local NPC_FOCUS_INTERVAL = 1/10
local NPC_TARGET_INTEREST_REFRESH = 2
local NPC_TARGET_INTEREST_LEASE = 5
local NPC_SNAPSHOT_BATCH_INTERVAL = 0.1
local NPC_SNAPSHOT_RECORDS_PER_BATCH = 8
local NPC_SNAPSHOT_PRUNE_PER_FRAME = 8
local ENTITY_REMOVALS_PER_FRAME = 8
local ACTIVITY_QUERY_INTERVAL = 30
local ACTIVITY_RETENTION = 15*60
local HOST_ALONE_GRACE = 6 -- make "solo p2p" less punishing at gates by keeping this value low
local AGGRESSION_GRACE = 20
-- The outer codec percent-escapes this packed field again. Keeping the raw
-- payload well below MAX_PACKET leaves room for worst-case expansion.
local NPC_MANIFEST_BATCH_PAYLOAD = 4000
local NPC_SNAPSHOT_TIMEOUT = 30
local OBJECT_REQUEST_TIMEOUT = 10
local OBJECT_QUERY_TIMEOUT = 4
local OBJECT_RECONCILE_TIMEOUT = 30
local OBJECT_SUBSCRIPTION_REFRESH = 30
local BUOY_BROADCAST_INTERVAL = 30
local VECTOR_METATABLE = getmetatable(vec2.new())

local session = {
   running=false, peers={}, endpoints={}, players={}, npcs={}, craft={}, departures={},
   peer_meta={}, sequence=0, last_player=0, last_npc=0, last_npc_focus=0,
   last_craft=0,
   last_claim=0, last_claim_check=0, last_liveness=0,
   host_inventory={}, owned_inventory={},
   inventory_snapshot=nil, last_inventory=-math.huge,
   npc_round_robin={}, npc_round_robin_at=1,
   npc_target_interests={}, local_npc_interest_seq=0,
   npc_target_interest_order={}, npc_target_interest_cursor=1,
   npc_target_interest_enqueued={},
   local_npc_interest_target=nil, last_npc_interest=-math.huge,
   craft_factions={}, host_welcomed={}, pending_leader_owners={}, resync_sent={},
   ownership_cache={}, initial_sync_until=0, pending_npc_manifests={},
   pending_npc_manifest_order={}, pending_npc_manifest_cursor=1,
   pending_npc_manifest_enqueued={},
   last_npc_manifest_batch=-math.huge,
   host_npc_controls={}, pending_npc_controls={},
   pending_npc_control_entities={},
   npc_lifecycle_sequences={}, craft_lifecycle_sequences={},
   pending_fighter_bays={},
   pending_entity_removals={},
   host_npc_population=0,
   guest_npc_population=nil, npc_population_events={},
   replica_entity_ids={},
   npc_replica_order={}, npc_replica_enqueued={},
   local_objects={}, local_object_pilots={}, pending_object_requests={},
   pending_object_deletes={}, object_request=0,
   known_objects_by_system={},
   object_subscription_system=nil, object_confirmed_system=nil,
   object_confirmed_at=-math.huge,
   object_client=nil,
   activity={}, activity_received=0, last_activity_query=0,
   directory_probe_deadline=nil,
   indicators=status.new(function () return player.pilot() end),
   player_features="mesh_control_v1,relay_links_v1",
   player_peers={}, direct_links={}, direct_link_signatures={},
   relay_targets={}, relay_topology_dirty=true,
}

-- Networking, liveness, and publication rates are wall-clock concerns. Using
-- ticksGame here makes autonav time compression multiply connection retries
-- and state collection in real time.
local function now () return naev.ticks() end

local function trace ( event, fields )
   local cache=naev.cache()
   if cache.multiplayer_p2p_trace~=true then return end
   local log=cache.multiplayer_p2p_trace_log
   if type(log)~="table" then log={}; cache.multiplayer_p2p_trace_log=log end
   local entry={at=now(),event=event}
   for key,value in pairs(fields or {}) do
      if type(value)=="string" or type(value)=="number"
            or type(value)=="boolean" then entry[key]=value end
   end
   log[#log+1]=entry
   while #log>256 do table.remove(log,1) end
end

local function locally_claimed ()
   return not naev.claimTest(system.cur())
end

local function random_id ()
   local parts={}
   for _i=1,4 do parts[#parts+1]=string.format("%08x",rnd.rnd(0,0x7fffffff)) end
   return table.concat(parts)
end

-- Naev's text input does not reliably accept a literal colon. Configuration
-- therefore accepts both "address port" (the UI form) and "address:port"
-- (the ENet/wire form), but stores and uses only the canonical latter form.
local function normalize_endpoint ( endpoint )
   if type(endpoint) ~= "string" then return nil end
   endpoint=endpoint:match("^%s*(.-)%s*$")
   if endpoint=="" then return "" end
   local host,port=endpoint:match("^([^%s:]+)%s*:%s*(%d+)$")
   if not host then host,port=endpoint:match("^(%S+)%s+(%d+)$") end
   port=tonumber(port)
   if not host or not port or port<1 or port>65535 then return nil end
   return host .. ":" .. tostring(math.floor(port))
end

session.normalize_endpoint = normalize_endpoint

function session.defaults ( settings )
   settings=settings or {}
   settings.enabled=settings.enabled == true
   settings.listen_port=math.max(0,math.min(65535,tonumber(settings.listen_port) or 0))
   local directory=settings.directory == nil and "79.76.110.205:60939" or settings.directory
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

function session.get_settings () return session.settings end

local function exists ( p )
   return p~=nil and p:exists()
end

local function remove_pilot ( p )
   if exists(p) then p:rm() end
end

local function remove_npc_replica ( entity, explode )
   local entry=session.npcs[entity]
   if not entry then return false end
   if exists(entry.pilot) then
      if explode then entry.pilot:explode()
      else entry.pilot:rm() end
   end
   if entry.local_id
         and session.replica_entity_ids[entry.local_id]==entity then
      session.replica_entity_ids[entry.local_id]=nil
   end
   session.npcs[entity]=nil
   session.pending_npc_controls[entity]=nil
   session.pending_npc_control_entities[entity]=nil
   return true
end

function session.pilot_departed ( p, reason )
   if not session.running or not p or p==player.pilot() then return end
   local local_id=tostring(p:id())
   if session.replica_entity_ids[local_id]
         or session.local_object_pilots[local_id] then return end
   local ambient=session.inventory_snapshot and session.inventory_snapshot.ambient
   local craft=session.inventory_snapshot and session.inventory_snapshot.craft
   local entity=session.authoritative_entities
      and session.authoritative_entities[local_id]
      or session.settings.node_id..":"..local_id
   local kind
   if (ambient and ambient[entity]==p) or session.host_inventory[entity]==p then
      kind="npc"
      if ambient then ambient[entity]=nil end
      session.host_inventory[entity]=nil
      session.host_npc_controls[entity]=nil
      session.authoritative_pilots[entity]=nil
      for _recipient,pending in pairs(session.pending_npc_manifests) do
         if pending.records then pending.records[entity]=nil end
         if pending.current and pending.current.id==entity then
            pending.current=nil
         end
      end
   else
      local craft_entity=session.settings.node_id..":"..local_id
      if (craft and craft[craft_entity]==p)
            or session.owned_inventory[craft_entity]==p then
         entity=craft_entity
         kind="craft"
         if craft then craft[entity]=nil end
         session.owned_inventory[entity]=nil
      end
   end
   if not kind then return end
   if session.inventory_snapshot and session.inventory_snapshot.target_entities then
      session.inventory_snapshot.target_entities[local_id]=nil
   end
   session.authoritative_entities[local_id]=nil
   session.ownership_cache[local_id]=nil
   session.pending_fighter_bays[entity]=nil
   local removal_reason=reason
   if removal_reason~="death" and removal_reason~="exploded"
         and removal_reason~="jump" and removal_reason~="land" then
      removal_reason="removed"
   end
   session.pending_entity_removals[entity]={
      kind=kind,
      reason=removal_reason,
   }
end

local function set_ambient_spawning ( enabled )
   enabled=enabled==true
   if session.ambient_spawning==enabled then return end
   pilot.toggleSpawn(enabled)
   session.ambient_spawning=enabled
end

local function lock_autonav ( locked )
   if locked then
      if session.autonav_locked then return end
      session.autonav_locked=true
      naev.keyEnable("speed",false)
      player.autonavSetSpeed(1)
      session.locked_dt_mod=player.dt_mod()
   else
      if not session.autonav_locked then return end
      session.autonav_locked=nil
      session.locked_dt_mod=nil
      naev.keyEnable("speed",true)
      player.autonavSetSpeed()
   end
end

local function no_other_players_discovered ( current_system )
   if session.machine then
      for node in pairs(session.machine.members) do
         if node~=session.settings.node_id then return false end
      end
   end
   for peer,meta in pairs(session.peer_meta) do
      if meta.verified and meta.cap=="player" then return false end
   end
   for _index,entry in ipairs(session.activity or {}) do
      local self_generation=session.self_activity[entry.system]
      local stale_self=self_generation
         and self_generation>=session.activity_generation
      if entry.active and entry.system~=current_system and not stale_self then
         return false
      end
   end
   return true
end

local function refresh_time_controls ( stamp )
   if not session.machine or not session.machine.system then
      session.solo_since=nil
      session.realtime_clock_pinned=nil
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   if session.machine.state=="discovering" and session.skip_host_grace
         and not session.realtime_clock_pinned then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   local remote_session=session.machine.state=="guest"
      or session.machine.state=="recovering"
   local solo=session.machine.state=="host"
   if session.machine.state=="host" then
      for node in pairs(session.machine.members) do
         if node~=session.settings.node_id then
            solo=false
            remote_session=true
            break
         end
      end
   end
   if remote_session then session.realtime_clock_pinned=true end
   if session.realtime_clock_pinned then
      session.skip_host_grace=nil
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(true)
      return
   end
   if not solo then
      session.skip_host_grace=nil
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(true)
      return
   end
   stamp=stamp or now()
   if session.skip_host_grace then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   session.solo_since=session.solo_since or stamp
   local deadline=session.solo_since+HOST_ALONE_GRACE
   session.indicators:host_alone(deadline,stamp)
   lock_autonav(stamp<deadline)
end

local function refresh_discovered_time_controls ( stamp )
   if not session.skip_host_grace or not session.machine
         or not session.machine.system
         or no_other_players_discovered(session.machine.system) then return end
   session.skip_host_grace=nil
   refresh_time_controls(stamp)
end

local function clear_local_controls ()
   local cache=naev.cache()
   cache.accel=0
   cache.primary=0
   cache.secondary=0
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

-- Directory and bootstrap addresses use the same connection path. The remote
-- hello declares whether it is a player or a directory-only node.
local function connect ( endpoint, expected_node )
   if not endpoint_valid(endpoint) or endpoint_is_local_listener(endpoint)
         or session.endpoints[endpoint] then return end
   local peer=session.host:connect(endpoint)
   if peer then
      session.endpoints[endpoint]=peer
      session.peers[peer]=endpoint
      session.peer_meta[peer]={verified=false,expected_node=expected_node,
         outbound=true,connected_at=now()}
      return true
   end
end

local function connect_configured ()
   if endpoint_valid(session.settings.directory) and session.settings.directory~="" then
      connect(session.settings.directory)
   end
   for _index,endpoint in ipairs(session.settings.bootstrap) do connect(endpoint) end
end

local function connect_known_peers ()
   connect_configured()
   for _index,entry in ipairs(session.settings.recent) do
      connect(entry.endpoint)
   end
end

local function send ( peer, message, reliable )
   local packet=codec.encode(message)
   if not packet or not peer then return nil end
   peer:send(packet,0,reliable and "reliable" or "unsequenced")
   return true
end

local has_feature
local function broadcast_raw ( message, reliable, except, except_node )
   local packet
   for peer,meta in pairs(session.peer_meta) do
      if peer~=except and meta.node~=except_node and meta.verified
            and (meta.cap=="player"
               or (meta.cap=="directory"
                  and message.node==session.settings.node_id
                  and (message.type=="claim" or message.type=="leave"))) then
         local new_only=message.type=="player_control" or message.type=="npc_interest"
            or message.type=="member_heartbeat" or message.type=="host_query"
         if not new_only or has_feature(meta,"mesh_control_v1") then
            if packet==nil then
               packet=codec.encode(message)
               if not packet then return false end
            end
            peer:send(packet,0,reliable and "reliable" or "unsequenced")
         end
      end
   end
   return packet~=nil
end

local function broadcast ( message, reliable, except )
   if session.mesh and session.visit and Mesh.routed_type(message.type)
         and not message.via then
      session.mesh:origin(message,session.visit)
   end
   broadcast_raw(message,reliable,except)
end

local function relay_once ( message, except, reliable )
   local forwarded=session.mesh and session.mesh:forward(message)
   if forwarded then
      trace("relay",{type=message.type,node=message.node,
         route_seq=message.route_seq,hops=forwarded.hops})
      -- Every participant has a direct transport to the current authority.
      -- Relaying another guest's packet back to that authority is therefore
      -- a duplicate while the origin still reports that direct path. If the
      -- origin stops reporting it, the ordinary mesh relay resumes.
      local except_node
      local origin_links=session.direct_links[message.node]
      if session.machine and session.machine.state~="host"
            and message.node~=session.machine.host and origin_links
            and origin_links[session.machine.host] then
         except_node=session.machine.host
      end
      broadcast_raw(forwarded,reliable,except,except_node)
   end
end

local function connected_node ( node, except, verified_only )
   for peer,meta in pairs(session.peer_meta) do
      if peer~=except and (not verified_only or meta.verified)
            and (meta.node==node or meta.expected_node==node) then return true end
   end
   return false
end

has_feature = function ( meta, feature )
   return meta and type(meta.features)=="string"
      and (","..meta.features..","):find(","..feature..",",1,true)~=nil
end

function session.local_direct_links ()
   local links={}
   local stamp=now()
   if session.machine then
      for _peer,meta in pairs(session.peer_meta) do
         if meta.verified and meta.cap=="player" and meta.node
               and meta.node~=session.settings.node_id
               and session.machine.members[meta.node]
               and stamp-(meta.last_receive or -math.huge)<=2 then
            links[#links+1]=meta.node
         end
      end
   end
   table.sort(links)
   return #links>0 and table.concat(links,",") or "-"
end

function session.parse_direct_links ( packed )
   local links={}
   if packed and packed~="-" then
      for node in packed:gmatch("([^,]+)") do links[node]=true end
   end
   return links
end

function session.rebuild_relay_targets ()
   local targets={}
   if session.machine and session.machine.state=="host" then
      for origin in pairs(session.machine.members) do
         if origin~=session.settings.node_id then
            local missing={}
            local origin_links=session.direct_links[origin] or {}
            for recipient in pairs(session.machine.members) do
               if recipient~=session.settings.node_id and recipient~=origin
                     and session.player_peers[recipient] then
                  local recipient_links=session.direct_links[recipient] or {}
                  -- Require both ends to report the path. Until then, retain
                  -- the authority relay so stale one-sided UDP state cannot
                  -- silently drop another participant's updates.
                  if not origin_links[recipient]
                        or not recipient_links[origin] then
                     missing[#missing+1]=recipient
                  end
               end
            end
            targets[origin]=missing
         end
      end
   end
   session.relay_targets=targets
   session.relay_topology_dirty=nil
end

function session.relay_missing_player_paths ( message, except, reliable )
   if session.relay_topology_dirty then session.rebuild_relay_targets() end
   local recipients=session.relay_targets[message.node]
   if not recipients then return false end
   local packet
   for _index,node in ipairs(recipients) do
      local peer=session.player_peers[node]
      local meta=peer and session.peer_meta[peer]
      if peer and peer~=except and meta and meta.verified
            and meta.cap=="player" then
         if packet==nil then
            packet=codec.encode(message)
            if not packet then return false end
         end
         peer:send(packet,0,reliable and "reliable" or "unsequenced")
      end
   end
   return packet~=nil
end

local function has_remote_member ()
   if not session.machine then return false end
   for node in pairs(session.machine.members) do
      if node~=session.settings.node_id then return true end
   end
   return false
end

function session.keep_simulation_live ()
   if not session.running or not session.machine or not session.machine.system
         or player.isLanded() or not has_remote_member() then return false end
   naev.unpause()
   session.enforce_time_controls()
   return true
end

local function base ( kind )
   return {type=kind,node=session.settings.node_id,system=session.machine.system,
      visit=session.visit}
end

local function query_rendezvous ()
   if not session.machine or not session.machine.system then return end
   for peer,meta in pairs(session.peer_meta) do
      if meta.verified and meta.cap=="directory" then
         send(peer,base("query"),true)
      end
   end
end

local function local_player_name ()
   local p=player.pilot()
   local name=p and p:exists() and p:name() or nil
   if type(name)=="string" and name~="" then return name end
   return player.name()
end

local function display_text ( text )
   return tostring(text):gsub("#","＃")
end

local chat_sound
local function play_chat_sound ()
   if not chat_sound then chat_sound=audio.new("snd/sounds/hail.opus") end
   chat_sound:play()
end

local disconnect_sound
local function play_disconnect_sound ()
   if not disconnect_sound then disconnect_sound=audio.new("snd/sounds/sokoban/invalid") end
   disconnect_sound:play()
end

local function nearby_transition ( pos, pilot_radius, pilot_faction )
   if not pos then return end
   local px,py=pos:get()

   local best_kind,best_target,best_distance
   local function consider ( kind, target )
      local target_pos=target:pos()
      if not target_pos then return end
      local tx,ty=target_pos:get()
      local dx,dy=tx-px,ty-py
      local distance=dx*dx+dy*dy
      local radius=target:radius()
      if type(radius)~="number" or radius<0 then radius=0 end
      if type(pilot_radius)~="number" or pilot_radius<0 then pilot_radius=0 end
      -- The last 15 Hz state can trail the real ship slightly. Use the target
      -- radius plus the pilot radius and a small packet/smoothing allowance,
      -- but never infer a transition from elsewhere in the system.
      local transition_range=radius+pilot_radius+300
      if distance > transition_range*transition_range then return end
      if not best_distance or distance < best_distance then
         best_kind,best_target,best_distance=kind,target,distance
      end
   end

   local current=system.cur()
   if not current then return end
   for _index,spob in ipairs(current:spobs()) do
      local usable=false
      local services=spob:services()
      if services and services.land then
         usable=true
         if pilot_faction then
            local spob_faction=spob:faction()
            if spob_faction and pilot_faction:areEnemies(spob_faction) then
               usable=false
            end
         end
      end
      if usable then consider("land",spob) end
   end
   for _index,jump in ipairs(current:jumps(true)) do consider("jump",jump) end
   return best_kind,best_target
end

local function departure_candidate ( p )
   return nearby_transition(p:pos(),p:radius(),p:faction())
end

local function clear_departure_controls ( p )
   p:taskClear()
   local memory=p:memory()
   memory.p2p_accel=0
   memory.p2p_primary=false
   memory.p2p_secondary=false
end

local function disable_departure ( p )
   clear_departure_controls(p)
   p:setDisable()
   return "disabled"
end

local function begin_departure ( p )
   local kind,target=departure_candidate(p)
   if not kind then return disable_departure(p) end
   clear_departure_controls(p)
   if kind=="land" then p:pushtask("land",target)
   else p:pushtask("hyperspace",target) end
   return kind
end

local function clear_departure ( node, rejoining )
   local old=session.departures[node]
   if not old then return end
   session.departures[node]=nil
   if not exists(old.pilot) then return end
   if rejoining and old.mode=="disabled" then
      old.pilot:setNoDeath(false)
      old.pilot:explode()
      return
   end
   remove_pilot(old.pilot)
end

local function remove_remote_player ( node )
   local departed=session.players[node]
   if not departed then return false end
   local p=departed.pilot
   session.players[node]=nil
   session.host_welcomed[node]=nil
   if not exists(p) then return false end
   -- Broadcast while the proxy still has its participant name so the comm
   -- bubble is anchored to the ship that actually disconnected.
   p:broadcast("Signal lost.",true)
   play_disconnect_sound()
   p:rename(p:name().." (disconnected "..node:sub(1,6)..")")
   p:setNoDeath(false)
   session.departures[node]={pilot=p,node=node,local_id=tostring(p:id()),mode=begin_departure(p)}
   return true
end

local function hello ( peer )
   send(peer,{type="hello",node=session.settings.node_id,cap="player",name=local_player_name(),
      endpoint=session.endpoint,features=session.player_features},true)
   if session.machine.system then send(peer,base("query"),true) end
end

local function reject_peer ( peer, reason, quiet )
   local endpoint=session.peers[peer]
   local meta=session.peer_meta[peer]
   if meta and meta.node and session.player_peers[meta.node]==peer then
      session.player_peers[meta.node]=nil
      session.relay_topology_dirty=true
   end
   if not quiet then print("P2P: rejected peer: " .. tostring(reason)) end
   peer:disconnect_now()
   session.peers[peer]=nil; session.peer_meta[peer]=nil
   if endpoint then session.endpoints[endpoint]=nil end
end

local function disconnect_player_transports ()
   local stale={}
   for peer,meta in pairs(session.peer_meta) do
      if meta.cap=="player" then stale[#stale+1]=peer end
   end
   for _index,peer in ipairs(stale) do
      reject_peer(peer,"system lifecycle reset",true)
   end
end

local function disconnect_node_transports ( node )
   local stale={}
   for peer,meta in pairs(session.peer_meta) do
      if meta.cap=="player"
            and (meta.node==node or meta.expected_node==node) then
         stale[#stale+1]=peer
      end
   end
   for _index,peer in ipairs(stale) do
      reject_peer(peer,"player liveness timeout",true)
   end
end

local function claim_message ()
   local msg=base("claim")
   msg.claim=session.machine.claim
   msg.endpoint=session.endpoint
   return msg
end

local function outfit_names ( p )
   local names={}
   for _index,o in ipairs(p:outfitsList()) do names[#names+1]=codec.escape(o:nameRaw()) end
   return table.concat(names,",")
end

local function outfit_slots ( p )
   local slots={}
   for index,o in pairs(p:outfits()) do
      if type(index)=="number" and o then
         slots[#slots+1]={
            index=index,
            value=tostring(index)..":"..codec.escape(o:nameRaw()),
         }
      end
   end
   table.sort(slots,function(a,b) return a.index<b.index end)
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
   local outfits=p:outfits()
   for line in packed:gmatch("([^;]+)") do
      local id,slots=line:match("^(%d+):(.*)$")
      id=tonumber(id)
      if id and id>=1 and id<=10 then
         for value in slots:gmatch("(%d+)") do
            local slot=tonumber(value)
            if slot and slot>=1 and slot<=512 and outfits[slot] then
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
      names[#names+1]=codec.escape(name)
      inherited=inherited:inherits()
   end

   local base_type=s:baseType()
   if #names<16 and type(base_type)=="string" and base_type~=""
         and not seen[base_type] and ship.exists(base_type) then
      names[#names+1]=codec.escape(base_type)
   end
   return table.concat(names,",")
end

-- Naev resource getters throw for unknown names. Manifests are untrusted, so
-- this is validation of external data, matching arena's ship-name validation.
local function resource_get ( getter, name )
   local valid,value=pcall(getter,name)
   if valid then return value end
end

local function resolve_proxy_ship ( message )
   if resource_get(ship.get,message.ship) then
      return message.ship,true
   end

   local fallbacks=message.ship_fallbacks
   if type(fallbacks)=="string" and #fallbacks<=2048 then
      local count=0
      for encoded in fallbacks:gmatch("([^,]+)") do
         count=count+1
         if count>16 then break end
         local name=codec.unescape(encoded)
         if name and #name<=240 and not name:find("[%z\1-\31\127]")
               and resource_get(ship.get,name) then
            return name,true
         end
      end
   end

   if resource_get(ship.get,"Plowshare") then
      return "Plowshare",false
   end
end

local function replica_outfit_allowed ( o, fighter_bays_only )
   local fighter_bay=o:type()=="Fighter Bay"
   if fighter_bays_only then return fighter_bay end
   return not fighter_bay
end

local function manifest_has_fighter_bay ( message )
   for item in (message.slots or ""):gmatch("([^,]+)") do
      local encoded=item:match("^%d+:(.+)$")
      local name=encoded and codec.unescape(encoded) or nil
      local o=name and outfit.exists(name) or nil
      if o and o:type()=="Fighter Bay" then return true end
   end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=codec.unescape(item)
      local o=name and outfit.exists(name) or nil
      if o and o:type()=="Fighter Bay" then return true end
   end
   return false
end

-- Fighter craft are synchronized as their own authoritative entities. Never
-- let a replica carrier launch an additional local wing.
local function install_outfits ( p, message, fighter_bays_only )
   local used_slots=false
   for item in (message.slots or ""):gmatch("([^,]+)") do
      local index,encoded=item:match("^(%d+):(.+)$")
      index=tonumber(index)
      local name=encoded and codec.unescape(encoded) or nil
      if index and index>=1 and index<=512 and name then
         local o=outfit.exists(name)
         if o and replica_outfit_allowed(o,fighter_bays_only) then
            p:outfitAddSlot(o,index,true,true)
            used_slots=true
         end
      end
   end
   if used_slots then return end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=codec.unescape(item)
      local o=name and outfit.exists(name) or nil
      if o and replica_outfit_allowed(o,fighter_bays_only) then
         p:outfitAdd(o,1,true)
      end
   end
end

local function install_compatible_outfits ( p, message )
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=codec.unescape(item)
      local o=name and outfit.exists(name) or nil
      if o and replica_outfit_allowed(o,false) then
         -- Preserve slot type, size, and property checks. CPU is irrelevant
         -- for a disposable proxy and is deliberately bypassed.
         p:outfitAdd(o,1,true,false)
      end
   end
end

local reconcile_craft_leaders

local function spawn_proxy ( message, display_name )
   if message.node == session.settings.node_id then return end
   local existing=session.players[message.entity]
   if existing and not exists(existing.pilot) then
      session.players[message.entity]=nil
      existing=nil
   end
   if existing then
      existing.last_seen=now()
      install_weapon_sets(existing.pilot,message.weapsets)
      return
   end
   local proxy_ship,install_manifest_outfits=resolve_proxy_ship(message)
   if not proxy_ship then return end
   clear_departure(message.node,true)
   local fac=faction.dynAdd(nil,"P2P Players","P2P Players",{ai="p2p_remote_control",clear_allies=true,clear_enemies=true})
   local proxy_name=display_name or message.name
   -- The identity registry normally resolves this before spawning. Keep the
   -- invariant here too: a remote participant may never use the local
   -- participant's unsuffixed display name.
   if proxy_name==local_player_name() then proxy_name=proxy_name.." (2)" end
   local position=(message.x and message.y) and vec2.new(message.x,message.y)
      or player.pilot():pos()
   local arrival_kind,arrival_origin=nearby_transition(position,50,fac)
   local p=pilot.add(proxy_ship,fac,arrival_origin or position,proxy_name,
      {ai="p2p_remote_control",naked=true})
   if not p then return end
   if install_manifest_outfits then
      install_outfits(p,message)
   else
      install_compatible_outfits(p,message)
   end
   install_weapon_sets(p,message.weapsets)
   p:fillAmmo()
   -- Invincible pilots are excluded from weapon collision in Naev. No-death
   -- proxies can receive local impact effects while never becoming authority
   -- for the remote player's real health.
   p:setNoDeath(true)
   p:setHealth(message.armour or 100,message.shield or 100,message.stress or 0)
   if p:name()~=proxy_name then p:rename(proxy_name) end
   -- Native takeoff and jump-in setup owns initial motion. Subsequent state
   -- packets smoothly converge the proxy on the remote player's real ship.
   if not arrival_kind then
      if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
      if message.dir then p:setDir(message.dir) end
   end
   ai_setup.setup(p)
   session.players[message.entity]={pilot=p,node=message.node,local_id=tostring(p:id()),
      sequences={},last_seen=now()}
   session.replica_entity_ids[tostring(p:id())]=message.entity
   if reconcile_craft_leaders then session.pending_leader_owners[message.node]=true end
   print("P2P: remote player proxy created")
end

local function active_names ( p )
   local active={}
   for _index,entry in ipairs(p:actives()) do
      if entry.state=="on" or entry.state==true then
         active[#active+1]=codec.escape(entry.outfit:nameRaw())
      end
   end
   return table.concat(active,",")
end

local function target_entity ( target )
   if not target then return "" end
   if target==player.pilot() then return session.settings.node_id end
   if exists(target) then
      local local_id=tostring(target:id())
      local replica_entity=session.replica_entity_ids[local_id]
      local replica=replica_entity and (session.players[replica_entity]
         or session.npcs[replica_entity] or session.craft[replica_entity])
      if replica and replica.pilot==target then return replica_entity end
      session.replica_entity_ids[local_id]=nil
      local object_id=session.local_object_pilots[local_id]
      if object_id then return object_id end
      if session.machine and session.machine.state=="host" then
         return session.authoritative_entities
            and session.authoritative_entities[local_id]
            or session.settings.node_id..":"..local_id
      end
   end
   return ""
end

local function entity_pilot ( id )
   if id==session.settings.node_id then
      local p=player.pilot()
      if exists(p) then return p end
      return nil
   end
   local entry=session.players[id] or session.npcs[id] or session.craft[id]
      or session.local_objects[id]
   if entry then
      if exists(entry.pilot) then return entry.pilot end
      return nil
   end
   local authoritative=session.authoritative_pilots
      and session.authoritative_pilots[id]
   if exists(authoritative) then return authoritative end
   local owned_pilot=session.owned_inventory and session.owned_inventory[id]
   if exists(owned_pilot) then return owned_pilot end
   -- Unknown wire identities are repaired through reliable manifests. Never
   -- turn a state or control packet into a full pilot.get() search.
   return nil
end

local function local_state ( p )
   local x,y=p:pos():get(); local vx,vy=p:vel():get()
   local armour,shield,stress=p:health()
   local cache=naev.cache()
   local target=p:target()
   -- Input hooks do not see thrust commanded by Naev's autonav AI. A rising
   -- squared speed is a cheap proxy for forward thrust that excludes autonav
   -- coasting and braking without adding engine calls or square roots.
   local speed2=vx*vx+vy*vy
   local accelerating=(cache.accel and cache.accel~=0)
      or (session.local_speed2 and speed2>session.local_speed2+1)
   session.local_speed2=speed2
   return {x=x,y=y,vx=vx,vy=vy,dir=p:dir(),accel=accelerating and 1 or 0,
      primary=(cache.primary and cache.primary~=0) and 1 or 0,
      secondary=(cache.secondary and cache.secondary~=0) and 1 or 0,
      weapset=session.local_weapset or 1,
      target=target_entity(target),active=active_names(p),energy=p:energy(),
      armour=armour,shield=shield,stress=stress}
end

local function motion_target ( entry, state, received )
   entry.motion={x=state.x,y=state.y,vx=state.vx,vy=state.vy,dir=state.dir,
      received=received or now()}
end

local player_smoothing={position_gain=2.5,correction_speed=600,velocity_rate=12,
   acceleration=2400,direction_rate=14,max_prediction=0.25}
local npc_smoothing={position_gain=1.5,correction_speed=250,velocity_rate=8,
   acceleration=600,direction_rate=10,direction_speed=2,max_prediction=0.4}
local craft_smoothing={position_gain=2,correction_speed=400,velocity_rate=10,
   acceleration=1200,direction_rate=12,max_prediction=0.3}

local function smooth_entry ( entry, dt, stamp, limits )
   local p=entry.pilot
   if not entry.motion or not exists(p) then return end
   local x,y=p:pos():get(); local vx,vy=p:vel():get(); local dir=p:dir()
   local m=reconcile.steer({x=x,y=y,vx=vx,vy=vy,dir=dir},entry.motion,
      dt,stamp-entry.motion.received,limits)
   if math.abs(m.vx-vx)>0.01 or math.abs(m.vy-vy)>0.01 then
      p:setVel(vec2.new(m.vx,m.vy))
   end
   if math.abs(math.sin((m.dir-dir)/2))>0.00025 then
      p:setDir(m.dir)
   end
end

local smooth_elapsed=0

local function reset_smoothing ()
   smooth_elapsed=0
end

local function smooth_replicas ( dt, stamp )
   dt=math.max(0,math.min(tonumber(dt) or 1/60,0.1))
   smooth_elapsed=smooth_elapsed+dt
   if smooth_elapsed+1e-9 < 1/30 then return end
   local step=math.min(smooth_elapsed,0.1)
   smooth_elapsed=smooth_elapsed%(1/30)
   for _entity_id,entry in pairs(session.players) do
      smooth_entry(entry,step,stamp,player_smoothing)
   end
end

local function mark_player_aggression ( node )
   local entry=session.players[node]
   if not entry or not exists(entry.pilot) then return end
   local stamp=now()
   entry.last_aggression=stamp
   session.indicators:mark_aggression(stamp+AGGRESSION_GRACE,stamp)
   if not entry.p2p_hostile then
      entry.pilot:setHostile(true)
      entry.p2p_hostile=true
   end
end

local request_resync

local function apply_player_control ( message )
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then
      if entry then session.players[message.entity]=nil end
      request_resync("all",message.node)
      return false
   end
   local sequence=tonumber(message.seq)
   if not sequence or sequence<=(entry.control_seq or -1) then return false end
   local target_id=message.target~="-" and message.target or nil
   local target=target_id and entity_pilot(target_id) or nil
   local memory=entry.pilot:memory()
   if target_id and not target then
      entry.pending_control=message
      entry.pilot:setTarget(nil)
      entry.target_pilot=nil
      memory.p2p_primary=false
      memory.p2p_secondary=false
      -- A release is safety-critical even when its requested target has not
      -- been manifested yet.
      if message.primary==0 and message.secondary==0 then
         entry.control_seq=sequence
         entry.pending_control=nil
      end
      request_resync("npc",nil,target_id)
      trace("control_pending",{node=message.node,seq=sequence,target=target_id})
      return false
   end
   local old_primary=memory.p2p_primary==true
   local old_secondary=memory.p2p_secondary==true
   entry.control_seq=sequence
   entry.pending_control=nil
   entry.target_pilot=target
   entry.applied=entry.applied or {}
   entry.applied.target=target_id or "-"
   entry.pilot:setTarget(target)
   local px,py=entry.pilot:pos():get()
   local dx,dy=message.x-px,message.y-py
   local position_error=math.sqrt(dx*dx+dy*dy)
   -- A reliable input edge must not become a transform snap. The proxy keeps
   -- its current physical state and converges through the same capped motion
   -- path as ordinary player state packets.
   motion_target(entry,message)
   if message.energy then
      local live_energy=entry.pilot:energy()
      if math.abs(live_energy-message.energy)>0.01 then
         entry.pilot:setEnergy(message.energy)
      end
   end
   if message.weapset~=nil then memory.p2p_weapset=message.weapset end
   memory.p2p_primary=message.primary==1
   memory.p2p_secondary=message.secondary==1
   if memory.p2p_primary and not old_primary then
      memory.p2p_primary_edges=math.min(4,(memory.p2p_primary_edges or 0)+1)
      entry.pilot:fillAmmo()
      entry.last_ammo_fill=now()
   end
   if memory.p2p_secondary and not old_secondary then
      memory.p2p_secondary_edges=math.min(4,(memory.p2p_secondary_edges or 0)+1)
      entry.pilot:fillAmmo()
      entry.last_ammo_fill=now()
   end
   trace("control_apply",{node=message.node,seq=sequence,
      target=target_id or "-",primary=memory.p2p_primary,
      secondary=memory.p2p_secondary,position_error=position_error})
   return true
end

local function apply_player_state ( message )
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then
      session.players[message.entity]=nil
      request_resync("all",message.node)
      return
   end
   if not reconcile.accept(entry.sequences,"state",message.seq) then return end
   entry.last_seen=now()
   motion_target(entry,message)
   local p=entry.pilot
   entry.applied=entry.applied or {}
   local target_id=(message.target and message.target~="") and message.target or "-"
   local target=target_id=="-" and nil or entity_pilot(target_id)
   if (target_id=="-" or target) and p:target()~=target then
         p:setTarget(target)
      entry.target_pilot=target
   end
   local memory=p:memory()
   memory.p2p_accel=message.accel==1 and 1 or 0
   if message.control_seq and message.control_seq>(entry.control_seq or -1) then
      apply_player_control{
         node=message.node,entity=message.entity,seq=message.control_seq,
         target=target_id,primary=message.primary,secondary=message.secondary,
         x=message.x,y=message.y,vx=message.vx,vy=message.vy,dir=message.dir,
         energy=message.energy,weapset=message.weapset,
      }
      target=entry.target_pilot
   elseif not message.control_seq then
      memory.p2p_primary=message.primary==1
      memory.p2p_secondary=message.secondary==1
      if message.weapset~=nil then memory.p2p_weapset=message.weapset end
   end
   -- Match arena semantics: a participant becomes hostile locally only
   -- after firing at this client's real player. It stays hostile until the
   -- pair has been quiet for the hostility grace period.
   if target==player.pilot() and (memory.p2p_primary or memory.p2p_secondary) then
      mark_player_aggression(message.node)
   end
   -- The remote participant is authoritative for its own health. Repair only
   -- this disposable proxy from that reported state; never write health to
   -- player.pilot().
   local live_armour,live_shield,live_stress=p:health()
   if math.abs(live_armour-message.armour)>0.01
         or math.abs(live_shield-message.shield)>0.01
         or math.abs(live_stress-message.stress)>0.01 then
      p:setHealth(message.armour,message.shield,message.stress)
   end
   if message.energy then
      local live_energy=p:energy()
      if math.abs(live_energy-message.energy)>0.01 then p:setEnergy(message.energy) end
   end
   -- Replica ammo is a local counter. Refill on fire edges and at a bounded
   -- one-second cadence while firing, rather than crossing into the engine on
   -- every 15 Hz state packet.
   if (memory.p2p_primary or memory.p2p_secondary)
         and now()-(entry.last_ammo_fill or -math.huge)>=1 then
      p:fillAmmo()
      entry.last_ammo_fill=now()
   end
   local active_wire=message.active or ""
   if entry.applied.active~=active_wire then
      local desired={}
      for item in active_wire:gmatch("([^,]+)") do
         local name=codec.unescape(item)
         if name then desired[name]=true end
      end
      entry.active=entry.active or {}
      local slots={}
      for _index,active in ipairs(p:actives()) do
         local name=active.outfit:nameRaw()
         if name then slots[name]=active.slot end
      end
      for name in pairs(entry.active) do
         if not desired[name] and slots[name] then p:outfitToggle(slots[name],false) end
      end
      for name in pairs(desired) do
         if not entry.active[name] and slots[name] then p:outfitToggle(slots[name],true) end
      end
      entry.active=desired
      entry.applied.active=active_wire
   end
end

local function publish_player_control ( force )
   if not session.machine or not session.machine.system then return end
   local p=player.pilot()
   if not exists(p) then return end
   local state=local_state(p)
   local target=state.target~="" and state.target or "-"
   local signature=table.concat({
      target,state.primary,state.secondary,state.weapset,
   },":")
   if not force and signature==session.local_control_signature then return end
   session.local_control_signature=signature
   session.local_control_seq=(session.local_control_seq or 0)+1
   local msg=base("player_control")
   msg.entity=session.settings.node_id
   msg.seq=session.local_control_seq
   msg.target=target
   msg.primary=state.primary; msg.secondary=state.secondary
   msg.weapset=state.weapset
   msg.energy=state.energy
   msg.x=state.x; msg.y=state.y; msg.vx=state.vx; msg.vy=state.vy; msg.dir=state.dir
   broadcast(msg,true)
   trace("control_emit",{seq=msg.seq,target=target,
      primary=msg.primary,secondary=msg.secondary})
end

local function pilot_owned ( p )
   if p:withPlayer() then return true end
   local seen={}
   while p and not seen[p] do
      seen[p]=true
      local leader=p:leader()
      if not leader then return false end
      if leader==player.pilot() then return true end
      p=leader
   end
   return false
end

local function pilot_id ( p )
   if not exists(p) then return nil end
   return tostring(p:id())
end

local function authoritative_entity ( p )
   local id=pilot_id(p)
   if not id then return nil end
   return session.authoritative_entities
      and session.authoritative_entities[id]
      or session.settings.node_id..":"..id
end

local function replica_lookup ()
   local lookup={}
   for _entity_id,e in pairs(session.players) do if e.local_id then lookup[e.local_id]=true end end
   for _entity_id,e in pairs(session.npcs) do if e.local_id then lookup[e.local_id]=true end end
   for _entity_id,e in pairs(session.craft) do if e.local_id then lookup[e.local_id]=true end end
   for _node,e in pairs(session.departures) do if e.local_id then lookup[e.local_id]=true end end
   return lookup
end

-- High-frequency state collection must remain deliberately small. In
-- particular, do not add ship, name, faction, outfit, or leader calls here:
-- each one crosses the Lua/C boundary and belongs only in a reliable manifest.
local function craft_state_record ( p, entity, target_entities )
   local armour,shield,stress=p:health(); local x,y=p:pos():get(); local vx,vy=p:vel():get()
   local target=p:target()
   local target_id=""
   if exists(target) then
      target_id=target_entities and target_entities[tostring(target:id())]
         or target_entity(target)
      if (not target_id or target_id=="") and session.machine.state=="host"
            and target~=player.pilot() then
         local local_id=pilot_id(target)
         if local_id then target_id=session.settings.node_id..":"..local_id end
      end
      target_id=target_id or ""
   end
   return {entity=entity,x=x,y=y,vx=vx,vy=vy,dir=p:dir(),armour=armour,shield=shield,
      stress=stress,energy=p:energy(),target=target_id,disabled=p:disabled()}
end

local function task_goal ( p, target_id )
   local task=p:taskname()
   if not task then return "","" end
   local data=p:taskdata()
   if data and data==p:target() and target_id and target_id~="" then
      return task,"pilot:"..target_id
   end
   if data then
      local current=system.cur()
      if current then
         for _index,spob in ipairs(current:spobs()) do
            if data==spob then return task,"spob:"..spob:nameRaw() end
         end
         for _index,jump in ipairs(current:jumps(true)) do
            if data==jump then return task,"jump:"..jump:dest():nameRaw() end
         end
      end
      local data_type=type(data)
      local vector_data=VECTOR_METATABLE
            and getmetatable(data)==VECTOR_METATABLE
         or (data_type=="table" and type(data.get)=="function")
      if vector_data then
         local x,y=data:get()
         if type(x)=="number" and type(y)=="number"
               and math.abs(x)<=1e9 and math.abs(y)<=1e9 then
            return task,string.format("vector:%.8g:%.8g",x,y)
         end
      end
      -- AI tasks also carry private values such as vectors and internal state.
      -- Sending the task name without that required argument creates malformed
      -- tasks on replicas (notably loiter(nil), which warns from ai.face every
      -- frame). Leave unsupported control to the replicated AI profile.
      return "",""
   end
   -- Unknown no-argument tasks are not a compatibility contract. Replicating
   -- an arbitrary task name as pushtask(task,nil) can create invalid AI state.
   return "",""
end

local function manifest_record ( p, entity, with_control )
   local rec=craft_state_record(p,entity)
   local leader_id=""
   local leader=p:leader()
   if exists(leader) then
      local local_id=pilot_id(leader)
      leader_id=leader==player.pilot() and session.settings.node_id
         or (local_id and authoritative_entity(leader) or "")
   end
   rec.ship=p:ship():nameRaw()
   rec.name=p:name()
   rec.faction=p:faction():nameRaw()
   rec.outfits=outfit_names(p)
   rec.slots=outfit_slots(p)
   -- Exact-slot data is authoritative for NPC and owned-craft replicas. Avoid
   -- duplicating every outfit name in the same reliable manifest packet.
   if rec.slots~="" then rec.outfits="" end
   rec.leader=leader_id
   if with_control then
      -- AI identity and the top-level goal are reliable, static manifest
      -- data. They must never be added to the frequent NPC state record.
      rec.ai=p:ainame() or ""
      rec.task,rec.goal=task_goal(p,rec.target)
   end
   return rec
end

local function add_message ( rec, kind, owner )
   session.sequence=session.sequence+1
   local msg=base(kind); msg.entity=rec.entity; msg.seq=session.sequence; msg.ship=rec.ship
   msg.name=rec.name; msg.faction=rec.faction; msg.outfits=rec.outfits; msg.slots=rec.slots
   msg.x=rec.x; msg.y=rec.y; msg.vx=rec.vx; msg.vy=rec.vy; msg.dir=rec.dir
   msg.armour=rec.armour; msg.shield=rec.shield; msg.stress=rec.stress; msg.energy=rec.energy
   msg.target=rec.target; msg.leader=rec.leader
   msg.ai=rec.ai; msg.task=rec.task; msg.goal=rec.goal
   if session.machine.claim then msg.claim=session.machine.claim end
   if owner then msg.owner=owner end
   return msg
end

local function manifest_field ( value )
   if value==nil or value=="" then return "~" end
   return "v"..codec.escape(value)
end

local function manifest_line ( rec )
   return table.concat({
      manifest_field(rec.entity),manifest_field(rec.ship),manifest_field(rec.name),
      manifest_field(rec.faction),manifest_field(rec.outfits),manifest_field(rec.slots),
      manifest_field(rec.x),manifest_field(rec.y),manifest_field(rec.vx),
      manifest_field(rec.vy),manifest_field(rec.dir),manifest_field(rec.armour),
      manifest_field(rec.shield),manifest_field(rec.stress),manifest_field(rec.energy),
      manifest_field(rec.target),manifest_field(rec.leader),
   },",")
end

local function control_line ( rec )
   return table.concat({manifest_field(rec.entity),manifest_field(rec.ai),
      manifest_field(rec.task),manifest_field(rec.goal)},",")
end

local function queue_npc_manifests ( records, recipient )
   if not recipient or recipient==session.settings.node_id
         or not session.machine.members[recipient]
         or session.pending_npc_manifests[recipient] then return false end
   session.npc_snapshot=(session.npc_snapshot or 0)+1
   session.pending_npc_manifests[recipient]={
      recipient=recipient,records=records,next_key=nil,
      visited={},snapshot=session.npc_snapshot,
      baseline=session.sequence,population=session.host_npc_population,count=0,
   }
   if not session.pending_npc_manifest_enqueued[recipient] then
      session.pending_npc_manifest_enqueued[recipient]=true
      session.pending_npc_manifest_order[
         #session.pending_npc_manifest_order+1]=recipient
   end
   return true
end

local function publish_next_npc_manifest_batch ( stamp )
   stamp=stamp or now()
   if stamp-session.last_npc_manifest_batch<NPC_SNAPSHOT_BATCH_INTERVAL then return end
   local order=session.pending_npc_manifest_order
   if #order==0 then return end
   local start=math.max(1,math.min(session.pending_npc_manifest_cursor,#order))
   local pending,pending_index
   for offset=0,#order-1 do
      local index=(start+offset-1)%#order+1
      local recipient=order[index]
      local candidate=session.pending_npc_manifests[recipient]
      if candidate and session.machine.members[recipient] then
         pending=candidate
         pending_index=index
         break
      end
      session.pending_npc_manifests[recipient]=nil
   end
   if not pending then
      session.pending_npc_manifest_order={}
      session.pending_npc_manifest_enqueued={}
      session.pending_npc_manifest_cursor=1
      return
   end
   session.last_npc_manifest_batch=stamp
   local function finish_snapshot ()
      if not pending.finished or pending.current then return false end
      session.sequence=session.sequence+1
      local done=base("npc_done")
      done.claim=session.machine.claim
      done.seq=session.sequence
      done.snapshot=pending.snapshot
      done.baseline=pending.baseline
      done.population=pending.population
      done.count=pending.count
      done.recipient=pending.recipient
      broadcast(done,true)
      session.pending_npc_manifests[pending.recipient]=nil
      session.pending_npc_manifest_cursor=pending_index%#order+1
      return true
   end
   local batch,control_batch,size,control_size={},{},0,0
   local inspected=0
   while inspected<NPC_SNAPSHOT_RECORDS_PER_BATCH do
      local entry=pending.current
      if not entry then
         local cursor=pending.next_key
         if cursor~=nil and pending.records[cursor]==nil then cursor=nil end
         local id,p=next(pending.records,cursor)
         pending.next_key=id
         if not id then
            pending.finished=true
            break
         end
         if pending.visited[id] then
            inspected=inspected+1
         else
            pending.visited[id]=true
            entry={id=id,pilot=p}
            pending.current=entry
         end
      end
      if not entry then
         -- A lifecycle deletion can invalidate the table cursor and restart
         -- traversal. Previously visited keys still consume the fixed batch
         -- budget, preventing restart recovery from becoming a frame spike.
      else
         inspected=inspected+1
         if not exists(entry.pilot) then
            pending.current=nil
         else
            local rec=entry.rec or manifest_record(entry.pilot,entry.id,true)
            entry.rec=rec
            local line=manifest_line(rec)
            local control=control_line(rec)
            if #line>NPC_MANIFEST_BATCH_PAYLOAD
                  or #control>NPC_MANIFEST_BATCH_PAYLOAD then
               if #batch>0 then break end
               pending.current=nil
               local add=add_message(rec,"npc_add")
               add.snapshot=pending.snapshot
               add.baseline=pending.baseline
               add.recipient=pending.recipient
               broadcast(add,true)
               pending.count=pending.count+1
               finish_snapshot()
               return
            end
            if #batch>0 and (size+#line+1>NPC_MANIFEST_BATCH_PAYLOAD
                  or control_size+#control+1>NPC_MANIFEST_BATCH_PAYLOAD) then break end
            batch[#batch+1]=line
            control_batch[#control_batch+1]=control
            size=size+#line+1
            control_size=control_size+#control+1
            pending.current=nil
         end
      end
   end
   if #batch>0 then
      session.sequence=session.sequence+1
      local msg=base("npc_manifest")
      msg.claim=session.machine.claim
      msg.seq=session.sequence
      msg.snapshot=pending.snapshot
      msg.baseline=pending.baseline
      msg.recipient=pending.recipient
      msg.entities=table.concat(batch,";")
      broadcast(msg,true)
      pending.count=pending.count+#batch
      session.sequence=session.sequence+1
      local control=base("npc_control")
      control.claim=session.machine.claim
      control.seq=session.sequence
      control.baseline=pending.baseline
      control.recipient=pending.recipient
      control.entities=table.concat(control_batch,";")
      broadcast(control,true)
   end
   if not finish_snapshot() and #order>0 then
      session.pending_npc_manifest_cursor=pending_index%#order+1
   end
end

local function state_line ( rec )
   return table.concat({rec.entity,rec.x,rec.y,rec.vx,rec.vy,rec.dir,rec.armour,rec.shield,
      rec.stress,rec.energy,(rec.target and rec.target~="") and rec.target or "-",
      rec.disabled and 1 or 0},",")
end

local function inventory ( include_ambient, include_craft, prune_unauthorized )
   local list=pilot.get()
   local unauthorized={}
   if next(session.pending_fighter_bays or {}) then
      local active_leaders={}
      for _index,p in ipairs(list) do
         if exists(p) then
            local leader=p:leader()
            if exists(leader) then active_leaders[leader]=true end
         end
      end
      for entity,pending in pairs(session.pending_fighter_bays) do
         if not exists(pending.pilot) then
            session.pending_fighter_bays[entity]=nil
         elseif not active_leaders[pending.pilot] then
            install_outfits(pending.pilot,pending.manifest,true)
            session.pending_fighter_bays[entity]=nil
         end
      end
   end
   local replicas=replica_lookup()
   local ambient,craft={},{ }
   local authoritative_pilots={}
   local seen={}
   local target_entities={[tostring(player.pilot():id())]=session.settings.node_id}
   for entity,e in pairs(session.players) do if e.local_id then target_entities[e.local_id]=entity end end
   for entity,e in pairs(session.npcs) do if e.local_id then target_entities[e.local_id]=entity end end
   for entity,e in pairs(session.craft) do if e.local_id then target_entities[e.local_id]=entity end end
   for _index,p in ipairs(list) do
      if exists(p) then
         local id=pilot_id(p)
         seen[id]=true
         if p~=player.pilot() and not replicas[id]
               and not session.local_object_pilots[id] then
            local entity=authoritative_entity(p)
            target_entities[id]=entity
            local owned_by_player=session.ownership_cache[id]
            if owned_by_player==nil then
               owned_by_player=pilot_owned(p)
               session.ownership_cache[id]=owned_by_player
            end
            if (owned_by_player and include_craft)
                  or (not owned_by_player and include_ambient and session.machine.state=="host") then
               if owned_by_player then
                  craft[session.settings.node_id..":"..id]=p
               else
                  ambient[entity]=p
                  authoritative_pilots[entity]=p
               end
            elseif prune_unauthorized and not owned_by_player then
               unauthorized[#unauthorized+1]=p
            end
         end
      end
   end
   for _index,p in ipairs(unauthorized) do remove_pilot(p) end
   for id in pairs(session.ownership_cache) do
      if not seen[id] then session.ownership_cache[id]=nil end
   end
   session.authoritative_pilots=authoritative_pilots
   for id in pairs(session.authoritative_entities or {}) do
      if not seen[id] then session.authoritative_entities[id]=nil end
   end
   return ambient,craft,target_entities
end

local function cached_inventory ( stamp, force )
   local snapshot=session.inventory_snapshot
   if not force and snapshot
         and stamp-session.last_inventory<INVENTORY_INTERVAL then
      return snapshot.ambient,snapshot.craft,snapshot.target_entities,false
   end
   local ambient,craft,target_entities=inventory(true,true,
      session.machine.state~="host" and not session.locally_claimed)
   session.inventory_snapshot={
      ambient=ambient,
      craft=craft,
      target_entities=target_entities,
   }
   session.last_inventory=stamp
   local ring={}
   for entity in pairs(ambient) do ring[#ring+1]=entity end
   session.npc_round_robin=ring
   if session.npc_round_robin_at>#ring then session.npc_round_robin_at=1 end
   return ambient,craft,target_entities,true
end

local function remove_guest_population ()
   local list=pilot.get()
   local replicas=replica_lookup()
   for _index,p in ipairs(list) do
      if exists(p) and p~=player.pilot() and not replicas[pilot_id(p)]
            and not session.local_object_pilots[pilot_id(p)]
            and not pilot_owned(p) then
         remove_pilot(p)
      end
   end
   set_ambient_spawning(false)
   for _object_id,entry in pairs(session.local_objects) do
      if exists(entry.pilot) then entry.pilot:setNoDeath(true) end
   end
end

local function craft_faction ( owner )
   local fac=session.craft_factions[owner]
   if fac then return fac end
   local display=session.identities and session.identities:display_name(owner) or owner
   local raw="P2P Craft "..owner
   local existing=resource_get(faction.get,raw)
   if existing then fac=existing
   else
      fac=faction.dynAdd(nil,raw,(display or owner).." Craft",
         {ai="escort",clear_allies=true,clear_enemies=true})
   end
   session.craft_factions[owner]=fac
   return fac
end

local function resolve_task_goal ( goal )
   if not goal or goal=="" then return nil,true end
   local entity=goal:match("^pilot:(.+)$")
   if entity then
      local target=entity_pilot(entity)
      return target,target~=nil
   end
   local spob_name=goal:match("^spob:(.+)$")
   local jump_name=goal:match("^jump:(.+)$")
   local vector_x,vector_y=goal:match("^vector:([^:]+):([^:]+)$")
   if vector_x then
      vector_x,vector_y=tonumber(vector_x),tonumber(vector_y)
      if vector_x and vector_y and math.abs(vector_x)<=1e9
            and math.abs(vector_y)<=1e9 then
         return vec2.new(vector_x,vector_y),true
      end
      return nil,false
   end
   local current=system.cur()
   if not current then return nil,false end
   if spob_name then
      for _index,spob in ipairs(current:spobs()) do
         if spob:nameRaw()==spob_name then return spob,true end
      end
   elseif jump_name then
      for _index,jump in ipairs(current:jumps(true)) do
         if jump:dest():nameRaw()==jump_name then return jump,true end
      end
   end
   return nil,false
end

local function apply_npc_control ( entry, message )
   if message.ai==nil or message.task==nil or message.goal==nil then return end
   local sequence=tonumber(message.seq)
   local entity=message.entity or entry.entity
   if sequence and sequence<=(entry.control_seq or -1) then return end
   if sequence and entry.pending_control and entry.pending_control.seq
         and sequence<entry.pending_control.seq then return end
   local p=entry.pilot
   local current_ai=p:ainame() or ""
   if message.ai~="" and current_ai~=message.ai then
      p:changeAI(message.ai)
      ai_setup.setup(p)
      current_ai=p:ainame() or ""
   end
   if current_ai~=message.ai then return end
   if message.task=="" then
      entry.control={entity=entity,ai=message.ai,task="",goal=""}
      entry.control_seq=sequence or entry.control_seq
      entry.pending_control=nil
      return
   end
   local current_task=p:taskname() or ""
   local goal,ready=resolve_task_goal(message.goal)
   local current_goal=p:taskdata()
   local goal_matches=message.goal=="" or (ready and current_goal==goal)
   if ready and not goal_matches and message.goal:sub(1,7)=="vector:"
         and current_goal then
      local current_type=type(current_goal)
      local vector_goal=VECTOR_METATABLE
            and getmetatable(current_goal)==VECTOR_METATABLE
         or (current_type=="table" and type(current_goal.get)=="function")
      if vector_goal then
         local cx,cy=current_goal:get()
         local gx,gy=goal:get()
         goal_matches=math.abs(cx-gx)<0.01 and math.abs(cy-gy)<0.01
      end
   end
   if current_task~=message.task or not goal_matches then
      if not ready then
         entry.pending_control={
            entity=entity,ai=message.ai,task=message.task,
            goal=message.goal,seq=message.seq,
         }
         if entity then session.pending_npc_control_entities[entity]=true end
         return
      end
      -- Control repair changes only AI/task state. Motion remains under the
      -- capped velocity and direction reconciliation path.
      if goal and message.goal:sub(1,6)=="pilot:"
            and p:target()~=goal then
         p:setTarget(goal)
      end
      p:taskClear()
      if message.task~="" then p:pushtask(message.task,goal) end
   end
   entry.control={
      entity=entity,ai=message.ai,task=message.task,goal=message.goal,
   }
   entry.control_seq=sequence or entry.control_seq
   entry.pending_control=nil
   if entity then session.pending_npc_control_entities[entity]=nil end
   entry.control_mismatch=nil
   entry.control_mismatch_at=nil
end

local function spawn_npc ( message, craft_owner )
   local container=craft_owner and session.craft or session.npcs
   local existing=container[message.entity]
   if existing and not exists(existing.pilot) then
      container[message.entity]=nil
      existing=nil
   end
   if existing and not craft_owner and existing.manifest
         and (existing.manifest.ship~=message.ship
            or existing.manifest.faction~=message.faction
            or existing.manifest.name~=message.name) then
      remove_npc_replica(message.entity,true)
      existing=nil
   end
   if existing then
      existing.leader_id=message.leader
      existing.manifest=message
      if craft_owner then
         session.pending_leader_owners[craft_owner]=true
      else
         session.pending_npc_leaders=true
         apply_npc_control(existing,message)
         local pending=session.pending_npc_controls[message.entity]
         if pending then
            apply_npc_control(existing,pending)
            if (existing.control_seq or -1)>=(pending.seq or -1) then
               session.pending_npc_controls[message.entity]=nil
            end
         end
      end
      return true
   end
   if not resource_get(ship.get,message.ship)
         or (not craft_owner and not resource_get(faction.get,message.faction)) then return false end
   local fac=craft_owner and craft_faction(craft_owner) or message.faction
   local params=craft_owner and {ai="escort",naked=true}
      or {ai=message.ai~="" and message.ai or nil,naked=true}
   local p=pilot.add(message.ship,fac,vec2.new(message.x or 0,message.y or 0),
      message.name,params)
   if not p then return false end
   install_outfits(p,message,false)
   -- Health and existence belong to the host for ambient NPCs and to the
   -- publishing player for owned craft. Local weapons may still disable and
   -- visibly hit replicas, but must not delete them before their authority
   -- sends a reliable removal.
   p:setNoDeath(true)
   local target_id=(message.target and message.target~="") and message.target or "-"
   local entry={entity=message.entity,pilot=p,owner=craft_owner,
      leader_id=message.leader,
      manifest=message,
      local_id=tostring(p:id()),sequences={},
      applied={armour=message.armour,shield=message.shield,stress=message.stress,
         energy=message.energy,target=target_id=="-" and "-" or nil,
         disabled=message.disabled==true or message.disabled=="1"}}
   container[message.entity]=entry
   session.replica_entity_ids[entry.local_id]=message.entity
   if not craft_owner and not session.npc_replica_enqueued[message.entity] then
      session.npc_replica_enqueued[message.entity]=true
      session.npc_replica_order[#session.npc_replica_order+1]=message.entity
   end
   if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
   if message.dir then p:setDir(message.dir) end
   if message.armour then p:setHealth(message.armour,message.shield,message.stress) end
   if message.energy then p:setEnergy(message.energy) end
   if message.target and message.target~="" then
      local target=entity_pilot(message.target)
      if target then
         p:setTarget(target)
         entry.applied.target=message.target
      end
   end
   if craft_owner then
      ai_setup.setup(p)
      session.pending_leader_owners[craft_owner]=true
   else
      ai_setup.setup(p)
      session.pending_npc_leaders=true
      apply_npc_control(entry,message)
      local pending=session.pending_npc_controls[message.entity]
      if pending then
         apply_npc_control(entry,pending)
         if (entry.control_seq or -1)>=(pending.seq or -1) then
            session.pending_npc_controls[message.entity]=nil
         end
      end
   end
   return true
end

reconcile_craft_leaders = function ( owner )
   for _entity_id,entry in pairs(session.craft) do
      if entry.owner==owner and exists(entry.pilot) then
         local leader
         if entry.leader_id==owner then
            local player_entry=session.players[owner]
            leader=player_entry and player_entry.pilot or nil
         elseif entry.leader_id and entry.leader_id~="" then
            local craft_entry=session.craft[entry.leader_id]
            leader=craft_entry and craft_entry.pilot or nil
         end
         if leader and exists(leader) and entry.bound_leader~=leader then
            entry.pilot:setLeader(leader)
            entry.bound_leader=leader
         end
      end
   end
end

local function reconcile_npc_leaders ()
   for _entity_id,entry in pairs(session.npcs) do
      if exists(entry.pilot) then
         local leader_entry=entry.leader_id and session.npcs[entry.leader_id]
         local leader=leader_entry and leader_entry.pilot or nil
         if leader and exists(leader) and entry.pilot:leader()~=leader then
            entry.pilot:setLeader(leader)
         end
      end
   end
end

local function apply_craft_order ( message )
   local owner_entry=session.players[message.owner]
   local leader=owner_entry and owner_entry.pilot or nil
   if not leader or not exists(leader) then return end
   local recipients={}
   for _entity_id,entry in pairs(session.craft) do
      if entry.owner==message.owner and exists(entry.pilot) then
         recipients[#recipients+1]=entry.pilot
      end
   end
   if #recipients==0 then return end
   local target=message.order=="e_attack" and entity_pilot(message.target) or nil
   if message.order=="e_attack" and not target then return end
   if target==player.pilot() then
      mark_player_aggression(message.owner)
      for _index,recipient in ipairs(recipients) do recipient:setHostile(true) end
   end
   leader:msg(recipients,message.order,target)
end

local publish_entities,publish_player,publish_manifests,remember_npc_interest

local function parse_states ( packed, container, owner, sequence )
   local missing=false
   local received=now()
   local limits=owner and craft_smoothing or npc_smoothing
   local step=owner and 1 or NPC_STATE_INTERVAL
   for line in packed:gmatch("([^;]+)") do
      local f={}; for value in line:gmatch("([^,]+)") do f[#f+1]=value end
      local id=f[1]; local entry=container[id]
      if entry and not exists(entry.pilot) then
         container[id]=nil
         entry=nil
      end
      local applicable=entry and (not owner or entry.owner==owner)
         and exists(entry.pilot)
      if applicable and reconcile.accept(entry.sequences,"state",sequence) then
         local state={x=tonumber(f[2]),y=tonumber(f[3]),vx=tonumber(f[4]),vy=tonumber(f[5]),dir=tonumber(f[6]),armour=tonumber(f[7]),shield=tonumber(f[8]),stress=tonumber(f[9]),energy=tonumber(f[10])}
         local bounded=state.x and state.energy and math.abs(state.x)<=1e9 and math.abs(state.y)<=1e9
            and math.abs(state.vx)<=1e7 and math.abs(state.vy)<=1e7 and math.abs(state.dir)<=1e6
            and state.armour>=0 and state.armour<=1e9 and state.shield>=0 and state.shield<=1e9
            and state.stress>=0 and state.stress<=1e9 and state.energy>=0 and state.energy<=1e9
         if bounded then
            motion_target(entry,state,received)
            -- NPC and owned-craft populations can contain hundreds of pilots.
            -- Correct replicas only when their authoritative packet arrives.
            -- NPC angular correction is capped, so a bad direction is repaired
            -- over multiple packets without adding any per-frame NPC work.
            smooth_entry(entry,step,received,limits)
            local live_armour,live_shield,live_stress=entry.pilot:health()
            if math.abs(live_armour-state.armour)>0.01
                  or math.abs(live_shield-state.shield)>0.01
                  or math.abs(live_stress-state.stress)>0.01 then
               entry.pilot:setHealth(state.armour,state.shield,state.stress)
            end
            local live_energy=entry.pilot:energy()
            if math.abs(live_energy-state.energy)>0.01 then
               entry.pilot:setEnergy(state.energy)
            end
            local authoritative_disabled=f[12]=="1"
            if entry.pilot:disabled()~=authoritative_disabled then
               entry.pilot:setDisable(authoritative_disabled)
            end
            local target_id=(f[11] and f[11]~="") and f[11] or "-"
            local target=target_id=="-" and nil or entity_pilot(target_id)
            if (target_id=="-" or target) and entry.pilot:target()~=target then
                  entry.pilot:setTarget(target)
               if owner and target==player.pilot() then entry.pilot:setHostile(true) end
            end
            if not owner and entry.control then
               apply_npc_control(entry,entry.control)
            end
         end
      elseif not entry and id then
         missing=true
      end
   end
   if missing and request_resync and now()>=(session.initial_sync_until or 0) then
      -- One state packet can mention the host's entire NPC population. Ask
      -- that authority once, not once per missing line/entity.
      request_resync(owner and "craft" or "npc",owner)
   end
end

local function parse_manifest_field ( field )
   if field=="~" then return "" end
   if field:sub(1,1)~="v" then return nil end
   return codec.unescape(field:sub(2))
end

local function advance_guest_population ( population )
   population=tonumber(population)
   if not population then return false end
   session.guest_npc_population=population
   while session.npc_population_events[population+1] do
      session.npc_population_events[population+1]=nil
      population=population+1
      session.guest_npc_population=population
   end
   for revision in pairs(session.npc_population_events) do
      if revision<=population then session.npc_population_events[revision]=nil end
   end
   return true
end

local function guest_population_has_gap ()
   local population=session.guest_npc_population
   if population==nil then return true end
   for revision in pairs(session.npc_population_events) do
      if revision>population+1 then return true end
   end
   return false
end

local function note_population_event ( message )
   local population=tonumber(message.population)
   if not population or message.snapshot~=nil then return end
   local current=session.guest_npc_population
   if current~=nil and population<=current then return end
   session.npc_population_events[population]=true
   if current~=nil then advance_guest_population(current) end
   if not session.receiving_npc_snapshot and guest_population_has_gap() then
      request_resync("npc")
   end
end

local function accept_npc_snapshot ( message )
   if message.snapshot==nil then return true end
   local current=session.receiving_npc_snapshot
   if current and current.claim==message.claim then
      if message.snapshot<current.snapshot then return false end
      if message.snapshot==current.snapshot then
         return not current.baseline or not message.baseline
            or current.baseline==message.baseline
      end
   end
   session.receiving_npc_snapshot={
      claim=message.claim,snapshot=message.snapshot,seen={},count=0,
      baseline=message.baseline,
      deadline=now()+NPC_SNAPSHOT_TIMEOUT,
   }
   return true
end

local function mark_npc_snapshot ( message, entity )
   local current=session.receiving_npc_snapshot
   if message.snapshot==nil or not current
         or current.claim~=message.claim
         or current.snapshot~=message.snapshot
         or current.seen[entity] then return end
   current.seen[entity]=true
   current.count=current.count+1
end

local function complete_npc_snapshot ( current )
   if current.pruning then return false end
   local expected=current.expected_count
   if expected==nil or current.count<expected then return false end
   if current.count>expected then
      session.receiving_npc_snapshot=nil
      request_resync("npc")
      return false
   end
   current.pruning=true
   current.prune_at=1
   current.prune_limit=#session.npc_replica_order
   return false
end

local function service_npc_snapshot_prune ()
   local current=session.receiving_npc_snapshot
   if not current or not current.pruning then return end
   local processed=0
   while current.prune_at<=current.prune_limit
         and processed<NPC_SNAPSHOT_PRUNE_PER_FRAME do
      local entity=session.npc_replica_order[current.prune_at]
      current.prune_at=current.prune_at+1
      processed=processed+1
      local lifecycle=session.npc_lifecycle_sequences[entity] or -1
      if session.npcs[entity] and not current.seen[entity]
            and lifecycle<=(current.baseline or current.done_seq) then
         remove_npc_replica(entity,true)
      end
   end
   if current.prune_at>current.prune_limit then
      advance_guest_population(current.population)
      if guest_population_has_gap() then request_resync("npc") end
      session.receiving_npc_snapshot=nil
   end
end

local function finish_npc_snapshot ( message )
   local current=session.receiving_npc_snapshot
   if not current or current.claim~=message.claim
         or message.snapshot>current.snapshot then
      current={
         claim=message.claim,snapshot=message.snapshot,seen={},count=0,
         baseline=message.baseline,population=message.population,
         deadline=now()+NPC_SNAPSHOT_TIMEOUT,
      }
      session.receiving_npc_snapshot=current
   elseif message.snapshot<current.snapshot then
      return false
   elseif current.baseline and message.baseline
         and current.baseline~=message.baseline then
      return false
   end
   current.expected_count=message.count
   current.done_seq=message.seq
   current.baseline=message.baseline or current.baseline or message.seq
   current.population=message.population or current.population
   return complete_npc_snapshot(current)
end

local function accept_lifecycle ( sequences, entity, sequence )
   sequence=tonumber(sequence)
   if not sequence or sequence<=(sequences[entity] or -1) then return false end
   sequences[entity]=sequence
   return true
end

local function clear_owner_lifecycle ( sequences, owner )
   local prefix=owner..":"
   for entity in pairs(sequences) do
      if entity:sub(1,#prefix)==prefix then sequences[entity]=nil end
   end
end

local function spawn_npc_manifest ( message )
   for line in message.entities:gmatch("([^;]+)") do
      local fields,field_count,valid={},0,true
      for field in line:gmatch("([^,]+)") do
         field_count=field_count+1
         local decoded=parse_manifest_field(field)
         if decoded==nil then valid=false else fields[field_count]=decoded end
      end
      if valid and (field_count==17 or field_count==20) then
         local manifest={
            type="npc_add",node=message.node,system=message.system,claim=message.claim,
            seq=message.seq,entity=fields[1],ship=fields[2],name=fields[3],
            faction=fields[4],outfits=fields[5],slots=fields[6],
            x=fields[7],y=fields[8],vx=fields[9],vy=fields[10],dir=fields[11],
            armour=fields[12],shield=fields[13],stress=fields[14],energy=fields[15],
            target=fields[16]~="" and fields[16] or nil,
            leader=fields[17]~="" and fields[17] or nil,
            ai=fields[18],task=fields[19],goal=fields[20],
         }
         if codec.validate(manifest) then
            local accepted=accept_lifecycle(session.npc_lifecycle_sequences,
               manifest.entity,message.baseline or message.seq)
            if (accepted and spawn_npc(manifest)) or not accepted then
               mark_npc_snapshot(message,manifest.entity)
               local current=session.receiving_npc_snapshot
               if current then complete_npc_snapshot(current) end
            end
         end
      end
   end
end

local function apply_npc_control_batch ( message )
   for line in message.entities:gmatch("([^;]+)") do
      local fields,field_count,valid={},0,true
      for field in line:gmatch("([^,]+)") do
         field_count=field_count+1
         local decoded=parse_manifest_field(field)
         if decoded==nil then valid=false else fields[field_count]=decoded end
      end
      if valid and field_count==4 then
         local control={
            type="npc_control",node=message.node,system=message.system,
            claim=message.claim,seq=message.baseline or message.seq,
            entities=message.entities,
            entity=fields[1],ai=fields[2],task=fields[3],goal=fields[4],
         }
         local entry=session.npcs[control.entity]
         if codec.validate(control) then
            if entry and exists(entry.pilot) then
               apply_npc_control(entry,control)
            else
               local pending=session.pending_npc_controls[control.entity]
               local lifecycle=session.npc_lifecycle_sequences[control.entity]
               if (not lifecycle or control.seq>lifecycle)
                     and (not pending or control.seq>pending.seq) then
                  session.pending_npc_controls[control.entity]=control
               end
            end
         end
      end
   end
end

local function handle_host_loss ()
   session.machine:host_lost()
   reconcile.host_lost(session.npcs)
end

local function promote_guest_population ()
   -- Replicas already run native AI. On takeover their current live state is
   -- the new authority; only remove replica protection and bookkeeping.
   session.authoritative_entities={}
   session.authoritative_pilots={}
   session.pending_fighter_bays={}
   local inherited_fighters={}
   local inherited_count=0
   for _entity_id,entry in pairs(session.npcs) do
      if exists(entry.pilot) and entry.leader_id and entry.leader_id~="" then
         inherited_fighters[entry.leader_id]=true
      end
   end
   for entity_id,entry in pairs(session.npcs) do
      if exists(entry.pilot) then
         inherited_count=inherited_count+1
         if entry.manifest and inherited_fighters[entity_id]
               and manifest_has_fighter_bay(entry.manifest) then
            session.pending_fighter_bays[entity_id]={
               pilot=entry.pilot,manifest=entry.manifest,
            }
         elseif entry.manifest then
            install_outfits(entry.pilot,entry.manifest,true)
         end
         entry.pilot:setNoDeath(false)
         local local_id=pilot_id(entry.pilot)
         if local_id then session.authoritative_entities[local_id]=entity_id end
         session.authoritative_pilots[entity_id]=entry.pilot
      end
   end
   session.npcs={}
   session.host_inventory={}
   session.host_npc_controls={}
   session.pending_npc_controls={}
   session.pending_npc_control_entities={}
   session.npc_lifecycle_sequences={}
   session.npc_snapshot=0
   session.receiving_npc_snapshot=nil
   session.host_npc_population=0
   session.guest_npc_population=nil
   session.npc_population_events={}
   session.pending_npc_leaders=nil
   -- Snapshot-created pilots have no native Naev presence charge. Re-enabling
   -- the scheduler underneath them would create a second full ambient
   -- population. An initial claimant has no inherited replicas and should use
   -- Naev's normal scheduler; a failover authority keeps the inherited
   -- population for the remainder of this system visit.
   set_ambient_spawning(inherited_count==0)
   for _object_id,entry in pairs(session.local_objects) do
      if exists(entry.pilot) then entry.pilot:setNoDeath(false) end
   end
end

local function demote_host_population ()
   -- A recovering host can rejoin a guest that inherited these same stable
   -- entities. Preserve the live pilots as replicas until the new host's
   -- complete snapshot proves otherwise. This avoids a visible population
   -- teardown/recreation during authority transfer.
   local ambient=inventory(true,false)
   for entity,p in pairs(ambient) do
      if exists(p) and not session.npcs[entity] then
         local deferred=session.pending_fighter_bays[entity]
         local manifest=deferred and deferred.manifest
            or manifest_record(p,entity,true)
         for slot,o in pairs(p:outfits()) do
            if o and o:type()=="Fighter Bay" then p:outfitRmSlot(slot) end
         end
         p:setNoDeath(true)
         local target_id=manifest.target~="" and manifest.target or "-"
         session.npcs[entity]={
            entity=entity,pilot=p,leader_id=manifest.leader,manifest=manifest,
            local_id=pilot_id(p),sequences={},
            control={ai=manifest.ai,task=manifest.task,goal=manifest.goal},
            applied={
               armour=manifest.armour,shield=manifest.shield,
               stress=manifest.stress,energy=manifest.energy,
               target=target_id,disabled=manifest.disabled==true,
            },
         }
         local local_id=pilot_id(p)
         if local_id then session.replica_entity_ids[local_id]=entity end
         if not session.npc_replica_enqueued[entity] then
            session.npc_replica_enqueued[entity]=true
            session.npc_replica_order[#session.npc_replica_order+1]=entity
         end
      end
   end
   session.authoritative_entities={}
   session.authoritative_pilots={}
   session.host_inventory={}
   session.host_npc_controls={}
   session.pending_fighter_bays={}
   session.pending_npc_leaders=true
   set_ambient_spawning(false)
   for _object_id,entry in pairs(session.local_objects) do
      if exists(entry.pilot) then entry.pilot:setNoDeath(true) end
   end
end

local function join_host_population ( old_state )
   local preserving=old_state=="host"
      or (old_state=="recovering" and next(session.host_inventory)~=nil)
   if preserving then demote_host_population()
   else remove_guest_population() end
   session.host_npc_controls={}
   session.pending_npc_controls={}
   session.pending_npc_control_entities={}
   session.npc_lifecycle_sequences={}
   session.receiving_npc_snapshot=nil
   session.guest_npc_population=nil
   session.npc_population_events={}
end

local function host_hint ( peer )
   local hint
   if session.machine.state=="host" then
      hint={host=session.settings.node_id,endpoint=session.endpoint,claim=session.machine.claim,expires=now()+60}
   elseif not session.locally_claimed then
      hint=session.machine.topology:hint(session.machine.system)
   end
   if hint then
      send(peer,{type="hint",node=session.settings.node_id,system=session.machine.system,host=hint.host,
         endpoint=hint.endpoint,claim=hint.claim,ttl=math.max(1,math.min(60,hint.expires-now()))},true)
   end
end

local buoy_faction

local function object_directory_peer ()
   if session.object_client and session.object_client:available() then
      return session.object_client
   end
end

local function publish_object_capability ()
   local cache=naev.cache()
   cache.multiplayer_p2p_objects=session.running
      and object_directory_peer()~=nil or false
end

local function next_object_request ()
   session.object_request=(session.object_request or 0)+1
   return session.object_request
end

local function remove_local_object ( object_id )
   local entry=session.local_objects[object_id]
   if not entry then return end
   entry.removing=true
   if entry.hook then hook.rm(entry.hook) end
   if entry.local_id then session.local_object_pilots[entry.local_id]=nil end
   remove_pilot(entry.pilot)
   session.local_objects[object_id]=nil
end

local function explode_local_object ( object_id )
   local entry=session.local_objects[object_id]
   if not entry then return end
   entry.removing=true
   if entry.hook then hook.rm(entry.hook) end
   if entry.local_id then session.local_object_pilots[entry.local_id]=nil end
   session.local_objects[object_id]=nil
   if exists(entry.pilot) then entry.pilot:explode() end
end

local function clear_local_objects ()
   local ids={}
   for object_id in pairs(session.local_objects) do ids[#ids+1]=object_id end
   for _index,object_id in ipairs(ids) do remove_local_object(object_id) end
end

local function message_buoy_endpoint ( object )
   if object.kind~="message_buoy" or not session.machine
         or not session.machine.system then return end
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible and endpoint.system==session.machine.system then
         return endpoint
      end
   end
end

local function remember_object ( object )
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible then
         local known=session.known_objects_by_system[endpoint.system]
         if not known then
            known={}
            session.known_objects_by_system[endpoint.system]=known
         end
         known[object.id]=object
      end
   end
end

local function forget_object ( object_id )
   for system_name,known in pairs(session.known_objects_by_system) do
      known[object_id]=nil
      if next(known)==nil then
         session.known_objects_by_system[system_name]=nil
      end
   end
end

local function spawn_local_object ( object )
   local endpoint=message_buoy_endpoint(object)
   if not endpoint then return end
   local old=session.local_objects[object.id]
   if old and old.object.revision>=object.revision then return end
   if old then remove_local_object(object.id) end
   if not buoy_faction then
      buoy_faction=faction.dynAdd(nil,"P2P Message Buoys","Message Buoys",
         {ai="dummy",clear_allies=true,clear_enemies=true})
   end
   local p=pilot.add("Message Buoy",buoy_faction,
      vec2.new(endpoint.x,endpoint.y),
      "Message Buoy",{ai="dummy",naked=true})
   if not p then return end
   p:setDir(endpoint.dir)
   p:setFriendly(true)
   -- Guest copies receive local impact effects, but persistent-object
   -- existence is decided by the host's native simulation. Guest player
   -- controls target this exact object ID on the host proxy.
   p:setNoDeath(session.machine.state~="host")
   -- Persistent objects are navigation landmarks. Keep the local copy
   -- detectable throughout the system regardless of ordinary sensor range.
   p:setVisplayer(true)
   p:setHilight(true)
   local local_id=tostring(p:id())
   local entry={object=object,pilot=p,local_id=local_id,
      announce_at=now()+1}
   session.local_objects[object.id]=entry
   session.local_object_pilots[local_id]=object.id
   entry.hook=hook.pilot(p,"death","P2P_OBJECT_DESTROYED",object.id)
end

local function spawn_known_objects ( system_name )
   for _object_id,object in pairs(
         session.known_objects_by_system[system_name] or {}) do
      spawn_local_object(object)
   end
end

local function complete_object_create ( request, pending, object_id )
   -- The reliable result is independently sufficient proof that the directory
   -- accepted this exact object. Do not depend on the separate subscription
   -- push to make the deploying client see its own buoy.
   if pending.object and pending.object.id==object_id then
      remember_object(pending.object)
      spawn_local_object(pending.object)
   end
   session.pending_object_requests[request]=nil
   naev.cache().multiplayer_buoy_consume={
      slot=pending.slot,object_id=object_id,
   }
   player.msg("#g".._("Message buoy deployed.").."#0")
end

local function fail_object_create ( request, code )
   session.pending_object_requests[request]=nil
   local reasons={
      occupied=_("This system already has a message buoy."),
      capacity=_("The directory cannot accept more persistent objects."),
      duplicate=_("That object ID is already in use."),
      forbidden=_("The directory rejected the message buoy."),
      invalid=_("The directory rejected invalid buoy data."),
      timeout=_("Message buoy deployment timed out."),
      missing=_("The directory did not retain the message buoy."),
   }
   player.msg("#r"..(reasons[code]
      or _("Message buoy deployment failed.")).."#0")
end

local function reconcile_object_create ( object )
   if object.owner~=session.settings.node_id then return end
   for request,pending in pairs(session.pending_object_requests) do
      if (pending.action=="create" or pending.action=="create_reconcile")
            and pending.object_id==object.id
            and pending.system
            and Object.visible_in(object,pending.system) then
         complete_object_create(request,pending,object.id)
         return true
      end
   end
end

local function apply_object_entry ( message )
   local object=Object.decode(message.object)
   if not object then return end
   reconcile_object_create(object)
   if message.request==0 then
      remember_object(object)
      spawn_local_object(object)
      return
   end
   local pending=session.pending_object_requests[message.request]
   if not pending or pending.action~="query"
         or not Object.visible_in(object,pending.system) then return end
   pending.objects[object.id]=object
end

local send_object_create

local function finish_object_query ( message )
   local pending=session.pending_object_requests[message.request]
   if not pending or pending.action~="query"
         or pending.system~=message.system then return end
   local received=0
   for _object_id in pairs(pending.objects) do received=received+1 end
   if received~=message.count then
      session.pending_object_requests[message.request]=nil
      session.object_confirmed_system=nil
      session.object_confirmed_at=-math.huge
      if session.object_client then session.object_client:invalidate() end
      return
   end
   session.pending_object_requests[message.request]=nil
   local occupied=false
   for _id,object in pairs(pending.objects) do
      if object.kind=="message_buoy"
            and Object.visible_in(object,pending.system) then
         occupied=true
         break
      end
   end
   for request,creation in pairs(session.pending_object_requests) do
      if creation.action=="create_reconcile"
            and creation.system==message.system then
         if occupied then
            fail_object_create(request,"occupied")
         else
            creation.action="create"
            send_object_create(object_directory_peer(),request,creation)
         end
      end
   end
   local previously_known=session.known_objects_by_system[message.system] or {}
   for object_id in pairs(previously_known) do
      if not pending.objects[object_id] then forget_object(object_id) end
   end
   session.known_objects_by_system[message.system]=nil
   for _id,object in pairs(pending.objects) do remember_object(object) end
   if session.object_subscription_system==message.system then
      session.object_confirmed_system=message.system
      session.object_confirmed_at=now()
   end
   print("P2P objects: confirmed "..message.system.." request="
      ..tostring(message.request).." count="..tostring(message.count))
   if not session.machine or session.machine.system~=message.system then return end
   local remove={}
   for object_id in pairs(session.local_objects) do
      if not pending.objects[object_id] then remove[#remove+1]=object_id end
   end
   for _index,object_id in ipairs(remove) do explode_local_object(object_id) end
   for _id,object in pairs(pending.objects) do spawn_local_object(object) end
end

local function query_objects ( peer )
   if not peer or not session.machine or not session.machine.system then return end
   local system_name=session.machine.system
   for _request,pending in pairs(session.pending_object_requests) do
      if pending.action=="query" and pending.system==system_name then return end
   end
   local request=next_object_request()
   session.pending_object_requests[request]={
      action="query",system=system_name,objects={},
      deadline=now()+OBJECT_QUERY_TIMEOUT,
   }
   send(peer,{type="object_query",node=session.settings.node_id,
      system=system_name,request=request},true)
   print("P2P objects: query "..system_name.." request="..tostring(request))
end

local function ensure_object_subscription ()
   if not session.object_subscription_system
         or not session.machine
         or session.machine.system~=session.object_subscription_system then return end
   if session.object_confirmed_system==session.object_subscription_system
         and now()-session.object_confirmed_at<OBJECT_SUBSCRIPTION_REFRESH then
      return
   end
   query_objects(object_directory_peer())
end

local function send_pending_object_deletes ( peer )
   if not peer then return end
   for object_id,entry in pairs(session.pending_object_deletes) do
      if not entry.sent then
         local request=next_object_request()
         entry.sent=true
         entry.request=request
         session.pending_object_requests[request]={
            action="delete",object_id=object_id,
            deadline=now()+OBJECT_REQUEST_TIMEOUT,
         }
         send(peer,{type="object_delete",node=session.settings.node_id,
            request=request,object_id=object_id},true)
      end
   end
end

local function has_pending_object_delete ( system_name )
   for _object_id,entry in pairs(session.pending_object_deletes) do
      if not entry.system or entry.system==system_name then return true end
   end
   return false
end

send_object_create = function ( peer, request, pending )
   if not peer then return false end
   pending.action="create"
   pending.deadline=now()+OBJECT_REQUEST_TIMEOUT
   if send(peer,{type="object_create",node=session.settings.node_id,
         request=request,object_id=pending.object_id,
         object=pending.packed},true) then return true end
   pending.action="create_wait_delete"
   pending.deadline=now()+OBJECT_RECONCILE_TIMEOUT
   return false
end

local function send_waiting_object_creates ( peer )
   if not peer then return end
   for request,pending in pairs(session.pending_object_requests) do
      if pending.action=="create_wait_delete"
            and not has_pending_object_delete(pending.system) then
         send_object_create(peer,request,pending)
      end
   end
end

local function object_result ( message )
   local pending=session.pending_object_requests[message.request]
   if not pending then return end
   if pending.action=="create" or pending.action=="create_reconcile" then
      if message.action~="create"
            or message.object_id~=pending.object_id then return end
      if message.ok==1 then
         if pending.object then pending.object.revision=message.revision end
         complete_object_create(message.request,pending,message.object_id)
      else
         fail_object_create(message.request,message.code)
      end
   elseif pending.action=="delete" then
      if message.action~="delete"
            or message.object_id~=pending.object_id then return end
      session.pending_object_requests[message.request]=nil
      local entry=session.pending_object_deletes[pending.object_id]
      if message.ok==1 then
         session.pending_object_deletes[pending.object_id]=nil
         send_waiting_object_creates(object_directory_peer())
      elseif entry then
         entry.sent=false
      end
   end
end

local function handle_directory_object_message ( message )
   if message.type=="object_entry" then
      apply_object_entry(message)
   elseif message.type=="object_done" then
      finish_object_query(message)
   elseif message.type=="object_deleted" then
      forget_object(message.object_id)
      explode_local_object(message.object_id)
      session.pending_object_deletes[message.object_id]=nil
      send_waiting_object_creates(object_directory_peer())
   elseif message.type=="object_result" then
      object_result(message)
   end
end

local function reset_object_requests_after_disconnect ()
   for request,pending in pairs(session.pending_object_requests) do
      if pending.action=="create" then
         pending.action="create_reconcile"
         pending.deadline=now()+OBJECT_RECONCILE_TIMEOUT
      elseif pending.action=="query" then
         session.pending_object_requests[request]=nil
      elseif pending.action=="delete" then
         session.pending_object_requests[request]=nil
         local queued=session.pending_object_deletes[pending.object_id]
         if queued then queued.sent=false; queued.request=nil end
      end
   end
end

local function process_object_deadlines ( stamp )
   local expired={}
   for request,pending in pairs(session.pending_object_requests) do
      if stamp>=pending.deadline then expired[#expired+1]=request end
   end
   for _index,request in ipairs(expired) do
      local pending=session.pending_object_requests[request]
      if pending and (pending.action=="query" or pending.action=="create"
            or pending.action=="delete")
            and session.object_client
            and session.object_client:available() then
         print("P2P objects: reconnecting after unanswered "
            ..pending.action.." request="..tostring(request))
         session.object_client:invalidate()
         return
      end
   end
   for _index,request in ipairs(expired) do
      local pending=session.pending_object_requests[request]
      if pending.action=="create" then
         pending.action="create_reconcile"
         pending.deadline=stamp+OBJECT_RECONCILE_TIMEOUT
         local peer=object_directory_peer()
         if peer then query_objects(peer) end
      elseif pending.action=="create_reconcile" then
         -- A missing reply is not a rejection. Keep the stable object ID and
         -- reconcile until the directory either returns the object or an
         -- authoritative query proves the system is occupied by another one.
         pending.deadline=stamp+OBJECT_RECONCILE_TIMEOUT
         local peer=object_directory_peer()
         if peer then query_objects(peer) end
      elseif pending.action=="create_wait_delete" then
         pending.deadline=stamp+OBJECT_RECONCILE_TIMEOUT
         send_waiting_object_creates(object_directory_peer())
      elseif pending.action=="delete" then
         session.pending_object_requests[request]=nil
         local queued=session.pending_object_deletes[pending.object_id]
         if queued then queued.sent=false; queued.request=nil end
      else
         session.pending_object_requests[request]=nil
      end
   end
   if stamp-(session.last_object_retry or 0)>=1 then
      session.last_object_retry=stamp
      local peer=object_directory_peer()
      send_pending_object_deletes(peer)
      send_waiting_object_creates(peer)
   end
end

-- Persistent-object traffic uses a dedicated ENet host, independently of the
-- system authority and gameplay transports.
function session.update_object_client ()
   if not session.running then return false end
   if session.object_client then session.object_client:update() end
   process_object_deadlines(now())
   ensure_object_subscription()
   local stamp=now()
   for object_id,entry in pairs(session.local_objects) do
      if not exists(entry.pilot) then
         -- Landing and system teardown remove pilots without implying that
         -- the persistent object was destroyed.
         remove_local_object(object_id)
      elseif stamp>=entry.announce_at then
         entry.pilot:broadcast(display_text(entry.object.data.text),true)
         entry.announce_at=stamp+BUOY_BROADCAST_INTERVAL
      end
   end
   return true
end

function session.object_service_pending ()
   if not session.running then return false end
   return next(session.pending_object_requests)~=nil
      or next(session.pending_object_deletes)~=nil
end

local function start_object_client ()
   if session.object_client or session.settings.directory=="" then return end
   session.object_client=ObjectClient.new{
      endpoint=session.settings.directory,
      node=session.settings.node_id,
      name=local_player_name(),
      now=now,
         on_ready=function(client)
            publish_object_capability()
            send_pending_object_deletes(client)
            session.object_confirmed_system=nil
            session.object_confirmed_at=-math.huge
            ensure_object_subscription()
            send_waiting_object_creates(client)
      end,
      on_message=handle_directory_object_message,
         on_disconnect=function()
            reset_object_requests_after_disconnect()
            session.object_confirmed_system=nil
            session.object_confirmed_at=-math.huge
            publish_object_capability()
      end,
   }
   local object_ok,object_err=session.object_client:start()
   if not object_ok then
      print("P2P: "..tostring(object_err))
      session.object_client=nil
   end
end

local function on_message ( peer, message )
   local meta=session.peer_meta[peer] or {}; session.peer_meta[peer]=meta
   if message.type=="hello" then
      if message.node==session.settings.node_id then
         reject_peer(peer,"self connection"); return
      end
      if meta.expected_node and meta.expected_node~=message.node then
         reject_peer(peer,"unexpected node identity"); return
      end
      if message.cap=="player" then
         local duplicate_peer,duplicate_meta
         for other,other_meta in pairs(session.peer_meta) do
            if other~=peer and other_meta.verified and other_meta.cap=="player"
                  and other_meta.node==message.node then
               duplicate_peer,duplicate_meta=other,other_meta
               break
            end
         end
         if duplicate_peer then
            local prefer_outbound=session.settings.node_id<message.node
            if meta.outbound==prefer_outbound and duplicate_meta.outbound~=prefer_outbound then
               reject_peer(duplicate_peer,"duplicate connection",true)
            else
               reject_peer(peer,"duplicate connection",true)
               return
            end
         end
         local accepted,err=session.identities:add(message.node,message.name)
         if not accepted and err=="node changed player name" and not duplicate_peer then
            accepted,err=session.identities:update(message.node,message.name)
            local entry=session.players[message.node]
            if accepted and entry and exists(entry.pilot) then
               entry.pilot:rename(accepted)
            end
         end
         if not accepted then reject_peer(peer,err); return end
         meta.name=message.name
      end
      meta.node=message.node; meta.cap=message.cap
      meta.features=message.features or ""; meta.verified=true
      meta.last_receive=now()
      if meta.cap=="player" then
         session.member_features[message.node]=meta.features
         session.player_peers[message.node]=peer
         session.relay_topology_dirty=true
      end
      local endpoint=session.peers[peer]
      if meta.cap=="player" and endpoint_valid(endpoint) then
         session.machine.topology:add_peer(endpoint)
         session.settings.recent=session.machine.topology:serialize_peers()
      end
      if message.cap=="player" and session.machine.system then send(peer,base("query"),true) end
      if message.cap=="player" then refresh_discovered_time_controls() end
      if message.cap=="player" and session.machine.state=="guest"
            and message.node==session.machine.host then
         -- A reconnecting guest may contain only stale extra NPCs, so no
         -- incoming state can reveal that it needs repair. Re-verifying the
         -- incumbent transport is the bounded positive signal for a fresh
         -- authoritative membership snapshot.
         request_resync("npc")
      end
      if message.cap=="directory" then
         if session.machine.state=="host" then send(peer,claim_message(),true) end
         if has_feature(meta,"activity") then
            local sent=send(peer,{
               type="activity_query",node=session.settings.node_id,
            },true)
            session.last_activity_query=now()
            if sent then
               session.directory_probe_deadline=
                  session.last_activity_query+DIRECTORY_RESPONSE_TIMEOUT
            end
         end
         if has_feature(meta,"objects") then start_object_client() end
      end
      return
   end
   if not meta.verified then return end
   if message.type=="punch" then
      if meta.cap=="directory" and message.system==session.machine.system
            and message.peer~=session.settings.node_id then
         connect(message.endpoint,message.peer)
      end
      return
   end
   if message.type=="query" then host_hint(peer); return end
   if message.type=="hint" then
      if session.locally_claimed then return end
      if message.host==session.settings.node_id then return end
      if meta.node==message.host and endpoint_valid(session.peers[peer]) then message.endpoint=session.peers[peer] end
      local expires=now()+message.ttl
      if session.machine.topology:remember_hint(message.system,message.host,message.endpoint,message.claim,expires) then
         session.settings.recent=session.machine.topology:serialize_peers()
         if meta.node==message.host and meta.cap=="player" then
            local old_state,old_host,old_claim=session.machine.state,
               session.machine.host,session.machine.claim
            local accepted=session.machine:accept_claim{system=message.system,node=message.host,claim=message.claim}
            local joined=accepted and (old_state~="guest"
               or old_host~=message.host
               or old_claim~=session.machine.claim)
            refresh_time_controls()
            if joined then
               join_host_population(old_state)
               request_resync("all")
            end
         else
            if not connected_node(message.host) then connect(message.endpoint,message.host) end
         end
      end
      return
   end
   if meta.cap=="directory" then
      if message.type=="activity" then
         local received=now()
         local activity={}
         if message.entries~="-" then
            for line in message.entries:gmatch("([^;]+)") do
               if #activity>=20 then break end
               local encoded,active,age=line:match("^([^,]+),([01]),(%d+)$")
               local system_name=encoded and codec.unescape(encoded) or nil
               age=tonumber(age)
               if system_name and system_name~="" and #system_name<=240
                     and not system_name:find("[%z\1-\31\127]")
                     and age and age>=0 and age<=86400 then
                  activity[#activity+1]={system=system_name,active=active=="1",
                     seen=received-age}
               end
            end
         end
         session.activity=activity
         session.activity_received=received
         session.directory_probe_deadline=nil
         session.activity_generation=session.activity_generation+1
         for system_name,generation in pairs(session.self_activity) do
            if generation<session.activity_generation then
               session.self_activity[system_name]=nil
            end
         end
         if session.machine.system then
            refresh_discovered_time_controls(received)
         elseif session.skip_next_host_grace then
            session.skip_next_host_grace=
               no_other_players_discovered(session.departed_system)
         end
         naev.cache().multiplayer_activity={
            received=received,
            entries=activity,
         }
      end
      return
   end
   if message.system~=session.machine.system then return end
   local active_visit=message.node and session.machine.member_visits[message.node]
   if message.visit and session.visit_tombstones[message.node]==message.visit then
      return
   end
   if message.visit and active_visit and message.visit~=active_visit then
      local establishes_visit=message.type=="member_heartbeat"
         or message.type=="player_manifest" or message.type=="claim"
      if meta.node~=message.node or not establishes_visit then return end
      local old=session.players[message.node]
      if old then remove_pilot(old.pilot); session.players[message.node]=nil end
      owned.cleanup(session.craft,message.node,function(entry)
         remove_pilot(entry.pilot)
      end)
      clear_owner_lifecycle(session.craft_lifecycle_sequences,message.node)
      session.npc_target_interests[message.node]=nil
      session.pending_npc_manifests[message.node]=nil
      session.machine:remove_member(message.node)
      session.machine:reset_member_sequences(message.node)
      session.host_welcomed[message.node]=nil
      session.visit_tombstones[message.node]=nil
      active_visit=nil
   end
   -- An origin advertises its local listener, which is commonly 0.0.0.0 and
   -- is not a usable address on another machine. A directly connected peer
   -- gives us the observed address. Replace it before mesh forwarding so
   -- every member learns a reconnectable endpoint rather than relaying the
   -- origin's wildcard bind address.
   if meta.cap=="player" and meta.node==message.node and message.endpoint
         and endpoint_valid(session.peers[peer]) then
      message.endpoint=session.peers[peer]
   end
   local routed=false
   local routed_relayed=false
   if message.via then
      if not has_feature(meta,"mesh_control_v1") then return end
      local accepted,route_err=session.mesh:accept(message,meta.node)
      if accepted==false then return end
      if not accepted then
         trace("route_reject",{type=message.type,reason=route_err or "invalid"})
         return
      end
      routed=true
   end
   local legacy_relay=not routed and session.machine.state~="host"
      and meta.node==session.machine.host
   local owner_ok=routed or meta.node==message.node or legacy_relay
   if routed then
      local direct_establishes=meta.node==message.node and message.visit
         and (message.type=="member_heartbeat"
            or message.type=="player_manifest" or message.type=="claim")
      if not active_visit and not direct_establishes then
         local incumbent_introduction=meta.node==session.machine.host
            and message.type=="player_manifest" and message.visit
            and endpoint_valid(message.endpoint)
         if incumbent_introduction then
            -- The incumbent already verified this manifest on its direct
            -- connection to the origin. Admit the visit now so the manifest
            -- can create a proxy while a direct guest-to-guest route is being
            -- established in parallel.
            session.member_endpoints[message.node]=message.endpoint
            session.machine.topology:add_peer(message.endpoint)
            session.machine:observe_member(message.node,message.visit,nil,nil,now())
            active_visit=message.visit
            connect(message.endpoint,message.node)
         elseif (message.type=="member_heartbeat"
               or message.type=="player_manifest" or message.type=="claim")
               and endpoint_valid(message.endpoint) then
            session.member_endpoints[message.node]=message.endpoint
            session.machine.topology:add_peer(message.endpoint)
            connect(message.endpoint,message.node)
            relay_once(message,peer,true)
            return
         else
            return
         end
      end
      if active_visit then
         local reliable=message.type~="npc_state"
            and message.type~="npc_focus_state"
         relay_once(message,peer,reliable)
         routed_relayed=true
      end
   end
   if message.type=="member_heartbeat" then
      if not owner_ok then return end
      if not session.machine:accept_sequence(
            "heartbeat:"..message.node..":"..message.visit,message.seq) then
         return
      end
      session.machine:observe_member(message.node,message.visit,
         message.accepted_host,message.accepted_claim,now())
      if meta.node==message.node then
         local signature=message.links or ""
         if session.direct_link_signatures[message.node]~=signature then
            session.direct_link_signatures[message.node]=signature
            session.direct_links[message.node]=session.parse_direct_links(message.links)
            session.relay_topology_dirty=true
         end
      end
      if endpoint_valid(message.endpoint) then
         session.member_endpoints[message.node]=message.endpoint
         session.machine.topology:add_peer(message.endpoint)
      end
      local player_entry=session.players[message.node]
      if message.node~=session.settings.node_id
            and (not player_entry or not exists(player_entry.pilot)) then
         if meta.node==message.node then
            session.sequence=session.sequence+1
            local repair=base("resync")
            repair.seq=session.sequence
            repair.scope="all"
            repair.owner=message.node
            send(peer,repair,true)
         else
            request_resync("all",message.node)
         end
      end
      return
   elseif message.type=="host_query" then
      if not owner_ok then return end
      if not session.machine:accept_sequence(
            "host_query:"..message.node..":"..message.visit,message.seq) then
         return
      end
      session.machine:observe_member(message.node,message.visit,nil,nil,now())
      if session.machine.state=="host" then broadcast(claim_message(),true) end
      return
   end
   if message.type=="claim" then
      if session.locally_claimed then return end
      if not owner_ok then return end
      if meta.node==message.node and endpoint_valid(session.peers[peer]) then message.endpoint=session.peers[peer] end
      local old_state,old_host,old_claim=session.machine.state,
         session.machine.host,session.machine.claim
      local accepted=session.machine:accept_claim(message)
      local joined=accepted and (old_state~="guest"
         or old_host~=message.node
         or old_claim~=session.machine.claim)
      refresh_time_controls()
      session.machine.topology:remember_hint(message.system,message.node,message.endpoint,message.claim,now()+60)
      if joined then
         print("P2P: joined system host")
         join_host_population(old_state)
         request_resync("all")
      end
      if session.machine.state=="host" then broadcast(claim_message(),true) end
      return
   end
   if (message.type=="player_manifest" or message.type=="player_state" or message.type=="chat"
         or message.type=="player_control"
         or message.type=="npc_interest"
         or message.type=="craft_manifest" or message.type=="craft_state" or message.type=="craft_remove"
         or message.type=="craft_order" or message.type=="resync"
         or message.type=="leave") and not owner_ok then return end
   if owner_ok and message.node~=session.settings.node_id
         and (not message.visit
            or not session.machine.member_visits[message.node]
            or session.machine.member_visits[message.node]==message.visit) then
      session.machine:observe_member(message.node,message.visit,nil,nil,now())
   end
   if message.type~="resync" and message.owner and message.owner~=message.node then return end
   if message.type=="npc_interest" then
      if not owner_ok or not session.machine:accept_sequence(
            "npc_interest:"..message.node..":"..message.visit,message.seq) then
         return
      end
      if session.machine.state=="host" then
         remember_npc_interest(message.node,message.target,now())
         if message.target~="-" then
            publish_manifests("npc",nil,message.target,message.node)
         end
      end
      return
   end
   if message.type=="resync" then
      if message.node==session.settings.node_id
            or not session.machine:accept_sequence(table.concat({
               "resync",message.node,message.scope,message.owner or "",
               message.entity or "",
            },":"),message.seq) then return end
      if session.machine.state=="host" and not routed then
         broadcast_raw(message,true,peer)
      end
      -- Reuse the compatible "all" scope with an owner as a targeted player
      -- repair. Older peers safely answer it as a full resynchronization.
      local player_target=message.scope=="all" and message.owner
      if message.scope=="all"
            and (not player_target or player_target==session.settings.node_id) then
         publish_player(true)
      end
      if not player_target then
         publish_manifests(message.scope,message.owner,message.entity,message.node)
      end
      return
   end
   if message.type=="player_manifest" then
      if message.node==session.settings.node_id then return end
      local accepted
      if meta.node==message.node then
         local known_name=session.identities:raw_name(message.node)
         accepted=(known_name==nil and session.identities:add(message.node,message.name))
            or known_name==message.name
      else
         accepted=session.identities:add(message.node,message.name)
      end
      if not accepted then return end
      session.machine:observe_member(message.node,message.visit,nil,nil,now())
      session.relay_topology_dirty=true
      session.member_features[message.node]=message.features or session.member_features[message.node] or ""
      refresh_time_controls()
      if session.machine.state=="host" and session.peers[peer] then message.endpoint=session.peers[peer] end
      if endpoint_valid(message.endpoint) then
         session.member_endpoints[message.node]=message.endpoint
         session.machine.topology:add_peer(message.endpoint)
         if not connected_node(message.node) then connect(message.endpoint,message.node) end
      end
      spawn_proxy(message,session.identities:display_name(message.node))
      if session.machine.state=="host" then
         if meta.node==message.node and not session.host_welcomed[message.node] then
            -- Put the host manifest ahead of the private reliable chat so the
            -- recipient can anchor the communication to the host's proxy.
            publish_player(true)
            session.sequence=session.sequence+1
            local welcome=base("chat")
            welcome.seq=session.sequence
            welcome.text="This is "..player.name()..", captain of "..local_player_name()..". Identify yourself."
            if send(peer,welcome,true) then session.host_welcomed[message.node]=true end
         end
         if routed and not routed_relayed then
            relay_once(message,peer,true)
         elseif not routed then
            broadcast_raw(message,true,peer)
         end
      end
   elseif message.type=="player_control" then
      apply_player_control(message)
   elseif message.type=="player_state" then
      apply_player_state(message)
      if session.machine.state=="host" and not routed then
         session.relay_missing_player_paths(message,peer,false)
      end
   elseif message.type=="chat" and session.machine:accept_sequence("chat:"..message.node,message.seq) then
      local entry=session.players[message.node]
      if message.node~=session.settings.node_id
            and (not entry or not exists(entry.pilot)) then
         request_resync("all",message.node)
      end
      if message.node==session.settings.node_id then
         pilot.comm(display_text(local_player_name()),display_text(message.text))
      elseif entry and exists(entry.pilot) then
         entry.pilot:broadcast(display_text(message.text),true)
      else
         pilot.comm(session.identities:display_name(message.node) or message.node,
            display_text(message.text))
      end
      play_chat_sound()
      -- Arena echoes chat through the server to every client, including the
      -- sender. Do the same so a guest sees confirmation of its own message.
      if session.machine.state=="host" and not routed then broadcast_raw(message,true) end
   elseif message.type=="npc_manifest" and session.machine.state~="host"
         and (not message.recipient
            or message.recipient==session.settings.node_id)
         and message.node==session.machine.host and message.claim==session.machine.claim
         and accept_npc_snapshot(message) then
      spawn_npc_manifest(message)
   elseif message.type=="npc_done" and session.machine.state~="host"
         and (not message.recipient
            or message.recipient==session.settings.node_id)
         and message.node==session.machine.host and message.claim==session.machine.claim
         then
      finish_npc_snapshot(message)
   elseif message.type=="npc_control" and session.machine.state~="host"
         and (not message.recipient
            or message.recipient==session.settings.node_id)
         and message.node==session.machine.host and message.claim==session.machine.claim
         then
      apply_npc_control_batch(message)
   elseif message.type=="npc_add" and session.machine.state~="host"
         and (not message.recipient
            or message.recipient==session.settings.node_id)
         and message.node==session.machine.host and message.claim==session.machine.claim
         and accept_npc_snapshot(message) then
      note_population_event(message)
      local accepted=accept_lifecycle(session.npc_lifecycle_sequences,
         message.entity,message.baseline or message.seq)
      if (accepted and spawn_npc(message)) or not accepted then
         mark_npc_snapshot(message,message.entity)
         local current=session.receiving_npc_snapshot
         if current then complete_npc_snapshot(current) end
      end
   elseif message.type=="npc_remove"
         and (not message.recipient
            or message.recipient==session.settings.node_id)
         and message.node==session.machine.host
         and message.claim==session.machine.claim then
      note_population_event(message)
      if accept_lifecycle(session.npc_lifecycle_sequences,
            message.entity,message.seq) then
         remove_npc_replica(message.entity,
            message.reason=="absent" or message.reason=="death"
               or message.reason=="exploded")
      end
   elseif message.type=="npc_state" and message.node==session.machine.host
         and message.claim==session.machine.claim then
      parse_states(message.entities,session.npcs,nil,message.seq)
   elseif message.type=="npc_focus_state" and session.machine.state~="host"
         and message.node==session.machine.host
         and message.claim==session.machine.claim then
      parse_states(message.entities,session.npcs,nil,message.seq)
   elseif message.type=="craft_manifest" and message.owner~=session.settings.node_id then
      if accept_lifecycle(session.craft_lifecycle_sequences,
            message.entity,message.seq) then
         spawn_npc(message,message.owner)
      end
      if session.machine.state=="host" and not routed then
         broadcast_raw(message,true,peer)
      end
   elseif message.type=="craft_state"
         and message.owner~=session.settings.node_id then
      parse_states(message.entities,session.craft,message.owner,message.seq)
      if session.machine.state=="host" then
         session.relay_missing_player_paths(message,peer,false)
      end
   elseif message.type=="craft_remove" and message.owner~=session.settings.node_id
         and accept_lifecycle(session.craft_lifecycle_sequences,
            message.entity,message.seq) then
      local e=session.craft[message.entity]
      if e and e.owner==message.owner then
         remove_pilot(e.pilot)
         session.craft[message.entity]=nil
      end
      if session.machine.state=="host" and not routed then
         broadcast_raw(message,true,peer)
      end
   elseif message.type=="craft_order" and session.machine:accept_sequence("craft_order:"..message.owner,message.seq) then
      apply_craft_order(message)
      if session.machine.state=="host" and not routed then
         broadcast_raw(message,true,peer)
      end
   elseif message.type=="leave" then
      if message.visit and session.machine.member_visits[message.node]
            and message.visit~=session.machine.member_visits[message.node] then return end
      session.machine:remove_member(message.node)
      session.visit_tombstones[message.node]=message.visit
      session.direct_links[message.node]=nil
      session.direct_link_signatures[message.node]=nil
      session.relay_topology_dirty=true
      session.npc_target_interests[message.node]=nil
      session.pending_npc_manifests[message.node]=nil
      owned.cleanup(session.craft,message.node,function(entry) remove_pilot(entry.pilot) end)
      clear_owner_lifecycle(session.craft_lifecycle_sequences,message.node)
      remove_remote_player(message.node)
      if message.node==session.machine.host then handle_host_loss() end
      if session.machine.state=="host" and not routed then
         broadcast_raw(message,true,peer)
      end
      refresh_time_controls()
   end
end

remember_npc_interest = function ( node, target, stamp )
   if not target or target=="" or target=="-" then
      session.npc_target_interests[node]=nil
      return
   end
   if not session.npc_target_interest_enqueued[node] then
      session.npc_target_interest_enqueued[node]=true
      session.npc_target_interest_order[
         #session.npc_target_interest_order+1]=node
   end
   session.npc_target_interests[node]={
      entity=target,
      expires=stamp+NPC_TARGET_INTEREST_LEASE,
   }
end

local function publish_npc_interest ( target, stamp )
   if session.machine.state=="host" then
      remember_npc_interest(session.settings.node_id,target,stamp)
      return
   elseif session.machine.state~="guest" then
      session.local_npc_interest_target=nil
      return
   end
   target=target and session.npcs[target] and target or "-"
   stamp=stamp or now()
   if target==session.local_npc_interest_target
         and stamp-session.last_npc_interest<NPC_TARGET_INTEREST_REFRESH then
      return
   end
   session.local_npc_interest_target=target
   session.last_npc_interest=stamp
   session.local_npc_interest_seq=(session.local_npc_interest_seq or 0)+1
   local message=base("npc_interest")
   message.seq=session.local_npc_interest_seq
   message.target=target
   broadcast(message,true)
end

publish_player = function ( full )
   local p=player.pilot(); if not p or not session.machine.system then return end
   local state=local_state(p)
   publish_npc_interest(state.target,now())
   local control_signature=table.concat({
      state.target~="" and state.target or "-",state.primary,state.secondary
   },":")
   if control_signature~=session.local_control_signature then
      publish_player_control(false)
   end
   if full then
      local current_ship=p:ship()
      local msg=base("player_manifest")
      msg.entity=session.settings.node_id
      msg.ship=current_ship:nameRaw()
      msg.name=local_player_name()
      msg.features=session.player_features
      msg.outfits=outfit_names(p)
      msg.slots=outfit_slots(p)
      msg.weapsets=weapon_sets(p)
      local fallbacks=ship_fallback_names(current_ship)
      if fallbacks~="" then msg.ship_fallbacks=fallbacks end
      msg.endpoint=session.endpoint
      msg.x=state.x; msg.y=state.y; msg.vx=state.vx; msg.vy=state.vy; msg.dir=state.dir
      msg.armour=state.armour; msg.shield=state.shield; msg.stress=state.stress
      broadcast(msg,true)
   end
   session.sequence=session.sequence+1
   local msg=base("player_state"); msg.entity=session.settings.node_id; msg.seq=session.sequence
   for k,v in pairs(state) do msg[k]=v end
   msg.control_seq=session.local_control_seq or 0
   broadcast(msg,false)
end

local function greet_host ()
   if not session.machine or session.machine.state~="guest" or not session.machine.system
         or session.greeted_system==session.machine.system then return end
   for peer,meta in pairs(session.peer_meta) do
      if meta.verified and meta.cap=="player" and meta.node==session.machine.host then
         -- Reliable packets on the same channel preserve ordering. Give the
         -- host our proxy manifest before it receives and displays the chat.
         publish_player(true)
         session.sequence=session.sequence+1
         local msg=base("chat")
         msg.seq=session.sequence
         msg.text="I am "..player.name()..", captain of "..local_player_name().."!"
         session.machine:accept_sequence("chat:"..session.settings.node_id,msg.seq)
         pilot.comm(display_text(local_player_name()),display_text(msg.text))
         play_chat_sound()
         broadcast(msg,true)
         session.greeted_system=session.machine.system
         return
      end
   end
end

local function publish_state_batches ( kind, lines, owner )
   local batch,size={},0
   local function flush ()
      if #batch==0 then return end
      session.sequence=session.sequence+1
      local msg=base(kind); msg.seq=session.sequence; msg.entities=table.concat(batch,";")
      if kind=="npc_state" or kind=="npc_focus_state" then
         msg.claim=session.machine.claim
      else
         msg.owner=owner
      end
      broadcast(msg,false); batch={}; size=0
   end
   for _index,line in ipairs(lines) do
      if size+#line+1>12000 then flush() end
      batch[#batch+1]=line; size=size+#line+1
   end
   flush()
end

local function publish_focus_states ( ambient, target_entities, stamp )
   local order=session.npc_target_interest_order
   local order_count=#order
   if order_count==0 then return end
   local start=math.max(1,math.min(session.npc_target_interest_cursor,order_count))
   local inspected=0
   local selected={}
   local lines={}
   while inspected<order_count and inspected<NPC_INTERESTS_PER_TICK
         and #lines<NPC_TARGETS_PER_TICK do
      local index=(start+inspected-1)%order_count+1
      local node=order[index]
      local interest=session.npc_target_interests[node]
      local participant=node==session.settings.node_id
         or session.machine.members[node]
      if not interest or not participant
            or stamp>=interest.expires then
         session.npc_target_interests[node]=nil
      else
         local p=ambient[interest.entity]
         if exists(p) and not selected[interest.entity] then
            selected[interest.entity]=true
            lines[#lines+1]=state_line(
               craft_state_record(p,interest.entity,target_entities))
         end
      end
      inspected=inspected+1
   end
   session.npc_target_interest_cursor=(start+inspected-1)%order_count+1
   publish_state_batches("npc_focus_state",lines)
end

function session.publish_focus_entities ( stamp )
   -- The membership publisher owns inventory refreshes and their add/remove
   -- edge. Focus updates only consume the last completed snapshot; otherwise a
   -- faster focus tick could hide a refresh from the authoritative diff.
   local snapshot=session.inventory_snapshot
   if not snapshot then return end
   publish_focus_states(snapshot.ambient,snapshot.target_entities,stamp)
end

local function publish_ambient_states ( ambient, target_entities )
   local selected,selected_set={},{}
   local ring=session.npc_round_robin
   local ring_count=#ring
   local inspected,round_robin_added=0,0
   while inspected<ring_count
         and round_robin_added<NPC_ROUND_ROBIN_PER_TICK do
      if session.npc_round_robin_at>ring_count then session.npc_round_robin_at=1 end
      local entity=ring[session.npc_round_robin_at]
      session.npc_round_robin_at=session.npc_round_robin_at+1
      inspected=inspected+1
      if not selected_set[entity] then
         local p=ambient[entity]
         if exists(p) then
            selected[#selected+1]={entity=entity,pilot=p}
            selected_set[entity]=true
            round_robin_added=round_robin_added+1
         end
      end
   end

   local lines,controls={},{}
   for _index,entry in ipairs(selected) do
      local rec=craft_state_record(entry.pilot,entry.entity,target_entities)
      lines[#lines+1]=state_line(rec)
      -- Control discovery shares the same hard entity budget as state. It may
      -- never turn into a second population scan.
      local task,goal=task_goal(entry.pilot,rec.target)
      local control={
         entity=entry.entity,ai=entry.pilot:ainame() or "",task=task,goal=goal,
      }
      local signature=table.concat({control.ai,control.task,control.goal},"\n")
      if session.host_npc_controls[entry.entity]~=signature then
         session.host_npc_controls[entry.entity]=signature
         controls[#controls+1]=control_line(control)
      end
   end
   publish_state_batches("npc_state",lines)
   local batch,size={},0
   local function flush_controls ()
      if #batch==0 then return end
      session.sequence=session.sequence+1
      local message=base("npc_control")
      message.claim=session.machine.claim
      message.seq=session.sequence
      message.entities=table.concat(batch,";")
      broadcast(message,true)
      batch={}; size=0
   end
   for _index,line in ipairs(controls) do
      if #batch>0 and size+#line+1>NPC_MANIFEST_BATCH_PAYLOAD then
         flush_controls()
      end
      batch[#batch+1]=line
      size=size+#line+1
   end
   flush_controls()
end

local function next_host_population ()
   session.host_npc_population=(session.host_npc_population or 0)+1
   return session.host_npc_population
end

local function publish_pending_entity_removals ()
   local published=0
   for entity,removal in pairs(session.pending_entity_removals) do
      session.pending_entity_removals[entity]=nil
      local kind=removal.kind
      if kind=="npc" and session.machine.state=="host" then
         session.sequence=session.sequence+1
         local message=base("npc_remove")
         message.claim=session.machine.claim
         message.entity=entity
         message.seq=session.sequence
         message.reason=removal.reason
         message.population=next_host_population()
         broadcast(message,true)
      elseif kind=="craft" then
         session.sequence=session.sequence+1
         local message=base("craft_remove")
         message.owner=session.settings.node_id
         message.entity=entity
         message.seq=session.sequence
         broadcast(message,true)
      end
      published=published+1
      if published>=ENTITY_REMOVALS_PER_FRAME then break end
   end
end

publish_entities = function ( full, include_ambient, include_craft )
   include_ambient=include_ambient~=false
   include_craft=include_craft~=false
   local stamp=now()
   local ambient,craft,target_entities,inventory_refreshed=
      cached_inventory(stamp,full)
   if include_ambient and session.machine.state=="host" then
      if inventory_refreshed or full then
         for id,p in pairs(ambient) do
            local previous=session.host_inventory[id]
            if not full and previous~=p and exists(p) then
               session.host_npc_controls[id]=nil
               local rec=manifest_record(p,id,true)
               local message=add_message(rec,"npc_add")
               message.population=next_host_population()
               broadcast(message,true)
            end
         end
         for id in pairs(session.host_inventory) do
            if not ambient[id] then
               session.host_npc_controls[id]=nil
               session.sequence=session.sequence+1
               local msg=base("npc_remove")
               msg.claim=session.machine.claim
               msg.entity=id
               msg.seq=session.sequence
               msg.population=next_host_population()
               broadcast(msg,true)
            end
         end
         session.host_inventory=ambient
      end
      if full then
         for node in pairs(session.machine.members) do
            if node~=session.settings.node_id then
               queue_npc_manifests(ambient,node)
            end
         end
      end
      publish_ambient_states(ambient,target_entities,stamp)
   end
   if include_craft then
      for id,p in pairs(craft) do
         if (full or not session.owned_inventory[id]) and exists(p) then
            broadcast(add_message(manifest_record(p,id),"craft_manifest",session.settings.node_id),true)
         end
      end
      for id in pairs(session.owned_inventory) do
         if not craft[id] then
            session.sequence=session.sequence+1
            local msg=base("craft_remove"); msg.owner=session.settings.node_id; msg.entity=id; msg.seq=session.sequence
            broadcast(msg,true)
         end
      end
      session.owned_inventory=craft
      local lines={}
      for id,p in pairs(craft) do
         if exists(p) then
            lines[#lines+1]=state_line(craft_state_record(p,id,target_entities))
         end
      end
      publish_state_batches("craft_state",lines,session.settings.node_id)
   end
end

publish_manifests = function ( scope, owner, entity, recipient )
   local include_ambient=scope=="all" or scope=="npc"
   local include_craft=(scope=="all" or scope=="craft")
      and (not owner or owner==session.settings.node_id)
   if entity then
      local p
      local kind
      if include_ambient and session.machine.state=="host" then
         p=session.host_inventory[entity]
         kind="npc_add"
      end
      if not p and include_craft then
         p=session.owned_inventory[entity]
         kind="craft_manifest"
      end
      if p and exists(p) then
         local message=add_message(manifest_record(p,entity,kind=="npc_add"),kind,
            kind=="craft_manifest" and session.settings.node_id or nil)
         if kind=="npc_add" then message.recipient=recipient end
         broadcast(message,true)
         return
      end
      if scope=="npc" and session.machine.state=="host" then
         session.sequence=session.sequence+1
         local message=base("npc_remove")
         message.claim=session.machine.claim
         message.entity=entity
         message.seq=session.sequence
         message.recipient=recipient
         message.reason="absent"
         broadcast(message,true)
         return
      end
      -- A request may race the one-second membership pass. Do not turn that
      -- race into an unbounded pilot.get() scan; the next membership pass will
      -- publish the new entity reliably.
   end
   local ambient=session.host_inventory
   local craft=session.owned_inventory
   if include_ambient and session.machine.state=="host" then
      if entity then
         local p=ambient[entity]
         if p then
            local message=add_message(manifest_record(p,entity,true),"npc_add")
            message.recipient=recipient
            broadcast(message,true)
         end
      else
         queue_npc_manifests(ambient,recipient)
      end
   end
   if include_craft then
      for id,p in pairs(craft) do
         if not entity or id==entity then
            broadcast(add_message(manifest_record(p,id),"craft_manifest",session.settings.node_id),true)
         end
      end
   end
end

request_resync = function ( scope, owner, entity )
   if not session.machine or not session.machine.system then return end
   local key=table.concat({scope or "",owner or "",entity or ""},"|")
   local stamp=now()
   if scope=="all" then session.initial_sync_until=stamp+3 end
   if stamp-(session.resync_sent[key] or -math.huge)<1 then return end
   session.resync_sent[key]=stamp
   session.sequence=session.sequence+1
   local msg=base("resync")
   msg.seq=session.sequence
   msg.scope=scope
   msg.owner=owner
   msg.entity=entity
   broadcast(msg,true)
end

function session.start ( settings )
   if session.running then return true end
   clear_local_controls()
   session.local_speed2=nil
   session.indicators:clear()
   session.settings=session.defaults(settings)
   local ok,host=pcall(enet.host_create,"*:"..tostring(session.settings.listen_port))
   if not ok then return nil,"unable to create P2P host: "..tostring(host) end
   if not host then return nil,"unable to create P2P host" end
   session.host=host; session.running=true; session.machine=core.new(session.settings.node_id,now); session.machine:start()
   session.identities=identity.new(session.settings.node_id,local_player_name())
   session.member_endpoints={}; session.craft_factions={}; session.departures={}; session.host_welcomed={}
   session.pending_leader_owners={}; session.resync_sent={}; session.ownership_cache={}
   session.pending_npc_leaders=nil
   session.host_inventory={}; session.owned_inventory={}
   session.host_npc_controls={}
   session.pending_npc_controls={}
   session.pending_npc_control_entities={}
   session.npc_lifecycle_sequences={}
   session.craft_lifecycle_sequences={}
   session.pending_fighter_bays={}
   session.pending_entity_removals={}
   session.host_npc_population=0
   session.guest_npc_population=nil
   session.npc_population_events={}
   session.replica_entity_ids={}
   session.npc_replica_order={}; session.npc_replica_enqueued={}
   session.npc_snapshot=0
   session.authoritative_entities={}
   session.authoritative_pilots={}
   session.mesh=Mesh.new(session.settings.node_id,now)
   session.member_features={}
   session.player_peers={}
   session.direct_links={}
   session.direct_link_signatures={}
   session.relay_targets={}
   session.relay_topology_dirty=true
   session.local_control_seq=0
   session.local_control_signature=nil
   session.local_weapset=1
   session.ambient_spawning=true
   session.heartbeat_seq=0
   session.last_heartbeat=-math.huge
   session.inventory_snapshot=nil; session.last_inventory=-math.huge
   session.npc_round_robin={}; session.npc_round_robin_at=1
   session.npc_target_interests={}
   session.npc_target_interest_order={}; session.npc_target_interest_cursor=1
   session.npc_target_interest_enqueued={}
   session.local_npc_interest_seq=0
   session.local_npc_interest_target=nil; session.last_npc_interest=-math.huge
   session.pending_npc_manifests={}
   session.pending_npc_manifest_order={}; session.pending_npc_manifest_cursor=1
   session.pending_npc_manifest_enqueued={}
   session.last_npc_manifest_batch=-math.huge
   session.last_npc_focus=-math.huge
   session.receiving_npc_snapshot=nil
   session.visit_tombstones={}
   session.local_objects={}
   session.local_object_pilots={}
   session.pending_object_requests={}
   session.pending_object_deletes={}
   session.known_objects_by_system={}
   session.object_subscription_system=nil
   session.object_confirmed_system=nil
   session.object_confirmed_at=-math.huge
   session.object_request=0
   session.last_object_retry=0
   session.object_client=nil
   session.activity={}
   session.activity_received=0
   session.activity_generation=0
   session.self_activity={}
   session.last_activity_query=0
   session.directory_probe_deadline=nil
   session.initial_sync_until=0
   session.solo_since=nil
   session.realtime_clock_pinned=nil
   session.skip_host_grace=nil
   session.skip_next_host_grace=nil
   session.departed_system=nil
   session.last_liveness=now()
   session.last_claim_check=0
   session.endpoint=tostring(host:get_socket_address())
   start_object_client()
   publish_object_capability()
   print("P2P: listener started")
   session.machine.topology:load_peers(session.settings.recent)
   connect_known_peers()
   session.last_seed_connect=now()
   return true
end

function session.stop ()
   clear_local_controls()
   session.local_speed2=nil
   if not session.running then
      session.indicators:clear()
      lock_autonav(false)
      naev.cache().multiplayer_p2p_objects=false
      return
   end
   if session.machine.system then broadcast(base("leave"),true) end
   session.leave()
   if session.object_client then session.object_client:stop() end
   for peer in pairs(session.peers) do peer:disconnect_now() end
   session.settings.recent=session.machine.topology:serialize_peers()
   session.machine:stop(); session.host=nil; session.object_client=nil
   session.running=false; session.peers={}; session.endpoints={}; session.peer_meta={}; session.identities=nil
   publish_object_capability()
end

function session.enter ( system_name )
   if not session.running then return nil,"not running" end
   -- Naev can run both takeoff and enter hooks for one transition. Do not
   -- restart discovery, discard peers, or rebuild the population when the
   -- player is already in this system.
   if session.machine.system==system_name then
      refresh_time_controls()
      return true
   end
   session.leave()
   local skip_host_grace=session.skip_next_host_grace==true
      and session.departed_system~=system_name
   session.skip_next_host_grace=nil
   session.departed_system=nil
   session.visit_generation=(session.visit_generation or 0)+1
   session.visit=random_id()..string.format("%x",session.visit_generation)
   session.mesh:reset()
   session.machine:enter(system_name,session.visit)
   session.object_subscription_system=system_name
   session.object_confirmed_system=nil
   session.object_confirmed_at=-math.huge
   session.skip_host_grace=skip_host_grace
   session.locally_claimed=locally_claimed()
   session.last_claim_check=now()
   session.last_liveness=now()
   session.solo_since=nil
   session.realtime_clock_pinned=nil
   session.local_speed2=nil
   reset_smoothing()
   session.greeted_system=nil
   if session.locally_claimed then
      set_ambient_spawning(true)
   else
      -- No peer is allowed to contribute a speculative ambient population
      -- while authority is undecided. The elected initial host enables Naev's
      -- scheduler; followers reconstruct only the authority's population.
      remove_guest_population()
   end
   spawn_known_objects(system_name)
   lock_autonav(not skip_host_grace)
   connect_known_peers(); session.last_seed_connect=now()
   -- The directory transport normally predates takeoff. Its hello handler
   -- therefore cannot subscribe a landed client to a system that did not
   -- exist yet. Subscribe on every visit so simultaneous arrivals are
   -- introduced after either peer publishes its claim.
   query_rendezvous()
   print("P2P: discovering system host")
   session.sequence=session.sequence+1
   local query=base("host_query"); query.seq=session.sequence
   broadcast(query,true)
   ensure_object_subscription()
   publish_player(true)
   return true
end

function session.leave ()
   clear_local_controls()
   session.local_control_signature=nil
   if not session.machine or not session.machine.system then
      session.local_speed2=nil
      session.indicators:clear()
      lock_autonav(false)
      return
   end
   local current_system=session.machine.system
   session.object_subscription_system=nil
   session.object_confirmed_system=nil
   session.object_confirmed_at=-math.huge
   clear_local_objects()
   for request,pending in pairs(session.pending_object_requests) do
      if pending.action=="query" then session.pending_object_requests[request]=nil end
   end
   session.skip_next_host_grace=session.machine.state=="host"
      and no_other_players_discovered(current_system)
   if session.machine.state=="host" then
      for _index,entry in ipairs(session.activity) do
         if entry.active and entry.system==current_system then
            session.self_activity[current_system]=session.activity_generation
            break
         end
      end
   end
   session.departed_system=current_system
   broadcast(base("leave"),true)
   -- A gameplay peer is only a path for the system visit that established it.
   -- Landing and jumping must not carry a half-open UDP association into the
   -- the next host election. Directory transports remain available to
   -- rendezvous a fresh path, while remembered player endpoints are retried by
   -- enter() below.
   disconnect_player_transports()
   session.player_peers={}
   session.direct_links={}
   session.direct_link_signatures={}
   session.relay_targets={}
   session.relay_topology_dirty=true
   for _entity_id,entry in pairs(session.players) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.npcs) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.craft) do remove_pilot(entry.pilot) end
   for node in pairs(session.departures) do clear_departure(node,false) end
   session.players={}; session.npcs={}; session.craft={}
   session.departures={}
   session.craft_factions={}; session.host_welcomed={}
   session.pending_leader_owners={}; session.resync_sent={}; session.ownership_cache={}
   session.pending_npc_leaders=nil
   session.host_inventory={}; session.owned_inventory={}
   session.host_npc_controls={}
   session.pending_npc_controls={}
   session.pending_npc_control_entities={}
   session.npc_lifecycle_sequences={}
   session.craft_lifecycle_sequences={}
   session.pending_fighter_bays={}
   session.pending_entity_removals={}
   session.host_npc_population=0
   session.guest_npc_population=nil
   session.npc_population_events={}
   session.replica_entity_ids={}
   session.npc_replica_order={}; session.npc_replica_enqueued={}
   session.authoritative_entities={}
   session.authoritative_pilots={}
   session.inventory_snapshot=nil; session.last_inventory=-math.huge
   session.npc_round_robin={}; session.npc_round_robin_at=1
   session.npc_target_interests={}
   session.npc_target_interest_order={}; session.npc_target_interest_cursor=1
   session.npc_target_interest_enqueued={}
   session.local_npc_interest_seq=0
   session.local_npc_interest_target=nil; session.last_npc_interest=-math.huge
   session.pending_npc_manifests={}
   session.pending_npc_manifest_order={}; session.pending_npc_manifest_cursor=1
   session.pending_npc_manifest_enqueued={}
   session.last_npc_manifest_batch=-math.huge
   session.last_npc_focus=-math.huge
   session.receiving_npc_snapshot=nil
   session.initial_sync_until=0
   session.solo_since=nil
   session.realtime_clock_pinned=nil
   session.local_speed2=nil
   session.indicators:clear()
   reset_smoothing()
   session.greeted_system=nil
   session.locally_claimed=nil
   set_ambient_spawning(true); session.machine:leave(); session.visit=nil
   session.mesh:reset(); lock_autonav(false)
end

function session.create_message_buoy ( text, slot )
   if not session.running or not session.machine or not session.machine.system
         or player.isLanded() then
      return nil,_("Message buoys can only be deployed during P2P spaceflight.")
   end
   if type(text)~="string" then return nil,_("Invalid message.") end
   text=text:match("^%s*(.-)%s*$")
   if text=="" or #text>96 or text:find("[%z\1-\31\127]") then
      return nil,_("Enter a message without control characters.")
   end
   slot=tonumber(slot)
   local current=slot and player.pilot():outfitSlot(slot) or nil
   if not current or current:nameRaw()~="Message Buoy" then
      return nil,_("The fitted message buoy could not be found.")
   end
   local peer=object_directory_peer()
   if not peer then return nil,_("The configured directory does not support persistent objects.") end
   for _request,pending in pairs(session.pending_object_requests) do
      if (pending.action=="create" or pending.action=="create_reconcile"
            or pending.action=="create_wait_delete")
            and pending.system==session.machine.system then
         return nil,_("A message buoy deployment is already in progress.")
      end
   end
   local object_id=session.settings.node_id.."_"..random_id()
   local x,y=player.pilot():pos():get()
   local object={
      id=object_id,kind="message_buoy",owner=session.settings.node_id,
      created=math.max(0,math.floor(now())),revision=1,
      data={text=text,captain=player.name()},
      endpoints={{
         id=object_id.."_physical",
         system=session.machine.system,x=x,y=y,dir=player.pilot():dir(),
         role="physical",visible=true,
      }},
   }
   local packed,err=Object.encode(object)
   if not packed then return nil,tostring(err) end
   local request=next_object_request()
   local waiting=has_pending_object_delete(session.machine.system)
   session.pending_object_requests[request]={
      action=waiting and "create_wait_delete" or "create",
      object_id=object_id,slot=slot,system=session.machine.system,
      object=object,packed=packed,
      deadline=now()+(waiting and OBJECT_RECONCILE_TIMEOUT
         or OBJECT_REQUEST_TIMEOUT),
   }
   if waiting then
      player.msg(_("Waiting for the destroyed message buoy to be removed…"))
   elseif not send_object_create(peer,request,session.pending_object_requests[request]) then
      session.pending_object_requests[request]=nil
      return nil,_("The message buoy directory is unavailable.")
   end
   return true
end

function session.message_buoy_destroyed ( object_id, destroyed_pilot )
   local entry=session.local_objects[object_id]
   if not entry or entry.removing
         or (destroyed_pilot and entry.pilot~=destroyed_pilot) then return false end
   if entry.hook then hook.rm(entry.hook) end
   if entry.local_id then session.local_object_pilots[entry.local_id]=nil end
   session.local_objects[object_id]=nil
   forget_object(object_id)
   local endpoint=message_buoy_endpoint(entry.object)
   session.pending_object_deletes[object_id]={
      sent=false,system=endpoint and endpoint.system,
   }
   send_pending_object_deletes(object_directory_peer())
   return true
end

function session.send_chat ( text )
   if not session.running or not session.machine.system or type(text)~="string" or text=="" then return nil end
   session.sequence=session.sequence+1
   local msg=base("chat"); msg.seq=session.sequence; msg.text=text:sub(1,1024)
   -- Display immediately. If a host relays the message back, the accepted
   -- sequence makes that echo a no-op instead of showing it twice.
   session.machine:accept_sequence("chat:"..session.settings.node_id,msg.seq)
   pilot.comm(display_text(local_player_name()),display_text(msg.text))
   play_chat_sound()
   broadcast(msg,true)
   return true
end

function session.request_activity ()
   if not session.running then return false end
   local sent=false
   for peer,meta in pairs(session.peer_meta) do
      if meta.verified and meta.cap=="directory" and has_feature(meta,"activity") then
         sent=send(peer,{type="activity_query",node=session.settings.node_id},true)
            or sent
      end
   end
   session.last_activity_query=now()
   if sent then
      session.directory_probe_deadline=
         session.last_activity_query+DIRECTORY_RESPONSE_TIMEOUT
   end
   return sent
end

function session.recent_activity ()
   local stamp=now()
   local activity={}
   local snapshot_fresh=stamp-(session.activity_received or 0)
      <=2*ACTIVITY_QUERY_INTERVAL
   for _index,entry in ipairs(session.activity or {}) do
      local age=math.max(0,math.floor(stamp-entry.seen))
      if age<=ACTIVITY_RETENTION then
         activity[#activity+1]={system=entry.system,
            active=entry.active and snapshot_fresh,age=age}
      end
   end
   return activity
end

function session.input ( input_name, input_pressed )
   if not session.running then return end
   -- Arena multiplayer unpauses on every input event. P2P must keep pumping
   -- networking and the authoritative NPC simulation while a menu is open
   -- too, but a solo host must retain ordinary single-player pausing.
   session.keep_simulation_live()
   local selected=input_name:match("^weapset([0-9])$")
   if selected then
      if input_pressed then
         session.local_weapset=tonumber(selected)
         if session.local_weapset==0 then session.local_weapset=10 end
         publish_player_control(false)
      end
      return
   end
   if input_pressed and (input_name=="e_attack" or input_name=="e_hold"
         or input_name=="e_return" or input_name=="e_clear") then
      session.sequence=session.sequence+1
      local msg=base("craft_order")
      msg.owner=session.settings.node_id; msg.seq=session.sequence; msg.order=input_name
      if input_name=="e_attack" then
         local target=player.pilot():target()
         msg.target=target_entity(target)
         if msg.target=="" then return end
         for node,entry in pairs(session.players) do
            if entry.pilot==target then mark_player_aggression(node); break end
         end
      end
      broadcast(msg,true)
      return
   end
   local key
   if input_name=="accel" then key="accel"
   elseif input_name=="primary" then key="primary"
   elseif input_name=="secondary" then key="secondary"
   else return end
   if input_pressed and (key=="primary" or key=="secondary") then
      local target=player.pilot():target()
      for node,entry in pairs(session.players) do
         if entry.pilot==target then
            mark_player_aggression(node)
            break
         end
      end
   end
   naev.cache()[key]=input_pressed and 1 or 0
   if key=="primary" or key=="secondary" then publish_player_control(false) end
end

function session.enforce_time_controls ()
   -- Naev's ship time_mod changes the global simulation dt, while each
   -- pilot's time_speedup remains its own action-speed balance modifier.
   -- Multiplayer must share the former without flattening the latter.
   if not session.autonav_locked then return end
   local current=player.dt_mod()
   if not session.locked_dt_mod
         or math.abs(current-session.locked_dt_mod)>1e-6 then
      player.autonavSetSpeed(1)
      session.locked_dt_mod=player.dt_mod()
   end
end

function session.update ( dt )
   if not session.running then return end
   local stamp=now()
   session.indicators:update(stamp)
   if session.machine.system
         and stamp-(session.last_claim_check or 0)>=1 then
      session.last_claim_check=stamp
      session.locally_claimed=locally_claimed()
      if session.locally_claimed and session.machine.state=="guest" then
         local system_name=session.machine.system
         print("P2P: local system claim requires hosting")
         session.leave()
         session.enter(system_name)
      end
   end
   -- Autonav can be entered through map and scripted paths that bypass the
   -- disabled speed input. Keep it usable without allowing time compression.
   session.enforce_time_controls()
   local processed=0
   local event=session.host:service(0)
   while event do
      processed=processed+1
      if event.type=="connect" then
         if not session.peers[event.peer] then
            session.peers[event.peer]=tostring(event.peer)
            session.peer_meta[event.peer]={
               verified=false,outbound=false,connected_at=stamp,
            }
         end
         hello(event.peer)
      elseif event.type=="receive" then
         local message,err=codec.decode(event.data)
         if message then
            local receive_meta=session.peer_meta[event.peer]
            if receive_meta then receive_meta.last_receive=stamp end
            on_message(event.peer,message)
         else
            print("P2P: rejected packet: "..tostring(err))
            reject_peer(event.peer,"malformed packet",true)
         end
      elseif event.type=="disconnect" then
         local endpoint=session.peers[event.peer]
         local meta=session.peer_meta[event.peer]
         if meta and meta.node and session.player_peers[meta.node]==event.peer then
            session.player_peers[meta.node]=nil
            session.relay_topology_dirty=true
         end
         session.peers[event.peer]=nil
         session.peer_meta[event.peer]=nil
         if endpoint then session.endpoints[endpoint]=nil end
      end
      if processed>=MAX_EVENTS_PER_FRAME then break end
      event=session.host:service(0)
   end
   service_npc_snapshot_prune()
   for owner in pairs(session.pending_leader_owners) do
      reconcile_craft_leaders(owner)
      session.pending_leader_owners[owner]=nil
   end
   if session.pending_npc_leaders then
      reconcile_npc_leaders()
      session.pending_npc_leaders=nil
   end
   -- toggleSpawn(false) only closes Naev's ambient scheduler. Missions and
   -- events can still add pilots directly, so non-authorities prune anything
   -- outside the replica, owned-craft, and persistent-object sets at the same
   -- bounded one-second cadence as the normal inventory diff.
   if session.machine.system and session.machine.state~="host"
         and not session.locally_claimed
         and stamp-(session.last_inventory or -math.huge)>=INVENTORY_INTERVAL then
      cached_inventory(stamp,false)
   end
   greet_host()
   if stamp-(session.last_liveness or 0)>=1 then
      session.last_liveness=stamp
      if session.machine.state=="host" and not session.locally_claimed
            and has_remote_member() and session.last_heartbeat>-math.huge
            and stamp-session.last_heartbeat>core.HOST_LEASE then
         session.machine:host_stale()
         trace("host_pause_recovery",{gap=stamp-session.last_heartbeat})
      end
      local stale_peers={}
      for peer,meta in pairs(session.peer_meta) do
         if not meta.verified
               and stamp-(meta.connected_at or stamp)>=HANDSHAKE_TIMEOUT then
            stale_peers[#stale_peers+1]=peer
         elseif meta.verified and meta.cap=="player"
               and stamp-(meta.last_receive or stamp)>=TRANSPORT_IDLE_TIMEOUT then
            stale_peers[#stale_peers+1]=peer
         elseif session.directory_probe_deadline
               and stamp>=session.directory_probe_deadline
               and meta.verified and meta.cap=="directory"
               and has_feature(meta,"activity") then
            stale_peers[#stale_peers+1]=peer
         end
      end
      if session.directory_probe_deadline
            and stamp>=session.directory_probe_deadline then
         session.directory_probe_deadline=nil
      end
      for _index,peer in ipairs(stale_peers) do
         reject_peer(peer,"application liveness timeout",true)
      end
      for entity in pairs(session.pending_npc_control_entities) do
         local entry=session.npcs[entity]
         if entry and exists(entry.pilot) and entry.pending_control then
            apply_npc_control(entry,entry.pending_control)
         end
         if not entry or not entry.pending_control then
            session.pending_npc_control_entities[entity]=nil
         end
      end
      local receiving=session.receiving_npc_snapshot
      if receiving and not receiving.pruning and stamp>=receiving.deadline then
         session.receiving_npc_snapshot=nil
         request_resync("npc")
      end
      for node,entry in pairs(session.departures) do
         if not exists(entry.pilot) then session.departures[node]=nil end
      end
      local stale_nodes={}
      local aggression_deadline
      for node,entry in pairs(session.players) do
         if entry.last_aggression and stamp-entry.last_aggression>=AGGRESSION_GRACE then
            if exists(entry.pilot) then entry.pilot:setHostile(false) end
            entry.last_aggression=nil
            entry.p2p_hostile=nil
            -- Fighter hostility is set only by explicit owner attack orders;
            -- clearing it here is a rare timer transition, not per-frame work.
            for _entity_id,craft in pairs(session.craft) do
               if craft.owner==node and exists(craft.pilot) then
                  craft.pilot:setHostile(false)
               end
            end
         end
         local member_seen=session.machine.member_seen[node]
         local stale=not exists(entry.pilot) or not member_seen
            or stamp-member_seen>core.MEMBER_LEASE
         if stale then
            stale_nodes[#stale_nodes+1]=node
         elseif entry.last_aggression then
            aggression_deadline=math.max(aggression_deadline or 0,
               entry.last_aggression+AGGRESSION_GRACE)
         end
      end
      session.indicators:reconcile_aggression(aggression_deadline,stamp)
      for _index,node in ipairs(stale_nodes) do
         disconnect_node_transports(node)
         session.machine:remove_member(node)
         session.direct_links[node]=nil
         session.direct_link_signatures[node]=nil
         session.relay_topology_dirty=true
         session.npc_target_interests[node]=nil
         session.pending_npc_manifests[node]=nil
         owned.cleanup(session.craft,node,function(entry) remove_pilot(entry.pilot) end)
         clear_owner_lifecycle(session.craft_lifecycle_sequences,node)
         session.identities:remove(node)
         remove_remote_player(node)
         if node==session.machine.host then handle_host_loss() end
      end
      for entity,entry in pairs(session.npcs) do
         if not exists(entry.pilot) then
            session.npcs[entity]=nil
            request_resync("npc",nil,entity)
         end
      end
      for entity,entry in pairs(session.craft) do
         if not exists(entry.pilot) then
            session.craft[entity]=nil
            request_resync("craft",entry.owner,entity)
         end
      end
      refresh_time_controls(stamp)
   end
   smooth_replicas(dt,stamp)
   if session.machine.system and stamp-(session.last_heartbeat or -math.huge)>=1 then
      session.last_heartbeat=stamp
      session.heartbeat_seq=(session.heartbeat_seq or 0)+1
      local heartbeat=base("member_heartbeat")
      heartbeat.seq=session.heartbeat_seq
      heartbeat.endpoint=session.endpoint
      heartbeat.links=session.local_direct_links()
      heartbeat.accepted_host=session.machine.host
      heartbeat.accepted_claim=session.machine.claim
      session.machine:observe_member(session.settings.node_id,session.visit,
         heartbeat.accepted_host,heartbeat.accepted_claim,stamp)
      broadcast(heartbeat,true)
   end
   local was_host=session.machine.state=="host"
   local action=session.machine:tick()
   if stamp-(session.last_activity_query or 0)>=ACTIVITY_QUERY_INTERVAL then
      session.request_activity()
   end
   if stamp-(session.last_seed_connect or 0)>=5 then
      connect_configured()
      query_rendezvous()
      for node,endpoint in pairs(session.member_endpoints) do
         if node~=session.settings.node_id and not connected_node(node)
               and endpoint_valid(endpoint) then connect(endpoint,node) end
      end
      session.last_seed_connect=stamp
   end
   if action=="claim" then
      session.relay_topology_dirty=true
      if not was_host then promote_guest_population() end
      print(fmt.f("P2P: claimed local system host in {syst}",{syst=system.cur()}))
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true)
      if has_remote_member() then publish_player(true); publish_entities(true) end
      session.last_claim=stamp
      refresh_time_controls(stamp)
   elseif action=="recover" or action=="query" then
      session.sequence=session.sequence+1
      local query=base("host_query"); query.seq=session.sequence
      broadcast(query,true)
      local winner=session.machine.recovery_candidate or session.machine.host
      if winner and session.member_endpoints[winner] then
         connect(session.member_endpoints[winner],winner)
      end
   end
   if session.machine.state=="host" and stamp-session.last_claim>=5 then
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true); session.last_claim=stamp
   end
   local active_session=has_remote_member()
   if active_session then publish_pending_entity_removals() end
   if active_session and session.machine.state=="host" then
      publish_next_npc_manifest_batch(stamp)
   end
   if active_session and session.machine.system
         and stamp-session.last_player>=1/15 then
      publish_player(false); session.last_player=stamp
   end
   if active_session and session.machine.system and session.machine.state=="host"
         and stamp-session.last_npc>=NPC_STATE_INTERVAL then
      publish_entities(false,true,false)
      session.last_npc=stamp
   end
   if active_session and session.machine.system and session.machine.state=="host"
         and stamp-session.last_npc_focus>=NPC_FOCUS_INTERVAL then
      session.publish_focus_entities(stamp)
      session.last_npc_focus=stamp
   end
   if active_session and session.machine.system and stamp-session.last_craft>=1 then
      publish_entities(false,false,true)
      session.last_craft=stamp
   end
end

return session
