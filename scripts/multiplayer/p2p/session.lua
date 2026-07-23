-- Isolated P2P runtime. Arena multiplayer does not depend on this module.
local codec = require "multiplayer.p2p.codec"
local core = require "multiplayer.p2p.core"
local reconcile = require "multiplayer.p2p.reconcile"
local owned = require "multiplayer.p2p.owned"
local identity = require "multiplayer.p2p.identity"
local enet = require "enet"
local ai_setup = require "ai.core.setup"

local session = {
   running=false, peers={}, endpoints={}, players={}, npcs={}, craft={}, departures={},
   peer_meta={}, sequence=0, last_player=0, last_npc=0, last_manifest=0,
   last_claim=0, host_inventory={}, owned_inventory={}, craft_factions={}, host_welcomed={},
}

-- naev.ticksGame() is already expressed in seconds. Keeping all discovery and
-- publication intervals in that unit is important: dividing it by 1000 leaves
-- peers discovering for 25 minutes and delays manifests for hours.
local function now () return naev.ticksGame and naev.ticksGame() or os.clock() end

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
   local ok, result=pcall(function() return p and p:exists() end)
   return ok and result
end

local function remove_pilot ( p )
   if exists(p) then
      local ok=pcall(function() p:rm() end)
      if not ok then pcall(function() p:setHealth(0) end) end
   end
end

local function lock_autonav ( locked )
   if locked then
      if session.autonav_locked then return end
      session.autonav_locked=true
      naev.keyEnable("speed",false)
      player.autonavReset()
   else
      if not session.autonav_locked then return end
      session.autonav_locked=nil
      naev.keyEnable("speed",true)
   end
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
   local ok, peer=pcall(function() return session.host:connect(endpoint) end)
   if ok and peer then
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
   local ok=pcall(function() peer:send(packet,0,reliable and "reliable" or "unsequenced") end)
   return ok
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

local function base ( kind )
   return {type=kind,node=session.settings.node_id,system=session.machine.system}
end

local function local_player_name ()
   local ok,name=pcall(function() return player.pilot():name() end)
   if ok and type(name)=="string" and name~="" then return name end
   return player.name()
end

local chat_sound
local function play_chat_sound ()
   pcall(function()
      if not chat_sound then chat_sound=audio.new("snd/sounds/hail.opus") end
      chat_sound:play()
   end)
end

local disconnect_sound
local function play_disconnect_sound ()
   pcall(function()
      if not disconnect_sound then disconnect_sound=audio.new("snd/sounds/sokoban/invalid") end
      disconnect_sound:play()
   end)
end

local function departure_candidate ( p )
   local pos_ok,pos=pcall(function() return p:pos() end)
   if not pos_ok or not pos then return end
   local px,py=pos:get()

   local best_kind,best_target,best_distance
   local function consider ( kind, target )
      local target_ok,target_pos=pcall(function() return target:pos() end)
      if not target_ok or not target_pos then return end
      local tx,ty=target_pos:get()
      local dx,dy=tx-px,ty-py
      local distance=dx*dx+dy*dy
      local radius_ok,radius=pcall(function() return target:radius() end)
      if not radius_ok or type(radius)~="number" or radius<0 then radius=0 end
      local pilot_radius_ok,pilot_radius=pcall(function() return p:radius() end)
      if not pilot_radius_ok or type(pilot_radius)~="number" or pilot_radius<0 then pilot_radius=0 end
      -- The last 15 Hz state can trail the real ship slightly. Use the target
      -- radius plus the pilot radius and a small packet/smoothing allowance,
      -- but never infer a departure from elsewhere in the system.
      local departure_range=radius+pilot_radius+300
      if distance > departure_range*departure_range then return end
      if not best_distance or distance < best_distance then
         best_kind,best_target,best_distance=kind,target,distance
      end
   end

   local system_ok,current=pcall(function() return system.cur() end)
   if not system_ok or not current then return end
   local faction_ok,pilot_faction=pcall(function() return p:faction() end)
   local spobs_ok,spobs=pcall(function() return current:spobs() end)
   if spobs_ok then
      for _index,spob in ipairs(spobs) do
         local usable=false
         local services_ok,services=pcall(function() return spob:services() end)
         if services_ok and services and services.land then
            usable=true
            if faction_ok and pilot_faction then
               local spob_faction_ok,spob_faction=pcall(function() return spob:faction() end)
               if spob_faction_ok and spob_faction then
                  local enemies_ok,enemies=pcall(function() return pilot_faction:areEnemies(spob_faction) end)
                  if enemies_ok and enemies then usable=false end
               end
            end
         end
         if usable then consider("land",spob) end
      end
   end
   local jumps_ok,jumps=pcall(function() return current:jumps(true) end)
   if jumps_ok then
      for _index,jump in ipairs(jumps) do consider("jump",jump) end
   end
   return best_kind,best_target
