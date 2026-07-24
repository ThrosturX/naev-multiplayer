-- Isolated P2P runtime. Arena multiplayer does not depend on this module.
local codec = require "multiplayer.p2p.codec"
local core = require "multiplayer.p2p.core"
local reconcile = require "multiplayer.p2p.reconcile"
local owned = require "multiplayer.p2p.owned"
local identity = require "multiplayer.p2p.identity"
local status = require "multiplayer.p2p.status"
local enet = require "enet"
local ai_setup = require "ai.core.setup"

local MAX_EVENTS_PER_FRAME = 48
local NPC_STATE_INTERVAL = 1/3
local ACTIVITY_QUERY_INTERVAL = 30
local ACTIVITY_RETENTION = 15*60
local HOST_ALONE_GRACE = 10
local AGGRESSION_GRACE = 20
-- The outer codec percent-escapes this packed field again. Keeping the raw
-- payload well below MAX_PACKET leaves room for worst-case expansion.
local NPC_MANIFEST_BATCH_PAYLOAD = 4000

local session = {
   running=false, peers={}, endpoints={}, players={}, npcs={}, craft={}, departures={},
   peer_meta={}, sequence=0, last_player=0, last_npc=0, last_craft=0,
   last_claim=0, last_claim_check=0, last_liveness=0,
   host_inventory={}, owned_inventory={},
   craft_factions={}, host_welcomed={}, pending_leader_owners={}, resync_sent={},
   ownership_cache={}, initial_sync_until=0, pending_npc_manifests=nil,
   activity={}, activity_received=0, last_activity_query=0,
   indicators=status.new(function () return player.pilot() end),
}

-- Networking, liveness, and publication rates are wall-clock concerns. Using
-- ticksGame here makes autonav time compression multiply connection retries
-- and state collection in real time.
local function now () return naev.ticks() end

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

local function lock_autonav ( locked )
   if locked then
      if session.autonav_locked then return end
      session.autonav_locked=true
      naev.keyEnable("speed",false)
      player.autonavSetSpeed(1)
   else
      if not session.autonav_locked then return end
      session.autonav_locked=nil
      naev.keyEnable("speed",true)
      player.autonavSetSpeed()
   end
end

local function refresh_time_controls ( stamp )
   if not session.machine or not session.machine.system then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(false)
      return
   end
   local solo=session.machine.state=="host"
   if solo then
      for node in pairs(session.machine.members) do
         if node~=session.settings.node_id then solo=false; break end
      end
   end
   if not solo then
      session.solo_since=nil
      session.indicators:clear_host_alone()
      lock_autonav(true)
      return
   end
   stamp=stamp or now()
   session.solo_since=session.solo_since or stamp
   local deadline=session.solo_since+HOST_ALONE_GRACE
   session.indicators:host_alone(deadline,stamp)
   lock_autonav(stamp<deadline)
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
      session.peer_meta[peer]={verified=false,expected_node=expected_node,outbound=true}
      return true
   end
end

local function connect_configured ()
   if endpoint_valid(session.settings.directory) and session.settings.directory~="" then
      connect(session.settings.directory)
   end
   for _index,endpoint in ipairs(session.settings.bootstrap) do connect(endpoint) end
end

local function send ( peer, message, reliable )
   local packet=codec.encode(message)
   if not packet or not peer then return nil end
   peer:send(packet,0,reliable and "reliable" or "unsequenced")
   return true
end

local function broadcast ( message, reliable, except )
   for peer in pairs(session.peers) do
      if peer ~= except then send(peer,message,reliable) end
   end
end

local function connected_node ( node, except, verified_only )
   for peer,meta in pairs(session.peer_meta) do
      if peer~=except and (not verified_only or meta.verified)
            and (meta.node==node or meta.expected_node==node) then return true end
   end
   return false
end

local function has_feature ( meta, feature )
   return meta and type(meta.features)=="string"
      and (","..meta.features..","):find(","..feature..",",1,true)~=nil
end

local function has_remote_member ()
   if not session.machine then return false end
   for node in pairs(session.machine.members) do
      if node~=session.settings.node_id then return true end
   end
   return false
end

local function base ( kind )
   return {type=kind,node=session.settings.node_id,system=session.machine.system}
end

local function local_player_name ()
   local p=player.pilot()
   local name=p and p:exists() and p:name() or nil
   if type(name)=="string" and name~="" then return name end
   return player.name()
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
   p:broadcast("Disconnected.",true)
   play_disconnect_sound()
   p:rename(p:name().." (disconnected "..node:sub(1,6)..")")
   p:setNoDeath(false)
   session.departures[node]={pilot=p,node=node,local_id=tostring(p:id()),mode=begin_departure(p)}
   return true
end