end

local function clear_departure_controls ( p )
   pcall(function() p:taskClear() end)
   pcall(function()
      local memory=p:memory()
      memory.p2p_accel=0
      memory.p2p_primary=false
      memory.p2p_secondary=false
   end)
end

local function disable_departure ( p )
   clear_departure_controls(p)
   pcall(function() p:setDisable() end)
   return "disabled"
end

local function begin_departure ( p )
   local kind,target=departure_candidate(p)
   if not kind then return disable_departure(p) end
   clear_departure_controls(p)
   local ok=pcall(function()
      if kind=="land" then p:pushtask("land",target)
      else p:pushtask("hyperspace",target) end
   end)
   if not ok then return disable_departure(p) end
   return kind
end

local function clear_departure ( node, rejoining )
   local old=session.departures[node]
   if not old then return end
   session.departures[node]=nil
   if not exists(old.pilot) then return end
   if rejoining and old.mode=="disabled" then
      local exploded=pcall(function()
         old.pilot:setNoDeath(false)
         old.pilot:explode()
      end)
      if exploded then return end
      pcall(function()
         old.pilot:setNoDeath(false)
         old.pilot:setHealth(0,0,0)
      end)
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
   pcall(function() p:broadcast("Disconnected.",true) end)
   play_disconnect_sound()
   pcall(function() p:rename(p:name().." (disconnected "..node:sub(1,6)..")") end)
   session.departures[node]={pilot=p,node=node,mode=begin_departure(p)}
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
   pcall(function() peer:disconnect_now() end)
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
   local ok,list=pcall(function() return p:outfitsList() end)
   if ok then for _index,o in ipairs(list) do names[#names+1]=codec.escape(o:nameRaw()) end end
   return table.concat(names,",")
end

local function outfit_slots ( p )
   local slots={}
   local ok,list=pcall(function() return p:outfits() end)
   if ok then
      for index,o in ipairs(list) do
         if o then slots[#slots+1]=tostring(index)..":"..codec.escape(o:nameRaw()) end
      end
   end
   return table.concat(slots,",")
end

local function install_outfits ( p, message )
   local used_slots=false
   for item in (message.slots or ""):gmatch("([^,]+)") do
      local index,encoded=item:match("^(%d+):(.+)$")
      index=tonumber(index)
      local name=encoded and codec.unescape(encoded) or nil
      if index and index>=1 and index<=512 and name then
         local valid,o=pcall(function() return outfit.get(name) end)
         if valid and o then
            pcall(function() p:outfitAddSlot(o,index,true,true) end)
            used_slots=true
         end
      end
   end
   if used_slots then return end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=codec.unescape(item)
      if name and pcall(function() outfit.get(name) end) then
         pcall(function() p:outfitAdd(name,1,true) end)
      end
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
   if not pcall(function() ship.get(message.ship) end) then return end
   clear_departure(message.node,true)
   local fac=faction.dynAdd(nil,"P2P Players","P2P Players",{ai="p2p_remote_control",clear_allies=true,clear_enemies=true})
   local proxy_name=display_name or message.name
   -- The identity registry normally resolves this before spawning. Keep the
   -- invariant here too: a remote participant may never use the local
   -- participant's unsuffixed display name.
   if proxy_name==local_player_name() then proxy_name=proxy_name.." #2" end
   local ok,p=pcall(function()
      local position=(message.x and message.y) and vec2.new(message.x,message.y) or player.pilot():pos()
      return pilot.add(message.ship,fac,position,proxy_name,{ai="p2p_remote_control",naked=true})
   end)
   if not ok or not p then return end
   install_outfits(p,message)
   -- Invincible pilots are excluded from weapon collision in Naev. No-death
   -- proxies can receive local impact effects while never becoming authority
   -- for the remote player's real health.
   pcall(function() p:setNoDeath(true) end)
   pcall(function() p:setHealth(100,100,0) end)
   pcall(function() if p:name()~=proxy_name then p:rename(proxy_name) end end)
   if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
   if message.dir then p:setDir(message.dir) end
   ai_setup.setup(p)
   session.players[message.entity]={pilot=p,node=message.node,sequences={},last_seen=now()}
   if reconcile_craft_leaders then reconcile_craft_leaders(message.node) end
   print("P2P: remote player proxy created")
end

local function active_names ( p )
   local active={}
   local ok,list=pcall(function() return p:actives() end)
   if ok then
      for _index,entry in ipairs(list) do
         if entry.state=="on" or entry.state==true then active[#active+1]=codec.escape(entry.outfit:nameRaw()) end
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
   local ok,list=pcall(pilot.get)
   if ok then
      for _index,p in ipairs(list) do
         local id_ok,pid=pcall(function() return p:id() end)
         if id_ok and tostring(pid)==local_id then return p end
      end
   end
   return nil
end

local function local_state ( p )
   local x,y=p:pos():get(); local vx,vy=p:vel():get()
   local cache=naev.cache()
   local target=p:target()
   return {x=x,y=y,vx=vx,vy=vy,dir=p:dir(),accel=(cache.accel and cache.accel~=0) and 1 or 0,
      primary=(cache.primary and cache.primary~=0) and 1 or 0,
      secondary=(cache.secondary and cache.secondary~=0) and 1 or 0,
      target=target_entity(target), active=active_names(p),energy=p:energy()}
end

local function motion_target ( entry, state )
   entry.motion={x=state.x,y=state.y,vx=state.vx,vy=state.vy,dir=state.dir,received=now()}
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

local smooth_elapsed={player=0,npc=0,craft=0}

local function reset_smoothing ()
   smooth_elapsed.player=0; smooth_elapsed.npc=0; smooth_elapsed.craft=0
end

local function smooth_replicas ( dt, stamp )
   dt=math.max(0,math.min(tonumber(dt) or 1/60,0.1))
   local function update_group ( key, interval, container, limits )
      smooth_elapsed[key]=smooth_elapsed[key]+dt
      if smooth_elapsed[key]+1e-9 < interval then return end
      local step=math.min(smooth_elapsed[key],0.1)
      smooth_elapsed[key]=smooth_elapsed[key]%interval
      for _entity_id,entry in pairs(container) do smooth_entry(entry,step,stamp,limits) end
   end
   update_group("player",1/30,session.players,player_smoothing)
   update_group("craft",1/15,session.craft,craft_smoothing)
   update_group("npc",1/10,session.npcs,npc_smoothing)
end

local function apply_player_state ( message )
   local entry=session.players[message.entity]
   if not entry or not exists(entry.pilot) then return end
   if not reconcile.accept(entry.sequences,"state",message.seq) then return end
   entry.last_seen=now()
   motion_target(entry,message)
   local p=entry.pilot
   pcall(function()
      local target=entity_pilot(message.target)
      p:setTarget(target)
      local memory=p:memory()
      memory.p2p_accel=message.accel==1 and 1 or 0
      memory.p2p_primary=message.primary==1
      memory.p2p_secondary=message.secondary==1
      -- Match arena semantics: a participant becomes hostile locally only
      -- after firing at this client's real player. It stays hostile until the
      -- proxy is removed on system departure.
      if target==player.pilot() and (memory.p2p_primary or memory.p2p_secondary) then
         p:setHostile(true)
      end
      -- Repair only the disposable proxy. Never write health to player.pilot().
      p:setHealth(100,100,0)
      if message.energy then p:setEnergy(message.energy) end
      -- Arena does this on every proxy sync. Replica ammo is otherwise an
      -- unrelated local counter and eventually suppresses replicated fire.
      p:fillAmmo()
      local desired={}
      for item in (message.active or ""):gmatch("([^,]+)") do local name=codec.unescape(item); if name then desired[name]=true end end
      entry.active=entry.active or {}
      local slots={}
      local active_ok,actives=pcall(function() return p:actives() end)
      if active_ok then
         for _index,active in ipairs(actives) do
            local name_ok,name=pcall(function() return active.outfit:nameRaw() end)
            if name_ok and name then slots[name]=active.slot end
         end
      end
      for name in pairs(entry.active) do
         if not desired[name] and slots[name] then p:outfitToggle(slots[name],false) end
      end
      for name in pairs(desired) do
         if not entry.active[name] and slots[name] then p:outfitToggle(slots[name],true) end
      end
      entry.active=desired
   end)
end

local function pilot_owned ( p )
   local ok,value=pcall(function() return p:withPlayer() end)
   if ok and value then return true end
   local seen={}
   while p and not seen[p] do
      seen[p]=true
      local lok,leader=pcall(function() return p:leader() end)
      if not lok or not leader then return false end
      if leader==player.pilot() then return true end
      p=leader
   end
   return false
end

local function is_replica ( p )
   for _entity_id,e in pairs(session.players) do if e.pilot==p then return true end end
   for _entity_id,e in pairs(session.npcs) do if e.pilot==p then return true end end
   for _entity_id,e in pairs(session.craft) do if e.pilot==p then return true end end
   for _node,e in pairs(session.departures) do if e.pilot==p then return true end end
   return false
end

local function pilot_id ( p )
   local ok,id=pcall(function() return p:id() end)
   return ok and tostring(id) or tostring(p)
end

local function pilot_record ( p )
   local armour,shield,stress=p:health(); local x,y=p:pos():get(); local vx,vy=p:vel():get()
   local disabled=false
   pcall(function() disabled=p:disabled() end)
   local leader_id=""
   local leader_ok,leader=pcall(function() return p:leader() end)
   if leader_ok and leader then
      leader_id=leader==player.pilot() and session.settings.node_id
         or session.settings.node_id..":"..pilot_id(leader)
   end
   return {entity=session.settings.node_id..":"..pilot_id(p),ship=p:ship():nameRaw(),name=p:name(),faction=p:faction():nameRaw(),
      outfits=outfit_names(p),slots=outfit_slots(p),x=x,y=y,vx=vx,vy=vy,dir=p:dir(),armour=armour,shield=shield,
      stress=stress,energy=p:energy(),target=target_entity(p:target()),leader=leader_id,disabled=disabled}
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

local function state_line ( rec )
   return table.concat({rec.entity,rec.x,rec.y,rec.vx,rec.vy,rec.dir,rec.armour,rec.shield,
      rec.stress,rec.energy,(rec.target and rec.target~="") and rec.target or "-",
      rec.disabled and 1 or 0},",")
end

local function inventory ()
   local ok,list=pcall(pilot.get)
   if not ok then return {},{} end
   local ambient,craft={},{ }
   for _index,p in ipairs(list) do
      if p~=player.pilot() and exists(p) and not is_replica(p) then
         local rec=pilot_record(p)
         if pilot_owned(p) then craft[rec.entity]=rec else ambient[rec.entity]=rec end
      end
   end
   return ambient,craft
end

local function remove_guest_population ()
   local ok,list=pcall(pilot.get)
   if not ok then return end
   for _index,p in ipairs(list) do
      if p~=player.pilot() and not pilot_owned(p) and not is_replica(p) then remove_pilot(p) end
   end
   pilot.toggleSpawn(false)
end

local function craft_faction ( owner )
   local fac=session.craft_factions[owner]
   if fac then return fac end
   local display=session.identities and session.identities:display_name(owner) or owner
   local raw="P2P Craft "..owner
   local found,existing=pcall(function() return faction.get(raw) end)
   if found and existing then fac=existing
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
         reconcile_craft_leaders(craft_owner)
      end
      return
   end
   if not pcall(function() ship.get(message.ship) end)
         or (not craft_owner and not pcall(function() faction.get(message.faction) end)) then return end
   local fac=craft_owner and craft_faction(craft_owner) or message.faction
   local params=craft_owner and {ai="escort",naked=true} or {naked=true}
   local ok,p=pcall(function() return pilot.add(message.ship,fac,vec2.new(message.x or 0,message.y or 0),message.name,params) end)
   if not ok or not p then return end
   install_outfits(p,message)
   -- Health and existence belong to the host for ambient NPCs and to the
   -- publishing player for owned craft. Local weapons may still disable and
   -- visibly hit replicas, but must not delete them before their authority
   -- sends a reliable removal.
   pcall(function() p:setNoDeath(true) end)
   local entry={pilot=p,owner=craft_owner,leader_id=message.leader,sequences={}}
   container[message.entity]=entry
   if message.vx and message.vy then p:setVel(vec2.new(message.vx,message.vy)) end
   if message.dir then p:setDir(message.dir) end
   if message.armour then p:setHealth(message.armour,message.shield,message.stress) end
   if message.energy then p:setEnergy(message.energy) end
   if message.target and message.target~="" then p:setTarget(entity_pilot(message.target)) end
   if craft_owner then
      ai_setup.setup(p)
      reconcile_craft_leaders(craft_owner)
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
         if leader and exists(leader) then
            local ok=pcall(function() entry.pilot:setLeader(leader) end)
            if ok then entry.bound_leader=leader end
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
      for _index,recipient in ipairs(recipients) do recipient:setHostile(true) end
   end
   pcall(function() leader:msg(recipients,message.order,target) end)
end

local publish_entities,publish_player

local function parse_states ( packed, container, owner )
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
            motion_target(entry,state)
            entry.pilot:setHealth(state.armour,state.shield,state.stress)
            entry.pilot:setEnergy(state.energy)
            if f[12]=="1" then
               local disabled_ok,disabled=pcall(function() return entry.pilot:disabled() end)
               if not disabled_ok or not disabled then pcall(function() entry.pilot:setDisable(true) end) end
            end
            if f[11]=="-" then
               entry.pilot:setTarget(nil)
            elseif f[11] and f[11]~="" then
               local target=entity_pilot(f[11])
               entry.pilot:setTarget(target)
               if owner and target==player.pilot() then entry.pilot:setHostile(true) end
            end
         end
      end
   end
end

local function handle_host_loss ()
   local winner=session.machine:host_lost()
   reconcile.host_lost(session.npcs)
   if winner==session.settings.node_id then
      -- Leave the native-AI pilots alive, but stop classifying them as replicas.
      for _entity_id,entry in pairs(session.npcs) do
         if exists(entry.pilot) then pcall(function() entry.pilot:setNoDeath(false) end) end
      end
      session.npcs={}
      session.host_inventory={}
      session.machine.topology:remember_hint(session.machine.system,winner,session.endpoint,session.machine.claim,now()+60)
      broadcast(claim_message(),true)
      publish_entities(true)
      session.last_claim=now()
   elseif winner and session.member_endpoints and session.member_endpoints[winner] then
      connect(session.member_endpoints[winner],winner)
   end
end

local function host_hint ( peer )
   local hint=session.machine.topology:hint(session.machine.system)
   if session.machine.state=="host" then
      hint={host=session.settings.node_id,endpoint=session.endpoint,claim=session.machine.claim,expires=now()+60}
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
               pcall(function() entry.pilot:rename(accepted) end)
            end
         end
         if not accepted then reject_peer(peer,err); return end
         meta.name=message.name
      end
      meta.node=message.node; meta.cap=message.cap; meta.verified=true
      if message.cap=="player" then session.machine.members[message.node]=true end
      local endpoint=session.peers[peer]
      if meta.cap=="player" and endpoint_valid(endpoint) then
         session.machine.topology:add_peer(endpoint)
         session.settings.recent=session.machine.topology:serialize_peers()
      end
      if message.cap=="player" and session.machine.system then send(peer,base("query"),true) end
      if message.cap=="directory" and session.machine.state=="host" then send(peer,claim_message(),true) end
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
      if message.host==session.settings.node_id then return end
      if meta.node==message.host and endpoint_valid(session.peers[peer]) then message.endpoint=session.peers[peer] end
      local expires=now()+message.ttl
      if session.machine.topology:remember_hint(message.system,message.host,message.endpoint,message.claim,expires) then
         session.settings.recent=session.machine.topology:serialize_peers()
         if meta.node==message.host and meta.cap=="player" then
            local old_state,old_host=session.machine.state,session.machine.host
            local accepted=session.machine:accept_claim{system=message.system,node=message.host,claim=message.claim}
            local joined=accepted and (old_state~="guest" or old_host~=message.host)
            if joined then remove_guest_population() end
         else
            if not connected_node(message.host) then connect(message.endpoint,message.host) end
         end
      end
      return
   end
   if meta.cap=="directory" then return end
   local relayed=(session.machine.state~="host" and meta.node==session.machine.host)
   local owner_ok=(meta.node==message.node or relayed)
   if message.type=="claim" then
      if not owner_ok then return end
      if meta.node==message.node and endpoint_valid(session.peers[peer]) then message.endpoint=session.peers[peer] end
      local old_state,old_host=session.machine.state,session.machine.host
      local accepted=session.machine:accept_claim(message)
      local joined=accepted and (old_state~="guest" or old_host~=message.node)
      session.machine.topology:remember_hint(message.system,message.node,message.endpoint,message.claim,now()+60)
      if joined then
         print("P2P: joined system host")
         remove_guest_population()
      end
      if session.machine.state=="host" then send(peer,claim_message(),true) end
      return
   end
   if message.system ~= session.machine.system then return end
   if (message.type=="player_manifest" or message.type=="player_state" or message.type=="chat"
         or message.type=="craft_manifest" or message.type=="craft_state" or message.type=="craft_remove"
         or message.type=="craft_order"
         or message.type=="leave") and not owner_ok then return end
   if message.owner and message.owner~=message.node then return end
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
            welcome.text="Hi, I'm "..local_player_name()..", the host of this system."
            if send(peer,welcome,true) then session.host_welcomed[message.node]=true end
         end
         broadcast(message,true,peer)
      end
   elseif message.type=="player_state" then
      apply_player_state(message); if session.machine.state=="host" then broadcast(message,false,peer) end
   elseif message.type=="chat" and session.machine:accept_sequence("chat:"..message.node,message.seq) then
      local entry=session.players[message.node]
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
   elseif message.type=="npc_add" and session.machine.state~="host" and message.node==session.machine.host and message.claim==session.machine.claim then spawn_npc(message)
   elseif message.type=="npc_remove" and message.node==session.machine.host and message.claim==session.machine.claim then local e=session.npcs[message.entity]; if e then remove_pilot(e.pilot); session.npcs[message.entity]=nil end
   elseif message.type=="npc_state" and message.node==session.machine.host and message.claim==session.machine.claim and session.machine:accept_sequence("npc",message.seq) then parse_states(message.entities,session.npcs)
   elseif message.type=="craft_manifest" then spawn_npc(message,message.owner); if session.machine.state=="host" then broadcast(message,true,peer) end
   elseif message.type=="craft_state" and session.machine:accept_sequence("craft:"..message.owner,message.seq) then
      parse_states(message.entities,session.craft,message.owner); if session.machine.state=="host" then broadcast(message,false,peer) end
   elseif message.type=="craft_remove" then local e=session.craft[message.entity]; if e and e.owner==message.owner then remove_pilot(e.pilot); session.craft[message.entity]=nil end
   elseif message.type=="craft_order" and session.machine:accept_sequence("craft_order:"..message.owner,message.seq) then
      apply_craft_order(message); if session.machine.state=="host" then broadcast(message,true,peer) end
   elseif message.type=="leave" then
      session.machine.members[message.node]=nil
      owned.cleanup(session.craft,message.node,function(entry) remove_pilot(entry.pilot) end)
      remove_remote_player(message.node)
      if session.machine.state=="host" then broadcast(message,true,peer) end
      if message.node==session.machine.host then handle_host_loss() end
   end
end

publish_player = function ( full )
   local p=player.pilot(); if not p or not session.machine.system then return end
   if full then
      local msg=base("player_manifest"); msg.entity=session.settings.node_id; msg.ship=p:ship():nameRaw(); msg.name=local_player_name(); msg.outfits=outfit_names(p); msg.slots=outfit_slots(p)
      msg.endpoint=session.endpoint
      local state=local_state(p); msg.x=state.x; msg.y=state.y; msg.vx=state.vx; msg.vy=state.vy; msg.dir=state.dir
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
         msg.text="Hi, I'm "..player.name().."!"
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

publish_entities = function ( full )
   local ambient,craft=inventory()
   if session.machine.state=="host" then
      for id,rec in pairs(ambient) do
         if full or not session.host_inventory[id] then broadcast(add_message(rec,"npc_add"),true) end
      end
      for id in pairs(session.host_inventory) do
         if not ambient[id] then
            session.sequence=session.sequence+1
            local msg=base("npc_remove"); msg.claim=session.machine.claim; msg.entity=id; msg.seq=session.sequence
            broadcast(msg,true)
         end
      end
      session.host_inventory=ambient
      local lines={}; for _entity_id,rec in pairs(ambient) do lines[#lines+1]=state_line(rec) end
      publish_state_batches("npc_state",lines)
   end
   for id,rec in pairs(craft) do
      if full or not session.owned_inventory[id] then broadcast(add_message(rec,"craft_manifest",session.settings.node_id),true) end
   end
   for id in pairs(session.owned_inventory) do
      if not craft[id] then
         session.sequence=session.sequence+1
         local msg=base("craft_remove"); msg.owner=session.settings.node_id; msg.entity=id; msg.seq=session.sequence
         broadcast(msg,true)
      end
   end
   session.owned_inventory=craft
   local lines={}; for _entity_id,rec in pairs(craft) do lines[#lines+1]=state_line(rec) end
   publish_state_batches("craft_state",lines,session.settings.node_id)
end

function session.start ( settings )
   if session.running then return true end
   clear_local_controls()
   session.settings=session.defaults(settings)
   local ok,host=pcall(enet.host_create,"*:"..tostring(session.settings.listen_port))
   if not ok or not host then return nil,"unable to create P2P host" end
   session.host=host; session.running=true; session.machine=core.new(session.settings.node_id,now); session.machine:start()
   session.identities=identity.new(session.settings.node_id,local_player_name())
   session.member_endpoints={}; session.craft_factions={}; session.departures={}; session.host_welcomed={}
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
   if not session.running then lock_autonav(false); return end
   if session.machine.system then broadcast(base("leave"),true) end
   session.leave()
   for peer in pairs(session.peers) do pcall(function() peer:disconnect_now() end) end
   session.settings.recent=session.machine.topology:serialize_peers()
   session.machine:stop(); session.host=nil; session.running=false; session.peers={}; session.endpoints={}; session.peer_meta={}; session.identities=nil
end

function session.enter ( system_name )
   if not session.running then return nil,"not running" end
   -- Naev can run both takeoff and enter hooks for one transition. Do not
   -- restart discovery, discard peers, or rebuild the population when the
   -- player is already in this system.
   if session.machine.system==system_name then
      lock_autonav(true)
      return true
   end
   session.leave(); session.machine:enter(system_name)
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
   if not session.machine or not session.machine.system then lock_autonav(false); return end
   broadcast(base("leave"),true)
   for _entity_id,entry in pairs(session.players) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.npcs) do remove_pilot(entry.pilot) end
   for _entity_id,entry in pairs(session.craft) do remove_pilot(entry.pilot) end
   for node in pairs(session.departures) do clear_departure(node,false) end
   session.players={}; session.npcs={}; session.craft={}
   session.departures={}
   session.craft_factions={}; session.host_welcomed={}
   reset_smoothing()
   session.greeted_system=nil
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
         msg.target=target_entity(player.pilot():target())
         if msg.target=="" then return end
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
      for _entity_id,entry in pairs(session.players) do
         if entry.pilot==target then
            target:setHostile(true)
            break
         end
      end
   end
   naev.cache()[key]=input_pressed and 1 or 0
end

function session.update ( dt )
   if not session.running then return end
   -- As in arena multiplayer, cancel autonav every frame so it cannot engage
   -- time compression while this process is simulating a shared system.
   if session.machine and session.machine.system then player.autonavReset() end
   local event=session.host:service(0)
   while event do
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
            end
         end
         local endpoint=session.peers[event.peer]; session.peers[event.peer]=nil; session.peer_meta[event.peer]=nil; if endpoint then session.endpoints[endpoint]=nil end
      end
      event=session.host:service(0)
   end
   greet_host()
   local stamp=now()
   for node,entry in pairs(session.departures) do
      if not exists(entry.pilot) then session.departures[node]=nil end
   end
   local stale_nodes={}
   for node,entry in pairs(session.players) do
      if stamp-(entry.last_seen or stamp)>12 then stale_nodes[#stale_nodes+1]=node end
   end
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
   smooth_replicas(dt,stamp)
   local action=session.machine:tick()
   if stamp-(session.last_seed_connect or 0)>=5 then
      connect_configured(); session.last_seed_connect=stamp
   end
   if action=="claim" then
      print("P2P: claimed local system host")
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true); publish_player(true); publish_entities(true); session.last_claim=stamp; session.last_manifest=stamp
   end
   if session.machine.state=="host" and stamp-session.last_claim>=10 then
      session.machine.topology:remember_hint(session.machine.system,session.settings.node_id,session.endpoint,session.machine.claim,stamp+60)
      broadcast(claim_message(),true); session.last_claim=stamp
   end
   if session.machine.system and stamp-session.last_player>=1/15 then publish_player(false); session.last_player=stamp end
   if session.machine.system and stamp-session.last_npc>=0.2 then publish_entities(false); session.last_npc=stamp end
   if session.machine.system and stamp-session.last_manifest>=10 then publish_player(true); publish_entities(true); session.last_manifest=stamp end
end

return session