local function hello ( peer )
   send(peer,{type="hello",node=session.settings.node_id,cap="player",name=local_player_name(),
      endpoint=session.endpoint},true)
   if session.machine.system then send(peer,base("query"),true) end
end

local function reject_peer ( peer, reason, quiet )
   local endpoint=session.peers[peer]
   if not quiet then print("P2P: rejected peer: " .. tostring(reason)) end
   peer:disconnect_now()
   session.peers[peer]=nil; session.peer_meta[peer]=nil
   if endpoint then session.endpoints[endpoint]=nil end
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
   for index,o in ipairs(p:outfits()) do
      if o then slots[#slots+1]=tostring(index)..":"..codec.escape(o:nameRaw()) end
   end
   return table.concat(slots,",")
end

-- Naev resource getters throw for unknown names. Manifests are untrusted, so
-- this is validation of external data, matching arena's ship-name validation.
local function resource_get ( getter, name )
   local valid,value=pcall(getter,name)
   if valid then return value end
end

local function install_outfits ( p, message )
   local used_slots=false
   for item in (message.slots or ""):gmatch("([^,]+)") do
      local index,encoded=item:match("^(%d+):(.+)$")
      index=tonumber(index)
      local name=encoded and codec.unescape(encoded) or nil
      if index and index>=1 and index<=512 and name then
         local o=resource_get(outfit.get,name)
         if o then
            p:outfitAddSlot(o,index,true,true)
            used_slots=true
         end
      end
   end
   if used_slots then return end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=codec.unescape(item)
      local o=name and resource_get(outfit.get,name) or nil
      if o then p:outfitAdd(name,1,true) end
   end
end

local reconcile_craft_leaders

local function spawn_proxy ( message, display_name )
   if message.node == session.settings.node_id then return end
   local existing=session.players[message.entity]
   if existing then
      existing.last_seen=now()
      return
   end
   if not resource_get(ship.get,message.ship) then return end
   clear_departure(message.node,true)
   local fac=faction.dynAdd(nil,"P2P Players","P2P Players",{ai="p2p_remote_control",clear_allies=true,clear_enemies=true})
   local proxy_name=display_name or message.name
   -- The identity registry normally resolves this before spawning. Keep the
   -- invariant here too: a remote participant may never use the local
   -- participant's unsuffixed display name.
   if proxy_name==local_player_name() then proxy_name=proxy_name.." #2" end
   local position=(message.x and message.y) and vec2.new(message.x,message.y)
      or player.pilot():pos()
   local arrival_kind,arrival_origin=nearby_transition(position,50,fac)
   local p=pilot.add(message.ship,fac,arrival_origin or position,proxy_name,
      {ai="p2p_remote_control",naked=true})
   if not p then return end
   install_outfits(p,message)
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
   for id,entry in pairs(session.players) do if entry.pilot==target then return id end end
   for id,entry in pairs(session.npcs) do if entry.pilot==target then return id end end
   for id,entry in pairs(session.craft) do if entry.pilot==target then return id end end
   return ""
end

local function entity_pilot ( id )
   if id==session.settings.node_id then return player.pilot() end
   local entry=session.players[id] or session.npcs[id] or session.craft[id]
   if entry then return entry.pilot end
   -- The host's authoritative ambient pilots and each owner's real craft are
   -- not kept in replica tables. Resolve their stable pilot IDs when a remote
   -- order or target refers back to a real local entity.
   local entity_node,local_id=id:match("^([%x]+):(.+)$")
   if entity_node and entity_node~=session.settings.node_id then return nil end
   local_id=local_id or id
   for _index,p in ipairs(pilot.get()) do
      if p and p:exists() and tostring(p:id())==local_id then return p end
   end
   return nil
end

local function local_state ( p )
   local x,y=p:pos():get(); local vx,vy=p:vel():get()
   local armour,shield,stress=p:health()
   local cache=naev.cache()
   local target=p:target()
   -- Input hooks do not see thrust commanded by Naev's autonav AI. Treat
   -- active autonav as thrust so remote proxies retain engine glow and trails.
   local accelerating=(cache.accel and cache.accel~=0) or player.autonav()
   return {x=x,y=y,vx=vx,vy=vy,dir=p:dir(),accel=accelerating and 1 or 0,
      primary=(cache.primary and cache.primary~=0) and 1 or 0,
      secondary=(cache.secondary and cache.secondary~=0) and 1 or 0,
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
   acceleration=600,direction_rate=10,max_prediction=0.4}
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
   if math.abs(math.sin((m.dir-dir)/2))>0.00025 then p:setDir(m.dir) end
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

local function apply_player_state ( message )
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then
      request_resync("all",message.node)
      return
   end
   if not reconcile.accept(entry.sequences,"state",message.seq) then return end
   entry.last_seen=now()
   motion_target(entry,message)
   local p=entry.pilot
   entry.applied=entry.applied or {}
   local target_id=(message.target and message.target~="") and message.target or "-"
   local target=entry.target_pilot
   if entry.applied.target~=target_id then
      target=target_id=="-" and nil or entity_pilot(target_id)
      if target_id=="-" or target then
         p:setTarget(target)
         entry.applied.target=target_id
         entry.target_pilot=target
      end
   end
   local memory=p:memory()
   memory.p2p_accel=message.accel==1 and 1 or 0
   memory.p2p_primary=message.primary==1
   memory.p2p_secondary=message.secondary==1
   -- Match arena semantics: a participant becomes hostile locally only
   -- after firing at this client's real player. It stays hostile until the
   -- pair has been quiet for the hostility grace period.
   if target==player.pilot() and (memory.p2p_primary or memory.p2p_secondary) then
      mark_player_aggression(message.node)
   end
   -- The remote participant is authoritative for its own health. Repair only
   -- this disposable proxy from that reported state; never write health to
   -- player.pilot().
   p:setHealth(message.armour,message.shield,message.stress)
   if message.energy and entry.applied.energy~=message.energy then
      p:setEnergy(message.energy)
      entry.applied.energy=message.energy
   end
   -- Arena does this on every proxy sync. Replica ammo is otherwise an
   -- unrelated local counter and eventually suppresses replicated fire.
   p:fillAmmo()
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
   if target then
      target_id=target_entities and target_entities[tostring(target:id())]
         or target_entity(target)
      target_id=target_id or ""
   end
   return {entity=entity,x=x,y=y,vx=vx,vy=vy,dir=p:dir(),armour=armour,shield=shield,
      stress=stress,energy=p:energy(),target=target_id,disabled=p:disabled()}
end

local function manifest_record ( p, entity )
   local rec=craft_state_record(p,entity)
   local leader_id=""
   local leader=p:leader()
   if leader then
      leader_id=leader==player.pilot() and session.settings.node_id
         or session.settings.node_id..":"..pilot_id(leader)
   end
   rec.ship=p:ship():nameRaw()
   rec.name=p:name()
   rec.faction=p:faction():nameRaw()
   rec.outfits=outfit_names(p)
   rec.slots=outfit_slots(p)
   rec.leader=leader_id
   return rec
end

local function add_message ( rec, kind, owner )
   session.sequence=session.sequence+1
   local msg=base(kind); msg.entity=rec.entity; msg.seq=session.sequence; msg.ship=rec.ship
   msg.name=rec.name; msg.faction=rec.faction; msg.outfits=rec.outfits; msg.slots=rec.slots
   msg.x=rec.x; msg.y=rec.y; msg.vx=rec.vx; msg.vy=rec.vy; msg.dir=rec.dir
   msg.armour=rec.armour; msg.shield=rec.shield; msg.stress=rec.stress; msg.energy=rec.energy
   msg.target=rec.target; msg.leader=rec.leader
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

local function queue_npc_manifests ( records )
   local entries={}
   for id,p in pairs(records) do entries[#entries+1]={id=id,pilot=p} end
   session.pending_npc_manifests={entries=entries,at=1}
end

local function publish_next_npc_manifest_batch ()
   local pending=session.pending_npc_manifests
   if not pending then return end
   local batch,size={},0
   while pending.at<=#pending.entries do
      local entry=pending.entries[pending.at]
      if not exists(entry.pilot) then
         pending.at=pending.at+1
      else
         local rec=entry.rec or manifest_record(entry.pilot,entry.id)
         entry.rec=rec
         local line=manifest_line(rec)
         if #line>NPC_MANIFEST_BATCH_PAYLOAD then
            if #batch>0 then break end
            pending.at=pending.at+1
            broadcast(add_message(rec,"npc_add"),true)
            if pending.at>#pending.entries then session.pending_npc_manifests=nil end
            return
         end
         if #batch>0 and size+#line+1>NPC_MANIFEST_BATCH_PAYLOAD then break end
         batch[#batch+1]=line
         size=size+#line+1
         pending.at=pending.at+1
      end
   end
   if #batch>0 then
      session.sequence=session.sequence+1
      local msg=base("npc_manifest")
      msg.claim=session.machine.claim
      msg.seq=session.sequence
      msg.entities=table.concat(batch,";")
      broadcast(msg,true)
   end
   if pending.at>#pending.entries then session.pending_npc_manifests=nil end
end

local function state_line ( rec )
   return table.concat({rec.entity,rec.x,rec.y,rec.vx,rec.vy,rec.dir,rec.armour,rec.shield,
      rec.stress,rec.energy,(rec.target and rec.target~="") and rec.target or "-",
      rec.disabled and 1 or 0},",")
end

local function inventory ( include_ambient, include_craft )
   local list=pilot.get()
   local replicas=replica_lookup()
   local ambient,craft={},{ }
   local seen={}
   local target_entities={[tostring(player.pilot():id())]=session.settings.node_id}
   for entity,e in pairs(session.players) do if e.local_id then target_entities[e.local_id]=entity end end
   for entity,e in pairs(session.npcs) do if e.local_id then target_entities[e.local_id]=entity end end
   for entity,e in pairs(session.craft) do if e.local_id then target_entities[e.local_id]=entity end end
   for _index,p in ipairs(list) do
      if exists(p) then
         local id=pilot_id(p)
         seen[id]=true
         if p~=player.pilot() and not replicas[id] then
            local entity=session.settings.node_id..":"..id
            target_entities[id]=entity
            local owned_by_player=session.ownership_cache[id]
            if owned_by_player==nil then
               owned_by_player=pilot_owned(p)
               session.ownership_cache[id]=owned_by_player
            end
            if (owned_by_player and include_craft)
                  or (not owned_by_player and include_ambient and session.machine.state=="host") then
               if owned_by_player then craft[entity]=p else ambient[entity]=p end
            end
         end
      end
   end
   for id in pairs(session.ownership_cache) do
      if not seen[id] then session.ownership_cache[id]=nil end
   end
   return ambient,craft,target_entities
end

local function remove_guest_population ()
   local list=pilot.get()
   local replicas=replica_lookup()
   for _index,p in ipairs(list) do
      if exists(p) and p~=player.pilot() and not replicas[pilot_id(p)]
            and not pilot_owned(p) then
         remove_pilot(p)
      end
   end
   pilot.toggleSpawn(false)
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

local function spawn_npc ( message, craft_owner )
   local container=craft_owner and session.craft or session.npcs
   if container[message.entity] then
      if craft_owner then
         container[message.entity].leader_id=message.leader
         session.pending_leader_owners[craft_owner]=true
      end
      return
   end
   if not resource_get(ship.get,message.ship)
         or (not craft_owner and not resource_get(faction.get,message.faction)) then return end
   local fac=craft_owner and craft_faction(craft_owner) or message.faction
   local params=craft_owner and {ai="escort",naked=true} or {naked=true}
   local p=pilot.add(message.ship,fac,vec2.new(message.x or 0,message.y or 0),
      message.name,params)
   if not p then return end
   install_outfits(p,message)
   -- Health and existence belong to the host for ambient NPCs and to the
   -- publishing player for owned craft. Local weapons may still disable and
   -- visibly hit replicas, but must not delete them before their authority
   -- sends a reliable removal.
   p:setNoDeath(true)
   local target_id=(message.target and message.target~="") and message.target or "-"
   local entry={pilot=p,owner=craft_owner,leader_id=message.leader,
      local_id=tostring(p:id()),sequences={},
      applied={armour=message.armour,shield=message.shield,stress=message.stress,
         energy=message.energy,target=target_id=="-" and "-" or nil,
         disabled=message.disabled==true or message.disabled=="1"}}
   container[message.entity]=entry
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
   end
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

local publish_entities,publish_player,publish_manifests

local function parse_states ( packed, container, owner )
   local missing=false
   local received=now()
   local limits=owner and craft_smoothing or npc_smoothing
   local step=owner and 1 or NPC_STATE_INTERVAL
   for line in packed:gmatch("([^;]+)") do
      local f={}; for value in line:gmatch("([^,]+)") do f[#f+1]=value end
      local id=f[1]; local entry=container[id]
      if entry and (not owner or entry.owner==owner) and exists(entry.pilot) then
         local state={x=tonumber(f[2]),y=tonumber(f[3]),vx=tonumber(f[4]),vy=tonumber(f[5]),dir=tonumber(f[6]),armour=tonumber(f[7]),shield=tonumber(f[8]),stress=tonumber(f[9]),energy=tonumber(f[10])}
         local bounded=state.x and state.energy and math.abs(state.x)<=1e9 and math.abs(state.y)<=1e9
            and math.abs(state.vx)<=1e7 and math.abs(state.vy)<=1e7 and math.abs(state.dir)<=1e6
            and state.armour>=0 and state.armour<=1e9 and state.shield>=0 and state.shield<=1e9
            and state.stress>=0 and state.stress<=1e9 and state.energy>=0 and state.energy<=1e9
         if bounded then
            motion_target(entry,state,received)
            -- NPC and owned-craft populations can contain hundreds of pilots.
            -- Correct each replica when its authoritative packet arrives
            -- instead of rescanning the whole population from hook.update.
            smooth_entry(entry,step,received,limits)
            local applied=entry.applied or {}
            entry.applied=applied
            if applied.armour~=state.armour or applied.shield~=state.shield
                  or applied.stress~=state.stress then
               entry.pilot:setHealth(state.armour,state.shield,state.stress)
               applied.armour=state.armour
               applied.shield=state.shield
               applied.stress=state.stress
            end
            if applied.energy~=state.energy then
               entry.pilot:setEnergy(state.energy)
               applied.energy=state.energy
            end
            local authoritative_disabled=f[12]=="1"
            if authoritative_disabled and not applied.disabled then
               entry.pilot:setDisable(true)
            end
            applied.disabled=authoritative_disabled
            local target_id=(f[11] and f[11]~="") and f[11] or "-"
            if applied.target~=target_id then
               local target=target_id=="-" and nil or entity_pilot(target_id)
               if target_id=="-" or target then
                  entry.pilot:setTarget(target)
                  applied.target=target_id
                  if owner and target==player.pilot() then entry.pilot:setHostile(true) end
               end
            end
         end
      elseif id then
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

local function spawn_npc_manifest ( message )
   for line in message.entities:gmatch("([^;]+)") do
      local fields,field_count,valid={},0,true
      for field in line:gmatch("([^,]+)") do
         field_count=field_count+1
         local decoded=parse_manifest_field(field)
         if decoded==nil then valid=false else fields[field_count]=decoded end
      end
      if valid and field_count==17 then
         local manifest={
            type="npc_add",node=message.node,system=message.system,claim=message.claim,
            seq=message.seq,entity=fields[1],ship=fields[2],name=fields[3],
            faction=fields[4],outfits=fields[5],slots=fields[6],
            x=fields[7],y=fields[8],vx=fields[9],vy=fields[10],dir=fields[11],
            armour=fields[12],shield=fields[13],stress=fields[14],energy=fields[15],
            target=fields[16]~="" and fields[16] or nil,
            leader=fields[17]~="" and fields[17] or nil,
         }
         if codec.validate(manifest) then spawn_npc(manifest) end
      end
   end
end

local function handle_host_loss ()
   local winner=session.machine:host_lost()
   reconcile.host_lost(session.npcs)
   if winner==session.settings.node_id then
      -- Leave the native-AI pilots alive, but stop classifying them as replicas.
      for _entity_id,entry in pairs(session.npcs) do
         if exists(entry.pilot) then entry.pilot:setNoDeath(false) end
      end
      session.npcs={}
      session.host_inventory={}
      session.machine.topology:remember_hint(session.machine.system,winner,session.endpoint,session.machine.claim,now()+60)
      broadcast(claim_message(),true)
      if has_remote_member() then publish_entities(true) end
      session.last_claim=now()
   elseif winner and session.member_endpoints and session.member_endpoints[winner] then
      connect(session.member_endpoints[winner],winner)
   end
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
      local endpoint=session.peers[peer]
      if meta.cap=="player" and endpoint_valid(endpoint) then
         session.machine.topology:add_peer(endpoint)
         session.settings.recent=session.machine.topology:serialize_peers()
      end
      if message.cap=="player" and session.machine.system then send(peer,base("query"),true) end
      if message.cap=="directory" then
         if session.machine.state=="host" then send(peer,claim_message(),true) end
         if has_feature(meta,"activity") then
            send(peer,{type="activity_query",node=session.settings.node_id},true)
            session.last_activity_query=now()
         end
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
            local old_state,old_host=session.machine.state,session.machine.host
            local accepted=session.machine:accept_claim{system=message.system,node=message.host,claim=message.claim}
            local joined=accepted and (old_state~="guest" or old_host~=message.host)
            refresh_time_controls()
            if joined then
               remove_guest_population()
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
      end
      return
   end
   local relayed=(session.machine.state~="host" and meta.node==session.machine.host)
   local owner_ok=(meta.node==message.node or relayed)
   if message.type=="claim" then
      if session.locally_claimed then return end
      if not owner_ok then return end
      if meta.node==message.node and endpoint_valid(session.peers[peer]) then message.endpoint=session.peers[peer] end
      local old_state,old_host=session.machine.state,session.machine.host
      local accepted=session.machine:accept_claim(message)
      local joined=accepted and (old_state~="guest" or old_host~=message.node)
      refresh_time_controls()
      session.machine.topology:remember_hint(message.system,message.node,message.endpoint,message.claim,now()+60)
      if joined then
         print("P2P: joined system host")
         remove_guest_population()
         request_resync("all")
      end
      if session.machine.state=="host" then send(peer,claim_message(),true) end
      return
   end
   if message.system ~= session.machine.system then return end
   if (message.type=="player_manifest" or message.type=="player_state" or message.type=="chat"
         or message.type=="craft_manifest" or message.type=="craft_state" or message.type=="craft_remove"
         or message.type=="craft_order" or message.type=="resync"
         or message.type=="leave") and not owner_ok then return end
   if message.type~="resync" and message.owner and message.owner~=message.node then return end
   if message.type=="resync" then
      if message.node==session.settings.node_id
            or not session.machine:accept_sequence("resync:"..message.node,message.seq) then return end
      if session.machine.state=="host" then broadcast(message,true,peer) end
      -- Reuse the compatible "all" scope with an owner as a targeted player
      -- repair. Older peers safely answer it as a full resynchronization.
      local player_target=message.scope=="all" and message.owner
      if message.scope=="all"
            and (not player_target or player_target==session.settings.node_id) then
         publish_player(true)
      end
      if not player_target then
         publish_manifests(message.scope,message.owner,message.entity)
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
      session.machine.members[message.node]=true
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
         broadcast(message,true,peer)
      end
   elseif message.type=="player_state" then
      apply_player_state(message); if session.machine.state=="host" then broadcast(message,false,peer) end
   elseif message.type=="chat" and session.machine:accept_sequence("chat:"..message.node,message.seq) then
      local entry=session.players[message.node]
      if message.node~=session.settings.node_id
            and (not entry or not exists(entry.pilot)) then
         request_resync("all",message.node)
      end
      if message.node==session.settings.node_id then
         pilot.comm(local_player_name(),message.text)
      elseif entry and exists(entry.pilot) then
         entry.pilot:broadcast(message.text,true)
      else
         pilot.comm(session.identities:display_name(message.node) or message.node,message.text)
      end
      play_chat_sound()
      -- Arena echoes chat through the server to every client, including the
      -- sender. Do the same so a guest sees confirmation of its own message.
      if session.machine.state=="host" then broadcast(message,true) end
   elseif message.type=="npc_manifest" and session.machine.state~="host"
         and message.node==session.machine.host and message.claim==session.machine.claim
         and session.machine:accept_sequence("npc_manifest",message.seq) then
      spawn_npc_manifest(message)
   elseif message.type=="npc_add" and session.machine.state~="host" and message.node==session.machine.host and message.claim==session.machine.claim then spawn_npc(message)
   elseif message.type=="npc_remove" and message.node==session.machine.host and message.claim==session.machine.claim then local e=session.npcs[message.entity]; if e then remove_pilot(e.pilot); session.npcs[message.entity]=nil end
   elseif message.type=="npc_state" and message.node==session.machine.host and message.claim==session.machine.claim and session.machine:accept_sequence("npc",message.seq) then parse_states(message.entities,session.npcs)
   elseif message.type=="craft_manifest" and message.owner~=session.settings.node_id then
      spawn_npc(message,message.owner); if session.machine.state=="host" then broadcast(message,true,peer) end
   elseif message.type=="craft_state" and message.owner~=session.settings.node_id
         and session.machine:accept_sequence("craft:"..message.owner,message.seq) then
      parse_states(message.entities,session.craft,message.owner); if session.machine.state=="host" then broadcast(message,false,peer) end
   elseif message.type=="craft_remove" and message.owner~=session.settings.node_id then
      local e=session.craft[message.entity]; if e and e.owner==message.owner then remove_pilot(e.pilot); session.craft[message.entity]=nil end
   elseif message.type=="craft_order" and session.machine:accept_sequence("craft_order:"..message.owner,message.seq) then
      apply_craft_order(message); if session.machine.state=="host" then broadcast(message,true,peer) end
   elseif message.type=="leave" then
      session.machine.members[message.node]=nil
      owned.cleanup(session.craft,message.node,function(entry) remove_pilot(entry.pilot) end)
      remove_remote_player(message.node)
      if session.machine.state=="host" then broadcast(message,true,peer) end
      if message.node==session.machine.host then handle_host_loss() end
      refresh_time_controls()
   end
end

publish_player = function ( full )
   local p=player.pilot(); if not p or not session.machine.system then return end
   if full then
      local msg=base("player_manifest"); msg.entity=session.settings.node_id; msg.ship=p:ship():nameRaw(); msg.name=local_player_name(); msg.outfits=outfit_names(p); msg.slots=outfit_slots(p)
      msg.endpoint=session.endpoint
      local state=local_state(p); msg.x=state.x; msg.y=state.y; msg.vx=state.vx; msg.vy=state.vy; msg.dir=state.dir
      msg.armour=state.armour; msg.shield=state.shield; msg.stress=state.stress
      broadcast(msg,true)
   end
   session.sequence=session.sequence+1
   local state=local_state(p); local msg=base("player_state"); msg.entity=session.settings.node_id; msg.seq=session.sequence
   for k,v in pairs(state) do msg[k]=v end
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
         if send(peer,msg,true) then session.greeted_system=session.machine.system end
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
      if kind=="npc_state" then msg.claim=session.machine.claim else msg.owner=owner end
      broadcast(msg,false); batch={}; size=0
   end
   for _index,line in ipairs(lines) do
      if size+#line+1>12000 then flush() end
      batch[#batch+1]=line; size=size+#line+1
   end
   flush()
end

publish_entities = function ( full, include_ambient, include_craft )
   include_ambient=include_ambient~=false
   include_craft=include_craft~=false
   local ambient,craft,target_entities=inventory(include_ambient,include_craft)
   if include_ambient and session.machine.state=="host" then
      for id,p in pairs(ambient) do
         if full or not session.host_inventory[id] then
            if not full then broadcast(add_message(manifest_record(p,id),"npc_add"),true) end
         end
      end
      if full then queue_npc_manifests(ambient) end
      for id in pairs(session.host_inventory) do
         if not ambient[id] then
            session.sequence=session.sequence+1
            local msg=base("npc_remove"); msg.claim=session.machine.claim; msg.entity=id; msg.seq=session.sequence
            broadcast(msg,true)
         end
      end
      session.host_inventory=ambient
      local lines={}
      for id,p in pairs(ambient) do
         lines[#lines+1]=state_line(craft_state_record(p,id,target_entities))
      end
      publish_state_batches("npc_state",lines)
   end
   if include_craft then
      for id,p in pairs(craft) do
         if full or not session.owned_inventory[id] then
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
         lines[#lines+1]=state_line(craft_state_record(p,id,target_entities))
      end
      publish_state_batches("craft_state",lines,session.settings.node_id)
   end
end

publish_manifests = function ( scope, owner, entity )
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
         broadcast(add_message(manifest_record(p,entity),kind,
            kind=="craft_manifest" and session.settings.node_id or nil),true)
         return
      end
      -- The request may race a newly-created entity before the next inventory
      -- tick. Fall through to one scan only in that uncommon case.
   end
   local ambient,craft=inventory(include_ambient,include_craft)
   if include_ambient and session.machine.state=="host" then
      if entity then
         local p=ambient[entity]
         if p then broadcast(add_message(manifest_record(p,entity),"npc_add"),true) end
      else queue_npc_manifests(ambient) end
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
   session.indicators:clear()
   session.settings=session.defaults(settings)
   local ok,host=pcall(enet.host_create,"*:"..tostring(session.settings.listen_port))
   if not ok then return nil,"unable to create P2P host: "..tostring(host) end
   if not host then return nil,"unable to create P2P host" end
   session.host=host; session.running=true; session.machine=core.new(session.settings.node_id,now); session.machine:start()
   session.identities=identity.new(session.settings.node_id,local_player_name())
   session.member_endpoints={}; session.craft_factions={}; session.departures={}; session.host_welcomed={}
   session.pending_leader_owners={}; session.resync_sent={}; session.ownership_cache={}
   session.pending_npc_manifests=nil
   session.activity={}
   session.activity_received=0
   session.last_activity_query=0
   session.initial_sync_until=0
   session.solo_since=nil
   session.last_liveness=now()
   session.last_claim_check=0
   session.endpoint=tostring(host:get_socket_address())
   print("P2P: listener started")
   session.machine.topology:load_peers(session.settings.recent)
   connect_configured()
   for _index,entry in ipairs(session.settings.recent) do connect(entry.endpoint) end
   session.last_seed_connect=now()
   return true
end

function session.stop ()
   clear_local_controls()
   if not session.running then session.indicators:clear(); lock_autonav(false); return end
   if session.machine.system then broadcast(base("leave"),true) end
   session.leave()
   for peer in pairs(session.peers) do peer:disconnect_now() end
   session.settings.recent=session.machine.topology:serialize_peers()
   session.machine:stop(); session.host=nil; session.running=false; session.peers={}; session.endpoints={}; session.peer_meta={}; session.identities=nil
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
   session.leave(); session.machine:enter(system_name)
   session.locally_claimed=locally_claimed()
   session.last_claim_check=now()
   session.last_liveness=now()
   session.solo_since=nil
   reset_smoothing()
   session.greeted_system=nil
   lock_autonav(true)
   connect_configured(); session.last_seed_connect=now()
   print("P2P: discovering system host")
   for peer in pairs(session.peers) do send(peer,base("query"),true) end
   publish_player(true)
   return true
end

function session.leave ()
   if not session.machine or not session.machine.system then
      session.indicators:clear()
      lock_autonav(false)
      return
   end
   broadcast(base("leave"),true)
   for _entity_id,entry in pairs(session.players) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.npcs) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.craft) do remove_pilot(entry.pilot) end
   for node in pairs(session.departures) do clear_departure(node,false) end
   session.players={}; session.npcs={}; session.craft={}
   session.departures={}
   session.craft_factions={}; session.host_welcomed={}
   session.pending_leader_owners={}; session.resync_sent={}; session.ownership_cache={}
   session.pending_npc_manifests=nil
   session.initial_sync_until=0
   session.solo_since=nil
   session.indicators:clear()
   reset_smoothing()
   session.greeted_system=nil
   session.locally_claimed=nil
   pilot.toggleSpawn(true); session.machine:leave(); lock_autonav(false)
end

function session.send_chat ( text )
   if not session.running or not session.machine.system or type(text)~="string" or text=="" then return nil end
   session.sequence=session.sequence+1
   local msg=base("chat"); msg.seq=session.sequence; msg.text=text:sub(1,1024)
   -- Display immediately. If a host relays the message back, the accepted
   -- sequence makes that echo a no-op instead of showing it twice.
   session.machine:accept_sequence("chat:"..session.settings.node_id,msg.seq)
   pilot.comm(local_player_name(),msg.text)
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
   -- networking and, for a host, the authoritative NPC simulation while a
   -- menu is open too.
   if session.machine and session.machine.system and not player.isLanded() then
      naev.unpause()
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
end

function session.enforce_time_controls ()
   if session.autonav_locked then player.autonavSetSpeed(1) end
end

function session.update ( dt )
   if not session.running then return end
   local stamp=now()
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
            session.peer_meta[event.peer]={verified=false,outbound=false}
         end
         hello(event.peer)
      elseif event.type=="receive" then
         local message,err=codec.decode(event.data)
         if message then on_message(event.peer,message) else print("P2P: rejected packet: " .. tostring(err)) end
      elseif event.type=="disconnect" then
         local meta=session.peer_meta[event.peer]
         if meta and meta.node then
            local last_connection=not connected_node(meta.node,event.peer,true)
            if last_connection then
               session.machine.members[meta.node]=nil
               owned.cleanup(session.craft,meta.node,function(entry) remove_pilot(entry.pilot) end)
               session.identities:remove(meta.node)
               remove_remote_player(meta.node)
               if session.machine.state=="host" then
                  local msg=base("leave"); msg.node=meta.node; broadcast(msg,true,event.peer)
               end
               if meta.node==session.machine.host then handle_host_loss() end
               refresh_time_controls()
            end
         end
         local endpoint=session.peers[event.peer]; session.peers[event.peer]=nil; session.peer_meta[event.peer]=nil; if endpoint then session.endpoints[endpoint]=nil end
      end
      if processed>=MAX_EVENTS_PER_FRAME then break end
      event=session.host:service(0)
   end
   for owner in pairs(session.pending_leader_owners) do
      reconcile_craft_leaders(owner)
      session.pending_leader_owners[owner]=nil
   end
   greet_host()
   if stamp-(session.last_liveness or 0)>=1 then
      session.last_liveness=stamp
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
         local stale=not exists(entry.pilot) or stamp-(entry.last_seen or stamp)>12
         if stale then
            stale_nodes[#stale_nodes+1]=node
         elseif entry.last_aggression then
            aggression_deadline=math.max(aggression_deadline or 0,
               entry.last_aggression+AGGRESSION_GRACE)
         end
      end
      session.indicators:reconcile_aggression(aggression_deadline,stamp)
      for _index,node in ipairs(stale_nodes) do
         session.machine.members[node]=nil
         owned.cleanup(session.craft,node,function(entry) remove_pilot(entry.pilot) end)
         session.identities:remove(node)
         remove_remote_player(node)
         if session.machine.state=="host" then
            local msg=base("leave")
            msg.node=node
            broadcast(msg,true)
         end
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
   local action=session.machine:tick()
   if stamp-(session.last_activity_query or 0)>=ACTIVITY_QUERY_INTERVAL then
      session.request_activity()
   end
   if stamp-(session.last_seed_connect or 0)>=5 then
      connect_configured(); session.last_seed_connect=stamp
   end
   if action=="claim" then
      print("P2P: claimed local system host")
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true)
      if has_remote_member() then publish_player(true); publish_entities(true) end
      session.last_claim=stamp
      refresh_time_controls(stamp)
   end
   if session.machine.state=="host" and stamp-session.last_claim>=10 then
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true); session.last_claim=stamp
   end
   local active_session=has_remote_member()
   if active_session and session.machine.state=="host" then publish_next_npc_manifest_batch() end
   if active_session and session.machine.system
         and stamp-session.last_player>=1/15 then
      publish_player(false); session.last_player=stamp
   end
   if active_session and session.machine.system and session.machine.state=="host"
         and stamp-session.last_npc>=NPC_STATE_INTERVAL then
      publish_entities(false,true,false)
      session.last_npc=stamp
   end
   if active_session and session.machine.system and stamp-session.last_craft>=1 then
      publish_entities(false,false,true)
      session.last_craft=stamp
   end
end

return session
