package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local wire_codec=require "multiplayer.p2p.codec"

local network={hosts={},next_port=63000}
local peer_mt={}
peer_mt.__index=peer_mt
function peer_mt:send ( data, _channel, _flag )
   if self.closed then return end
   local kind=data:match("^MP2P/1 ([%w_]+)")
   if kind and self.host.sent_types then
      self.host.sent_types[kind]=(self.host.sent_types[kind] or 0)+1
   end
   table.insert(self.remote_host.events,{type="receive",peer=self.remote_peer,data=data})
end
function peer_mt:disconnect_now ()
   if self.closed then return end
   self.closed=true; self.remote_peer.closed=true
   table.insert(self.host.events,{type="disconnect",peer=self})
   table.insert(self.remote_host.events,{type="disconnect",peer=self.remote_peer})
end
peer_mt.__tostring=function(self) return self.remote_host.address end

local host_mt={}
host_mt.__index=host_mt
function host_mt:get_socket_address () return self.address end
function host_mt:service () return table.remove(self.events,1) end
function host_mt:connect ( endpoint )
   local port=tonumber(endpoint:match(":(%d+)$")); local remote=network.hosts[port]
   assert(remote,"fake ENet endpoint unavailable: "..endpoint)
   local outgoing=setmetatable({host=self,remote_host=remote},peer_mt)
   local incoming=setmetatable({host=remote,remote_host=self},peer_mt)
   outgoing.remote_peer=incoming; incoming.remote_peer=outgoing
   table.insert(self.events,{type="connect",peer=outgoing})
   table.insert(remote.events,{type="connect",peer=incoming})
   return outgoing
end

package.preload.enet=function()
   return {host_create=function(bind)
      local port=tonumber(bind:match(":(%d+)$")) or 0
      if port==0 then port=network.next_port; network.next_port=port+1 end
      assert(not network.hosts[port],"duplicate fake ENet port")
      local host=setmetatable({events={},address="0.0.0.0:"..port,sent_types={}},host_mt)
      network.hosts[port]=host
      return host
   end}
end
package.preload["ai.core.setup"]=function()
   return {setup=function(p) p.ai_setup_called=true end}
end

local function vector ( x, y )
   return {x=x or 0,y=y or 0,get=function(self) return self.x,self.y end}
end

local function resource ( name )
   return {
      nameRaw=function() return name end,
      areEnemies=function() return false end,
   }
end

local function departure_target ( x, y, landable )
   local target={position=vector(x,y),target_radius=200}
   function target:pos () return self.position end
   function target:radius () return self.target_radius end
   function target:services () return {land=landable==true} end
   function target:faction () return resource("Independent") end
   return target
end

local function new_world ( player_name )
   local world={clock=0,wall_clock=0,pilots={},next_id=1,spawn=true,player_name=player_name,c_calls={},
      speed_enabled=true,autonav_speed_calls=0,unpauses=0,comms={},spobs={},jumps={},
      claim_available=true,autonaving=false,missing_outfits={}}
   local function counted ( name )
      world.c_calls[name]=(world.c_calls[name] or 0)+1
   end
   local pilot_methods={}
   pilot_methods.__index=pilot_methods
   function pilot_methods:exists () return not self.removed end
   function pilot_methods:rm () self.removed=true end
   function pilot_methods:name () counted("name"); return self.pilot_name end
   function pilot_methods:ship () counted("ship"); return resource(self.ship_name) end
   function pilot_methods:faction () counted("faction"); return resource(self.faction_name) end
   function pilot_methods:outfitsList ()
      counted("outfitsList")
      local list={}
      for _index,name in ipairs(self.outfit_names) do list[#list+1]=resource(name) end
      return list
   end
   function pilot_methods:outfits ()
      counted("outfits")
      local list={}
      for index,name in ipairs(self.outfit_names) do list[index]=resource(name) end
      return list
   end
   function pilot_methods:actives () return self.active_outfits end
   function pilot_methods:pos () return self.position end
   function pilot_methods:vel () return self.velocity end
   function pilot_methods:dir () return self.direction end
   function pilot_methods:target () return self.target_pilot end
   function pilot_methods:health () return self.armour,self.shield,self.stress end
   function pilot_methods:energy () return self.energy_value end
   function pilot_methods:disabled () return self.is_disabled==true end
   function pilot_methods:radius () return 50 end
   function pilot_methods:id () return self.pilot_id end
   function pilot_methods:withPlayer ()
      return self.owned or self.faction_name=="Player" or self.leader_pilot==world.local_pilot
   end
   function pilot_methods:leader () counted("leader"); return self.leader_pilot end
   function pilot_methods:ainame () return self.ai_name end
   function pilot_methods:setLeader (v) self.leader_pilot=v end
   function pilot_methods:msg (receivers,kind,data)
      for _index,receiver in ipairs(receivers) do
         receiver.last_order={sender=self,kind=kind,data=data}
      end
   end
   function pilot_methods:setPos (v) self.position=v; self.position_sets=(self.position_sets or 0)+1 end
   function pilot_methods:setVel (v) self.velocity=v; self.velocity_sets=(self.velocity_sets or 0)+1 end
   function pilot_methods:setDir (v) self.direction=v end
   function pilot_methods:setTarget (v)
      self.target_sets=(self.target_sets or 0)+1
      self.target_pilot=v
   end
   function pilot_methods:setHealth (a,s,t)
      self.health_sets=(self.health_sets or 0)+1
      self.armour=a; self.shield=s; self.stress=t
   end
   function pilot_methods:setEnergy (v)
      self.energy_sets=(self.energy_sets or 0)+1
      self.energy_value=v
   end
   function pilot_methods:setInvincible (v) self.invincible=v end
   function pilot_methods:setNoDeath (v) self.no_death=v end
   function pilot_methods:setDisable ()
      self.disable_sets=(self.disable_sets or 0)+1
      self.is_disabled=true
   end
   function pilot_methods:setHostile (v) self.hostile=v==nil or v end
   function pilot_methods:effectAdd (name,duration)
      self.effects=self.effects or {}
      self.effect_adds=self.effect_adds or {}
      local expires=world.clock+duration
      local old=self.effects[name]
      if old and old.expires>expires then return true end
      self.effects[name]={duration=duration,expires=expires}
      self.effect_adds[name]=(self.effect_adds[name] or 0)+1
      return true
   end
   function pilot_methods:effectRm (name)
      self.effects=self.effects or {}
      self.effect_rms=self.effect_rms or {}
      self.effects[name]=nil
      self.effect_rms[name]=(self.effect_rms[name] or 0)+1
   end
   function pilot_methods:rename (v) self.pilot_name=v end
   function pilot_methods:taskClear () self.task=nil end
   function pilot_methods:pushtask (kind,target) self.task={kind=kind,target=target} end
   function pilot_methods:explode () self.exploded=true; self.removed=true end
   function pilot_methods:fillAmmo () self.ammo_fills=(self.ammo_fills or 0)+1 end
   function pilot_methods:outfitAdd (name)
      if type(name)~="string" then name=name:nameRaw() end
      self.outfit_names[#self.outfit_names+1]=name
      if name=="The Bite" or name:match("^The Bite %- ") then
         self.active_outfits[#self.active_outfits+1]={outfit=resource(name),slot=#self.active_outfits+1,state="off"}
      end
   end
   function pilot_methods:outfitAddSlot (item,slot)
      local name=type(item)=="string" and item or item:nameRaw()
      self.outfit_names[slot]=name
      self.slotted_outfits=self.slotted_outfits or {}
      self.slotted_outfits[slot]=name
      if name=="The Bite" or name:match("^The Bite %- ") then
         self.active_outfits[#self.active_outfits+1]={outfit=resource(name),slot=slot,state="off"}
      end
      return true
   end
   function pilot_methods:outfitToggle (slot,on)
      for _index,active in ipairs(self.active_outfits) do
         if active.slot==slot then
            active.state=on and "on" or "off"
            self.last_outfit_toggle={name=active.outfit:nameRaw(),on=on}
            return true
         end
      end
      return false
   end
   function pilot_methods:memory () return self.pilot_memory end
   function pilot_methods:broadcast (text)
      self.last_chat=text
      self.chat_count=(self.chat_count or 0)+1
   end

   function world:add_pilot ( ship_name, faction_name, pilot_name, owned, ai_name )
      local p=setmetatable({ship_name=ship_name,faction_name=faction_name,pilot_name=pilot_name,
         owned=owned,position=vector(),velocity=vector(),direction=0,armour=100,shield=100,
         stress=0,energy_value=100,pilot_id=self.next_id,pilot_memory={},ai_name=ai_name,
         outfit_names={},active_outfits={}},pilot_methods)
      self.next_id=self.next_id+1; table.insert(self.pilots,p); return p
   end
   world.local_pilot=world:add_pilot("Llama","Player",player_name,true)

   local env=setmetatable({}, {__index=_G})
   -- Naev's Lua sandbox does not expose os.clock. Keep the integration world
   -- honest so per-frame networking cannot accidentally depend on it again.
   env.os={}
   world.cache={}
   env.naev={ticks=function() return world.wall_clock end,
      ticksGame=function() return world.clock end,cache=function() return world.cache end,
      claimTest=function() counted("claim_test"); return world.claim_available end,
      keyEnable=function(key,enabled) assert(key=="speed"); world.speed_enabled=enabled end,
      unpause=function() world.unpauses=world.unpauses+1 end}
   env.rnd={rnd=function(a) return a or 1 end}
   env.vec2={new=vector}
   env.player={name=function() return world.player_name end,pilot=function() return world.local_pilot end,
      isLanded=function() return false end,
      autonav=function() return world.autonaving,world.autonav_speed or 1 end,
      autonavSetSpeed=function(speed)
         world.autonav_speed_calls=world.autonav_speed_calls+1
         world.autonav_speed=speed
      end}
   env.system={cur=function()
      return {
         spobs=function() return world.spobs end,
         jumps=function() return world.jumps end,
      }
   end}
   env.ship={get=function(name) assert(type(name)=="string" and name~=""); return resource(name) end}
   env.outfit={
      get=function(name)
         if world.missing_outfits[name] then
            world.unknown_outfit_gets=(world.unknown_outfit_gets or 0)+1
            error("unknown outfit reached outfit.get")
         end
         return resource(name)
      end,
      exists=function(name)
         if world.missing_outfits[name] then return nil end
         return resource(name)
      end,
   }
   env.faction={get=function(name) return resource(name) end,
      dynAdd=function(_base,raw) return resource(raw) end}
   env.audio={new=function(path)
      if path=="snd/sounds/hail.opus" then
         return {play=function() world.hail_sounds=(world.hail_sounds or 0)+1 end}
      end
      assert(path=="snd/sounds/sokoban/invalid")
      return {play=function() world.disconnect_sounds=(world.disconnect_sounds or 0)+1 end}
   end}
   env.pilot={
      get=function()
         counted("pilot_get")
         local out={}
         for _index,p in ipairs(world.pilots) do if not p.removed then out[#out+1]=p end end
         return out
      end,
      add=function(ship_name,fac,pos,name,params)
         local faction_name=type(fac)=="string" and fac or fac:nameRaw()
         local p=world:add_pilot(ship_name,faction_name,name,false,params and params.ai)
         p.spawn_origin=pos
         if pos and pos.get then p.position=pos
         elseif pos and pos.pos then p.position=pos:pos() end
         return p
      end,
      toggleSpawn=function(v) world.spawn=v end,
      taskClear=function() end,pushtask=function() end,
      comm=function(name,text)
         world.comms[#world.comms+1]={name=name,text=text}
      end,
   }
   env.print=function(...) io.stdout:write("["..player_name.."] "); print(...) end
   world.env=env
   local chunk=assert(loadfile("scripts/multiplayer/p2p/session.lua","t",env))
   world.session=chunk()
   return world
end

local function update ( worlds, rounds )
   for _round=1,rounds or 1 do for _index,w in ipairs(worlds) do w.session.update() end end
end
local function advance ( worlds, seconds, rounds )
   for _index,w in ipairs(worlds) do
      w.clock=w.clock+seconds
      w.wall_clock=w.wall_clock+seconds
   end
   update(worlds,rounds or 8)
end
local function advance_game_only ( worlds, game_seconds, wall_seconds, rounds )
   for _index,w in ipairs(worlds) do
      w.clock=w.clock+game_seconds
      w.wall_clock=w.wall_clock+(wall_seconds or 0)
   end
   update(worlds,rounds or 8)
end
local function find ( world, name, faction_name )
   for _index,p in ipairs(world.pilots) do
      if not p.removed and p.pilot_name==name and (not faction_name or p.faction_name==faction_name) then return p end
   end
end

local host=new_world("John")
host.local_pilot:outfitAdd("The Bite")
host.local_pilot:outfitAdd("XL Hangar Bay")
assert(host.session.start{enabled=true,node_id="10",listen_port=62001,directory="",bootstrap={},recent={}})
assert(host.session.enter("Delta Polaris"))
local discovery_deadline=host.session.machine.deadline
assert(host.session.enter("Delta Polaris"))
assert(host.session.machine.deadline==discovery_deadline and host.session.machine.state=="discovering",
   "duplicate same-system entry restarted discovery")
assert(not host.speed_enabled,"P2P system entry did not disable the speed key")
local initial_claim_checks=host.c_calls.claim_test or 0
local initial_autonav_speed_calls=host.autonav_speed_calls
update({host},120)
assert((host.c_calls.claim_test or 0)==initial_claim_checks,
   "P2P rechecked local system claims every rendered frame")
assert(host.autonav_speed_calls==initial_autonav_speed_calls+120
      and host.autonav_speed==1,
   "P2P did not cap autonav speed on every rendered frame")
advance({host},2,4)
assert(host.autonav_speed_calls==initial_autonav_speed_calls+124
      and host.autonav_speed==1,
   "P2P stopped enforcing the autonav speed cap during discovery")
assert(host.session.machine.state=="host")
assert(host.local_pilot.effects["Multiplayer: Autonav Pending"],
   "solo-host autonav countdown was not shown")
advance({host},9,4)
assert(not host.speed_enabled,
   "solo host regained time compression before its ten-second grace period")
advance({host},1.1,4)
assert(host.speed_enabled,
   "solo host did not regain ordinary autonav time compression")
assert(host.autonav_speed==nil,
   "solo host retained the multiplayer autonav speed cap")
assert(not host.local_pilot.effects["Multiplayer: Autonav Pending"],
   "solo-host autonav countdown remained after autonav was restored")
host.c_calls={}
local solo_player_states=host.session.host.sent_types.player_state or 0
advance({host},60,12)
assert((host.c_calls.pilot_get or 0)==0,
   "solo host scanned the pilot inventory under time compression")
assert((host.session.host.sent_types.player_state or 0)==solo_player_states,
   "solo host published player state without a remote system member")
local npc=host:add_pilot("Koala","Empire","Host NPC",false)
local escort=host:add_pilot("Hyena","Player","Host Escort",true,"escort")
escort.pilot_id=777
escort:setLeader(host.local_pilot)

local guest=new_world("John")
guest.missing_outfits["XL Hangar Bay"]=true
-- A player endpoint in the directory field must behave like a bootstrap peer.
-- Settings accept the space separator required by Naev's text input and
-- canonicalize it before passing the endpoint to ENet.
assert(guest.session.start{enabled=true,node_id="20",listen_port=0,directory="127.0.0.1 62001",bootstrap={},recent={}})
assert(guest.session.settings.directory=="127.0.0.1:62001")
assert(guest.session.enter("Delta Polaris"))
assert(not guest.speed_enabled,"guest system entry did not disable the speed key")
update({host,guest},12)
advance({host,guest},11,16) -- reliable repair manifests

assert(host.session.machine.state=="host")
assert(guest.session.machine.state=="guest")
assert(not host.speed_enabled and not guest.speed_enabled,
   "joining participant did not immediately restore shared-session time controls")
assert(host.player_name=="John" and guest.player_name=="John")
assert(find(host,"John #2","P2P Players"),"host did not locally alias the guest")
for _entity_id,record in pairs(host.session.host_inventory) do
   assert(record.pilot_name~="John #2",
      "remote player proxy was inventoried as a host-owned ambient NPC")
end
local host_proxy=find(guest,"John #2","P2P Players")
assert(host_proxy,"guest did not locally alias the host")
assert(host_proxy.last_chat=="This is John, captain of John. Identify yourself."
      and host_proxy.chat_count==1,
   "host did not privately identify itself to the joining guest")
assert(host_proxy.slotted_outfits and host_proxy.slotted_outfits[1]=="The Bite",
   "The Bite was not installed in the remote player's matching ship slot")
assert(not host_proxy.slotted_outfits[2],
   "an outfit missing from the receiving client was installed")
assert(not guest.unknown_outfit_gets,
   "an outfit missing from the receiving client reached the warning getter")
local guest_proxy=find(host,"John #2","P2P Players")
assert(guest_proxy,"host did not retain the aliased guest proxy")
assert(guest_proxy.last_chat=="I am John, captain of John!" and guest_proxy.chat_count==1,
   "guest did not send exactly one reliable entry greeting to the host")
assert(#guest.comms==1 and guest.comms[1].name=="John"
      and guest.comms[1].text=="I am John, captain of John!",
   "host did not echo the entry greeting back to the sending client")
update({host,guest},20)
assert(guest_proxy.chat_count==1,"guest repeated its entry greeting without re-entering")
assert(not find(host,"John","P2P Players") and not find(guest,"John","P2P Players"))
assert(host_proxy.no_death and not host_proxy.invincible,
   "remote player proxy cannot receive local projectile impacts")
assert(not host_proxy.hostile,"remote player started hostile before taking hostile action")

host.session.input("accel",true)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==1,
   "manual player acceleration was not replicated")
host.session.input("accel",false)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==0,
   "manual acceleration release was not replicated")

host.autonaving=true
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==0,
   "coasting under autonav incorrectly replicated acceleration")
host.local_pilot.velocity=vector(100,0)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==1,
   "increasing speed under autonav did not replicate probable acceleration")
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==0,
   "steady speed under autonav did not release replicated acceleration")
host.local_pilot.velocity=vector(50,0)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_accel==0,
   "braking under autonav incorrectly replicated acceleration")
host.autonaving=false

guest.session.input("primary",true)
advance({host,guest},0.1,8)
assert(guest_proxy:memory().p2p_primary and not guest_proxy.hostile,
   "firing without targeting the local player incorrectly caused hostility")
guest.session.input("primary",false)
advance({host,guest},0.1,8)

-- P2P captures local inputs itself. Desired controls must survive until the
-- proxy AI consumes them, the remote proxy must target the local real player,
-- and only the disposable proxy may have its health repaired.
host.local_pilot:setTarget(guest_proxy)
host.local_pilot:setEnergy(63)
host.session.input("primary",true)
assert(host.unpauses>0,"P2P input did not keep the space simulation unpaused")
assert(guest_proxy.hostile,"firing at a neutral remote player did not make the target hostile")
assert(host.local_pilot.effects["Multiplayer: Aggression"],
   "local aggression did not show its peace countdown")
host_proxy:setHealth(12,7,3)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_primary,"primary fire input was not replicated")
assert(host_proxy.target_pilot==guest.local_pilot,"replicated fire target is not the local player")
assert(host_proxy.hostile,"firing proxy was not made locally damage-capable")
assert(guest.local_pilot.effects["Multiplayer: Aggression"],
   "replicated aggression did not show its peace countdown")
assert(host_proxy.energy_value==63,"remote player energy was not replicated")
assert(host_proxy.ammo_fills and host_proxy.ammo_fills>0,"remote proxy ammo was not maintained")
assert(host_proxy.armour==100 and host_proxy.shield==100 and host_proxy.stress==0,
   "disposable proxy health was not repaired")
assert(guest.local_pilot.armour==100 and guest.local_pilot.shield==100,
   "replicated player state wrote local-player health")
guest.local_pilot:setNoDeath(true)
guest.local_pilot:setHealth(44,22,6)
advance({host,guest},0.1,8)
assert(guest_proxy.armour==44 and guest_proxy.shield==22 and guest_proxy.stress==6,
   "guest self-authoritative health was not replicated to its host-side proxy")
assert(guest.local_pilot.armour==44 and guest.local_pilot.shield==22
      and guest.local_pilot.stress==6,
   "remote player state overwrote the real local player's health")
guest.local_pilot:setHealth(100,100,0)
advance({host,guest},0.1,8)
assert(guest_proxy.armour==100 and guest_proxy.shield==100 and guest_proxy.stress==0,
   "host-side proxy did not follow its owner's recovered health")
host.local_pilot.active_outfits[1].state="on"
advance({host,guest},0.1,8)
assert(host_proxy.last_outfit_toggle and host_proxy.last_outfit_toggle.name=="The Bite"
      and host_proxy.last_outfit_toggle.on,
   "The Bite was not activated by its actual replicated outfit slot")
host.local_pilot.active_outfits[1].state="off"
advance({host,guest},0.1,8)
assert(host_proxy.last_outfit_toggle and not host_proxy.last_outfit_toggle.on,
   "active outfit release was not replicated")
host.session.input("primary",false)
advance({host,guest},0.1,8)
assert(not host_proxy:memory().p2p_primary,"primary fire release was not replicated")
guest.local_pilot:setTarget(host_proxy)
host.session.input("primary",true)
guest.session.input("primary",true)
advance({host,guest},0.1,8)
host.session.input("primary",false)
guest.session.input("primary",false)
advance({host,guest},0.1,8)
for _second=1,19 do advance({host,guest},1,8) end
assert(guest_proxy.hostile and host_proxy.hostile,
   "mutual player hostility expired before twenty quiet seconds")
advance({host,guest},1.1,8)
assert(not guest_proxy.hostile and not host_proxy.hostile,
   "mutual player hostility did not reset after twenty quiet seconds: "
      ..tostring(guest_proxy.hostile).."/"..tostring(host_proxy.hostile)
      .." last="..tostring(host.session.players["20"].last_aggression)
      .." now="..tostring(host.clock))
assert(not host.local_pilot.effects["Multiplayer: Aggression"]
      and not guest.local_pilot.effects["Multiplayer: Aggression"],
   "aggression countdown remained after the final live timer expired")
assert(not host.speed_enabled and not guest.speed_enabled,
   "active multiplayer session incorrectly enabled time compression")

local npc_replica=find(guest,"Host NPC","Empire")
assert(npc_replica,"guest did not receive host NPC")
assert((host.session.host.sent_types.npc_manifest or 0)>0,
   "full NPC synchronization did not use a batched manifest")
assert(npc_replica.no_death,
   "host-authoritative NPC replica could be destroyed by guest-local damage")
local escort_replica=find(guest,"Host Escort","P2P Craft 10")
assert(escort_replica,"guest did not receive owner-authoritative craft")
assert(escort_replica.no_death,
   "owner-authoritative craft replica could be destroyed by guest-local damage")
local unchanged_health_sets=npc_replica.health_sets or 0
local unchanged_energy_sets=npc_replica.energy_sets or 0
local unchanged_target_sets=npc_replica.target_sets or 0
advance({host,guest},0.35,8)
assert((npc_replica.health_sets or 0)==unchanged_health_sets
      and (npc_replica.energy_sets or 0)==unchanged_energy_sets
      and (npc_replica.target_sets or 0)==unchanged_target_sets,
   "unchanged authoritative NPC state crossed the Lua/C setter boundary")
npc:setDisable()
advance({host,guest},0.35,8)
assert(npc_replica:disabled(),
   "authoritative NPC disable lifecycle was not replicated")
local disable_sets=npc_replica.disable_sets or 0
advance({host,guest},0.35,8)
assert((npc_replica.disable_sets or 0)==disable_sets,
   "unchanged disabled state repeatedly called setDisable")
assert(not escort_replica:withPlayer(),"remote host craft became guest-owned")
assert(escort_replica:ainame()=="escort" and escort_replica:leader()==host_proxy,
   "remote host craft did not retain escort AI and its network owner's leader")

-- A guest-launched fighter remains guest-authoritative. On the host it must
-- not enter the local Player faction, and its native escort AI must receive
-- commands from the guest proxy (the only leader that AI will accept).
local guest_fighter=guest:add_pilot("Lancelot","Player","Guest Fighter",true,"escort")
guest_fighter:setLeader(guest.local_pilot)
-- Pilot IDs are process-local and frequently collide across peers. The wire
-- entity namespace must keep these two different owners' craft distinct.
guest_fighter.pilot_id=escort.pilot_id
guest.session.last_craft=guest.clock
local guest_craft_states=guest.session.host.sent_types.craft_state or 0
advance({host,guest},0.9,12)
assert((guest.session.host.sent_types.craft_state or 0)==guest_craft_states,
   "owned craft state was published faster than 1 Hz")
advance({host,guest},0.11,12)
assert((guest.session.host.sent_types.craft_state or 0)>guest_craft_states,
   "owned craft state was not published at 1 Hz")
local guest_fighter_replica=find(host,"Guest Fighter","P2P Craft 20")
assert(guest_fighter_replica,"host did not receive the guest fighter")
assert(host.session.craft["20:"..escort.pilot_id]
      and guest.session.craft["10:"..escort.pilot_id],
   "same-numbered pilot IDs from different owners collided")
assert(not guest_fighter_replica:withPlayer(),"guest fighter was classified as host-owned")
assert(guest_fighter_replica:ainame()=="escort" and guest_fighter_replica:leader()==guest_proxy,
   "guest fighter replica has the wrong AI or leader")
assert(guest_fighter_replica.ai_setup_called,
   "guest fighter outfits were not registered with native escort AI")
guest.session.input("e_hold",true); update({host,guest},8)
assert(guest_fighter_replica.last_order
      and guest_fighter_replica.last_order.sender==guest_proxy
      and guest_fighter_replica.last_order.kind=="e_hold",
   "guest escort hold order was not applied by the host-side guest proxy")
guest.local_pilot:setTarget(host_proxy)
guest.session.input("e_attack",true); update({host,guest},8)
assert(guest_fighter_replica.last_order.kind=="e_attack"
      and guest_fighter_replica.last_order.data==host.local_pilot,
   "guest escort attack order did not resolve the host's real pilot")
assert(guest_fighter_replica.hostile,
   "guest fighter attacking the host remained collision-neutral")

-- A duplicate or relayed path must never make an owner instantiate replicas
-- of its own ship tree.
local host_side_guest_peer
for peer,meta in pairs(guest.session.peer_meta) do
   if meta.verified and meta.node=="10" then host_side_guest_peer=peer.remote_peer; break end
end
assert(host_side_guest_peer)
host_side_guest_peer:send(assert(wire_codec.encode{
   type="craft_manifest",node="20",system="Delta Polaris",owner="20",
   entity="20:999",seq=999,ship="Llama",name="Reflected Self",
}),0,"reliable")
guest.session.update()
assert(not guest.session.craft["20:999"],
   "reflected owned-craft manifest created a local self copy")

-- A receive flood must stay queued across rendered frames instead of making
-- one update drain the entire ENet host.
local host_to_guest
for peer,meta in pairs(host.session.peer_meta) do
   if meta.verified and meta.node=="20" then host_to_guest=peer; break end
end
assert(host_to_guest)
local ignored_punch=assert(wire_codec.encode{
   type="punch",node="10",system="Delta Polaris",peer="abcdef",
   endpoint="127.0.0.1:65500",
})
for _index=1,100 do host_to_guest:send(ignored_punch,0,"reliable") end
guest.session.update()
assert(#guest.session.host.events>=52,
   "one P2P update exceeded the 48-event ENet receive budget")
update({guest},8)
assert(#guest.session.host.events==0,
   "bounded ENet receive queue did not drain over later frames")

-- State for an unknown entity asks its authority for the one missing manifest.
local resync_requests=guest.session.host.sent_types.resync or 0
host.session.sequence=host.session.sequence+1
host_to_guest:send(assert(wire_codec.encode{
   type="craft_state",node="10",system="Delta Polaris",owner="10",
   seq=host.session.sequence,
   entities="10:missing,0,0,0,0,0,100,100,0,100,-,0",
}),0)
guest.session.update()
assert((guest.session.host.sent_types.resync or 0)==resync_requests+1,
   "unknown craft state did not request its missing manifest")
update({host,guest},8)
advance({host,guest},1.1,1)
resync_requests=guest.session.host.sent_types.resync or 0
host.session.sequence=host.session.sequence+1
host_to_guest:send(assert(wire_codec.encode{
   type="craft_state",node="10",system="Delta Polaris",owner="10",
   seq=host.session.sequence,
   entities="10:missing-a,0,0,0,0,0,100,100,0,100,-,0;"
      .."10:missing-b,0,0,0,0,0,100,100,0,100,-,0",
}),0)
guest.session.update()
assert((guest.session.host.sent_types.resync or 0)==resync_requests+1,
   "one missing-state batch emitted more than one authority resync")
update({host,guest},8)

-- A targeted resync for a known entity must use the authoritative inventory
-- index instead of rescanning every pilot.
host.c_calls={}
guest.session.sequence=guest.session.sequence+1
host_to_guest.remote_peer:send(assert(wire_codec.encode{
   type="resync",node="20",system="Delta Polaris",seq=guest.session.sequence,
   scope="craft",owner="10",entity="10:"..escort.pilot_id,
}),0,"reliable")
host.session.update()
assert((host.c_calls.pilot_get or 0)==0,
   "known targeted resync performed a full host pilot inventory scan")
update({host,guest},8)

-- Static manifest fields are collected once when craft appear. Ordinary state
-- ticks must not cross into ship/loadout/name/faction/leader getters, and the
-- old ten-second full-manifest hammer must stay gone.
local carrier_fighters={}
for index=1,20 do
   local fighter=host:add_pilot("Lancelot","Player","Carrier Fighter "..index,true,"escort")
   fighter:setLeader(host.local_pilot)
   carrier_fighters[#carrier_fighters+1]=fighter
end
advance({host,guest},1.1,24)
local remote_craft_count=0
for _entity_id in pairs(guest.session.craft) do remote_craft_count=remote_craft_count+1 end
assert(remote_craft_count==21,
   "state/manifest separation dropped remote carrier craft")
local craft_manifests=host.session.host.sent_types.craft_manifest or 0
host.c_calls={}
host.session.last_npc=host.wall_clock+20 -- isolate owned-craft collection from ambient inventory classification
advance({host,guest},11,24)
for _index,name in ipairs({"outfitsList","outfits","ship","name","faction","leader"}) do
   assert((host.c_calls[name] or 0)==0,
      "craft state collection called static manifest getter "..name)
end
assert((host.session.host.sent_types.craft_manifest or 0)==craft_manifests,
   "unchanged craft emitted periodic full manifests")
for _index,fighter in ipairs(carrier_fighters) do fighter:rm() end
advance({host,guest},1.1,24)
remote_craft_count=0
for _entity_id in pairs(guest.session.craft) do remote_craft_count=remote_craft_count+1 end
assert(remote_craft_count==1,
   "reliable carrier removals did not preserve only the original escort")

-- A third peer knows only the guest and must discover the actual host through it.
local third=new_world("Jane")
local guest_bootstrap=guest.session.endpoint:gsub(":", " ")
assert(third.session.start{enabled=true,node_id="30",listen_port=0,directory="",bootstrap={guest_bootstrap},recent={}})
assert(third.session.settings.bootstrap[1]==guest.session.endpoint)
assert(third.session.enter("Delta Polaris"))
update({host,guest,third},20)
advance({host,guest,third},11,20)
assert(third.session.machine.state=="guest" and third.session.machine.host=="10",
   "peer did not discover host through an intermediate guest")
assert(find(third,"John","P2P Players") and find(third,"John #2","P2P Players"),
   "third peer did not uniquely alias duplicate remote names")
local third_host_proxy=third.session.players["10"].pilot
assert(third_host_proxy.last_chat=="This is John, captain of John. Identify yourself."
      and third_host_proxy.chat_count==1,
   "host did not privately identify itself to a peer discovered through a guest")

-- A raced or otherwise missed player manifest must not leave a permanent
-- invisible participant. State reaches both the host and other guests, which
-- request a throttled reliable manifest repair through the normal relay.
guest_proxy:rm()
host.session.players["20"]=nil
local guest_proxy_on_third=third.session.players["20"].pilot
guest_proxy_on_third:rm()
third.session.players["20"]=nil
local guest_player_manifests=guest.session.host.sent_types.player_manifest or 0
local third_player_manifests=third.session.host.sent_types.player_manifest or 0
guest.session.last_player=guest.wall_clock+20 -- isolate chat-triggered repair
assert(guest.session.send_chat("repair my manifest"))
update({host,guest,third},24)
assert(host.session.players["20"] and host.session.players["20"].pilot:exists(),
   "host did not repair a missing remote player proxy")
assert(third.session.players["20"] and third.session.players["20"].pilot:exists(),
   "guest did not repair a missing relayed player proxy")
assert((guest.session.host.sent_types.player_manifest or 0)>guest_player_manifests
      and (third.session.host.sent_types.player_manifest or 0)==third_player_manifests,
   "targeted player repair did not isolate the requested participant")
guest_proxy=host.session.players["20"].pilot
guest.session.last_player=guest.wall_clock
assert(guest.session.send_chat("manifest repaired"))
update({host,guest,third},8)
assert(guest_proxy.last_chat=="manifest repaired"
      and third.session.players["20"].pilot.last_chat=="manifest repaired",
   "chat remained detached after repairing its player proxy")

npc:setPos(vector(500,0))
escort:setPos(vector(500,0))
local npc_velocity_sets=npc_replica.velocity_sets or 0
local escort_velocity_sets=escort_replica.velocity_sets or 0
for _index,w in ipairs({host,guest,third}) do
   w.clock=w.clock+1
   w.wall_clock=w.wall_clock+1
end
update({host,guest,third},7)
guest.session.update(0.1)
local npc_motion=guest.session.npcs["10:"..npc.pilot_id].motion
guest.session.npcs["10:"..npc.pilot_id].motion=nil
for _index=1,60 do guest.session.update(1/60) end
guest.session.npcs["10:"..npc.pilot_id].motion=npc_motion
local npc_x=select(1,npc_replica:pos():get())
local escort_x=select(1,escort_replica:pos():get())
local npc_vx=select(1,npc_replica:vel():get())
local escort_vx=select(1,escort_replica:vel():get())
assert(npc_x==0 and (npc_replica.position_sets or 0)==0,
   "NPC reconciliation teleported its replica")
assert(escort_x==0 and (escort_replica.position_sets or 0)==0,
   "owned-craft reconciliation teleported its replica")
assert(npc_vx>0 and npc_vx<=240,"NPC correction velocity was not acceleration-capped")
assert(escort_vx>0 and escort_vx<=240,
   "owned-craft correction velocity was not acceleration-capped: "..tostring(escort_vx))
assert((npc_replica.velocity_sets or 0)-npc_velocity_sets<=4,
   "NPC reconciliation exceeded its 10 Hz work budget: "
      ..tostring((npc_replica.velocity_sets or 0)-npc_velocity_sets))
assert((escort_replica.velocity_sets or 0)-escort_velocity_sets<=2,
   "owned-craft reconciliation exceeded its 1 Hz work budget")
npc:setHealth(42,17,3); npc:setEnergy(51)
advance({host,guest,third},0.35,8)
assert(npc_replica.armour==42 and npc_replica.shield==17 and npc_replica.stress==3 and npc_replica.energy_value==51)

local removed_npc=host:add_pilot("Rhino","Empire","Removed NPC",false)
advance({host,guest,third},0.35,8)
local removed_replica=find(guest,"Removed NPC","Empire")
assert(removed_replica,"guest did not receive incremental NPC addition")
removed_npc:rm(); advance({host,guest,third},0.35,8)
assert(not removed_replica:exists(),"guest ignored authoritative NPC removal")

host.local_pilot:setPos(vector(500,0))
local player_velocity_sets=host_proxy.velocity_sets or 0
for _index,w in ipairs({host,guest,third}) do
   w.clock=w.clock+0.1
   w.wall_clock=w.wall_clock+0.1
end
update({host,guest,third},6)
local proxy_x=select(1,host_proxy:pos():get())
local proxy_vx=select(1,host_proxy:vel():get())
assert(proxy_x==0 and (host_proxy.position_sets or 0)==0,
   "player reconciliation teleported its proxy")
assert(proxy_vx>0 and proxy_vx<=360,
   "player correction velocity exceeded its acceleration cap")
assert((host_proxy.velocity_sets or 0)-player_velocity_sets<=3,
   "player reconciliation exceeded its 30 Hz work budget")
assert(guest.local_pilot.armour==100 and guest.local_pilot.shield==100,"local player health was overwritten")
local host_hails,guest_hails,third_hails=host.hail_sounds or 0,guest.hail_sounds or 0,third.hail_sounds or 0
assert(host.session.send_chat("headless hello")); update({host,guest,third},8)
assert(host_proxy.last_chat=="headless hello","reliable chat was not delivered")
assert(host.comms[#host.comms].name=="John" and host.comms[#host.comms].text=="headless hello",
   "chat sender did not immediately display its own message")
assert(host.hail_sounds==host_hails+1 and guest.hail_sounds==guest_hails+1
      and third.hail_sounds==third_hails+1,
   "chat broadcast did not play exactly one hail sound per participant")
local guest_comm_count=#guest.comms
guest_hails=guest.hail_sounds
assert(guest.session.send_chat("guest hello")); update({host,guest,third},8)
assert(#guest.comms==guest_comm_count+1 and guest.comms[#guest.comms].text=="guest hello",
   "relayed chat duplicated or omitted the guest's immediate local display")
assert(guest.hail_sounds==guest_hails+1,
   "relayed chat duplicated or omitted the sender's hail sound")

-- The local aggression effect represents the latest live deadline, not the
-- first hostile peer to become peaceful.
local third_proxy_on_host=host.session.players["30"].pilot
host.local_pilot:setTarget(guest_proxy)
host.session.input("primary",true); advance({host,guest,third},0.1,8)
host.session.input("primary",false); advance({host,guest,third},5,8)
host.local_pilot:setTarget(third_proxy_on_host)
host.session.input("primary",true); advance({host,guest,third},0.1,8)
host.session.input("primary",false)
for _second=1,15 do advance({host,guest,third},1,8) end
assert(not guest_proxy.hostile and third_proxy_on_host.hostile,
   "staggered aggression timers did not expire independently")
assert(host.local_pilot.effects["Multiplayer: Aggression"],
   "aggression countdown cleared before the final live timer")
advance({host,guest,third},5,8)
assert(not third_proxy_on_host.hostile
      and not host.local_pilot.effects["Multiplayer: Aggression"],
   "aggression countdown did not clear with the final live timer")

-- An ordinary guest departure is observed by the host and relayed to every
-- other guest, with one notification and sound on each observer.
local fourth=new_world("Alex")
assert(fourth.session.start{enabled=true,node_id="35",listen_port=0,directory="",
   bootstrap={guest_bootstrap},recent={}})
assert(fourth.session.enter("Delta Polaris"))
update({host,guest,third,fourth},24)
assert(fourth.session.machine.state=="guest" and fourth.session.machine.host=="10")
local host_disconnects=host.disconnect_sounds or 0
local guest_disconnects=guest.disconnect_sounds or 0
local third_disconnects=third.disconnect_sounds or 0
local fourth_on_host=host.session.players["35"].pilot
local fourth_on_guest=guest.session.players["35"].pilot
local fourth_on_third=third.session.players["35"].pilot
fourth.session.stop(); update({host,guest,third},16)
assert(host.disconnect_sounds==host_disconnects+1
      and guest.disconnect_sounds==guest_disconnects+1
      and third.disconnect_sounds==third_disconnects+1,
   "guest departure did not notify the host and every other guest exactly once")
assert(fourth_on_host.last_chat=="Disconnected."
      and fourth_on_guest.last_chat=="Disconnected."
      and fourth_on_third.last_chat=="Disconnected.",
   "guest departure communication did not come from the departed proxies")
assert(fourth_on_host:exists() and fourth_on_host:disabled()
      and fourth_on_guest:exists() and fourth_on_guest:disabled()
      and fourth_on_third:exists() and fourth_on_third:disabled(),
   "stationary departed guest proxies were not retained and disabled")

-- A returning participant replaces its stale proxy. Disabled copies visibly
-- explode; copies already committed to landing or jumping may simply leave.
assert(fourth.session.start{enabled=true,node_id="35",listen_port=0,directory="",
   bootstrap={guest_bootstrap},recent={}})
assert(fourth.session.enter("Delta Polaris"))
update({host,guest,third,fourth},24)
assert(fourth_on_host.exploded and not fourth_on_host:exists(),
   "disabled departure did not explode when its participant rejoined")
assert(host.session.players["35"].pilot~=fourth_on_host,
   "rejoining participant did not receive a fresh remote proxy")
fourth.session.stop(); update({host,guest,third},16)

guest_disconnects,third_disconnects=guest.disconnect_sounds or 0,third.disconnect_sounds or 0
local host_on_guest=guest.session.players["10"].pilot
local host_on_third=third.session.players["10"].pilot
host_on_guest:setVel(vector(100,0))
host_on_third:setVel(vector(100,0))
local guest_nearest_spob=departure_target(500,0,true)
guest.spobs={departure_target(1000,0,true),guest_nearest_spob}
local third_nearest_jump=departure_target(400,0,false)
third.jumps={departure_target(900,0,false),third_nearest_jump}
host.session.stop(); update({guest,third},16)
assert(host.speed_enabled,"stopping P2P did not restore the speed key")
assert(guest.disconnect_sounds==guest_disconnects+1
      and third.disconnect_sounds==third_disconnects+1,
   "host departure did not play one disconnect sound for every guest")
assert(host_on_guest.last_chat=="Disconnected."
      and host_on_third.last_chat=="Disconnected.",
   "host departure communication did not come from the departed host proxies")
assert(host_on_guest:exists() and host_on_guest.task
      and host_on_guest.task.kind=="land"
      and host_on_guest.task.target==guest_nearest_spob,
   "moving departed host did not land at the nearest plausible spob")
assert(not host_on_guest.no_death and not host_on_third.no_death,
   "disconnected player proxies retained connected-player no-death protection")
assert(host_on_third:exists() and host_on_third.task
      and host_on_third.task.kind=="hyperspace"
      and host_on_third.task.target==third_nearest_jump,
   "moving departed host did not jump through the nearest plausible gate")
for _entity_id,record in pairs(guest.session.host_inventory) do
   assert(record.pilot_name~=host_on_guest.pilot_name,
      "retained departing proxy became a host-owned ambient NPC")
end
assert(guest.session.machine.state=="host","guest did not take over after host loss")
assert(third.session.machine.state=="guest" and third.session.machine.host=="20",
   "third peer did not follow replacement-host election")
assert(npc_replica:exists(),"host NPC replica was removed during takeover")
assert(npc_replica.armour==42,"retained NPC state changed during takeover")
assert(not npc_replica.no_death,
   "promoted host NPC retained replica-only no-death protection")
assert(not escort_replica:exists(),"departed owner's craft replica was retained")

third_disconnects=third.disconnect_sounds
local guest_on_third=third.session.players["20"].pilot
guest.session.stop(); update({third},8)
assert(third.disconnect_sounds==third_disconnects+1,
   "replacement-host departure did not play one disconnect sound for its guest")
assert(guest_on_third.last_chat=="Disconnected.",
   "replacement-host departure communication did not come from its proxy")
third.session.stop()
assert(guest.speed_enabled and third.speed_enabled,"leaving P2P did not restore speed controls")

-- UDP loss does not necessarily produce an immediate ENet disconnect event.
-- Player-state liveness must eventually remove a one-sided ghost even while
-- the underlying peer object remains connected.
local stale_host=new_world("Liveness Host")
assert(stale_host.session.start{enabled=true,node_id="38",listen_port=62038,
   directory="",bootstrap={},recent={}})
assert(stale_host.session.enter("Delta Polaris")); advance({stale_host},2,4)
local stale_guest=new_world("Liveness Guest")
assert(stale_guest.session.start{enabled=true,node_id="39",listen_port=0,
   directory="",bootstrap={"127.0.0.1:62038"},recent={}})
assert(stale_guest.session.enter("Delta Polaris"))
update({stale_host,stale_guest},16)
stale_host.session.update() -- drain the guest's final queued state
local stale_proxy=stale_host.session.players["39"].pilot
stale_host.clock=stale_host.clock+13
stale_host.wall_clock=stale_host.wall_clock+13
stale_host.session.update()
assert(not stale_host.session.players["39"]
      and stale_host.session.departures["39"].pilot==stale_proxy
      and stale_proxy:disabled(),
   "silent participant timeout left a one-sided player ghost")
stale_guest.session.stop()
stale_host.session.stop()

-- A local Naev system claim protects mission/event state. Such a player must
-- ignore a reachable host, and a guest that gains a local claim must leave the
-- shared population and restart discovery before claiming itself.
local claim_host=new_world("Claim Host")
assert(claim_host.session.start{enabled=true,node_id="41",listen_port=61401,
   directory="",bootstrap={},recent={}})
assert(claim_host.session.enter("Claimed System")); advance({claim_host},2,4)
local claimed_player=new_world("Claimed Player")
claimed_player.claim_available=false
assert(claimed_player.session.start{enabled=true,node_id="42",listen_port=0,
   directory="",bootstrap={"127.0.0.1:61401"},recent={}})
assert(claimed_player.session.enter("Claimed System"))
update({claim_host,claimed_player},16)
assert(claimed_player.session.machine.state=="discovering",
   "locally claimed player accepted a remote host claim or hint")
advance({claim_host,claimed_player},2,16)
assert(claimed_player.session.machine.state=="host",
   "locally claimed player did not become host")
advance({claim_host,claimed_player},11,16)
assert(claimed_player.session.machine.state=="host",
   "locally claimed host accepted a refreshed remote host claim")
claimed_player.session.stop(); claim_host.session.stop()

local transition_host=new_world("Transition Host")
assert(transition_host.session.start{enabled=true,node_id="43",listen_port=61402,
   directory="",bootstrap={},recent={}})
assert(transition_host.session.enter("Transition System")); advance({transition_host},2,4)
local transition_guest=new_world("Transition Guest")
assert(transition_guest.session.start{enabled=true,node_id="44",listen_port=0,
   directory="",bootstrap={"127.0.0.1:61402"},recent={}})
assert(transition_guest.session.enter("Transition System"))
update({transition_host,transition_guest},16)
assert(transition_guest.session.machine.state=="guest")
transition_guest.claim_available=false
transition_host.clock=transition_host.clock+1.1
transition_host.wall_clock=transition_host.wall_clock+1.1
transition_guest.clock=transition_guest.clock+1.1
transition_guest.wall_clock=transition_guest.wall_clock+1.1
transition_guest.session.update()
assert(transition_guest.session.machine.state=="discovering"
      and next(transition_guest.session.players)==nil
      and transition_guest.spawn,
   "guest gaining a local claim did not leave and restart discovery")
advance({transition_host,transition_guest},2,16)
assert(transition_guest.session.machine.state=="host",
   "guest gaining a local claim did not become host")
transition_guest.session.stop(); transition_host.session.stop()

-- Newly observed players use native Naev arrival states when their first
-- authoritative position is close to a landable spob or jump point.
local arrival_host=new_world("Arrival Host")
local arrival_spob=departure_target(500,0,true)
arrival_host.spobs={arrival_spob}
assert(arrival_host.session.start{enabled=true,node_id="45",listen_port=61403,
   directory="",bootstrap={},recent={}})
assert(arrival_host.session.enter("Arrival System")); advance({arrival_host},2,4)
local arrival_guest=new_world("Arrival Guest")
local arrival_jump=departure_target(0,0,false)
arrival_guest.jumps={arrival_jump}
arrival_guest.local_pilot.position=vector(500,0)
assert(arrival_guest.session.start{enabled=true,node_id="46",listen_port=0,
   directory="",bootstrap={"127.0.0.1:61403"},recent={}})
assert(arrival_guest.session.enter("Arrival System"))
update({arrival_host,arrival_guest},16)
assert(arrival_host.session.players["46"].pilot.spawn_origin==arrival_spob,
   "player arriving near a landable spob did not take off from it")
assert(arrival_guest.session.players["45"].pilot.spawn_origin==arrival_jump,
   "player arriving near a jump point did not jump in through it")
arrival_guest.session.stop(); arrival_host.session.stop()

-- Listening on the configured loopback directory port must not dial self.
local selfloop=new_world("Loopback")
assert(selfloop.session.start{enabled=true,node_id="40",listen_port=60939,
   directory="127.0.0.1:60939",bootstrap={},recent={}})
assert(next(selfloop.session.peers)==nil,"local directory endpoint created a self connection")
assert(selfloop.session.enter("Delta Polaris")); advance({selfloop},2,4)
assert(selfloop.session.machine.state=="host","self-loop guard prevented local hosting")
selfloop.session.stop()

-- Non-loopback aliases can evade endpoint comparison, so hello must also
-- reject a connection that reflects the local persistent node ID.
local reflected_a=new_world("Reflected")
local reflected_b=new_world("Reflected")
assert(reflected_a.session.start{enabled=true,node_id="50",listen_port=61001,directory="",bootstrap={},recent={}})
assert(reflected_b.session.start{enabled=true,node_id="50",listen_port=61002,
   directory="127.0.0.1:61001",bootstrap={},recent={}})
update({reflected_a,reflected_b},12)
assert(next(reflected_a.session.peers)==nil and next(reflected_b.session.peers)==nil,
   "reflected node identity was not disconnected")
reflected_a.session.stop(); reflected_b.session.stop()

-- Configured directory/bootstrap endpoints are retried after a dropped ENet
-- connection, and the reconnect resolves the temporary split claim.
local reconnect_host=new_world("Reconnect Host")
local reconnect_guest=new_world("Reconnect Guest")
assert(reconnect_host.session.start{enabled=true,node_id="60",listen_port=61201,directory="",bootstrap={},recent={}})
assert(reconnect_host.session.enter("Arandon")); advance({reconnect_host},2,4)
assert(reconnect_guest.session.start{enabled=true,node_id="70",listen_port=0,
   directory="127.0.0.1:61201",bootstrap={},recent={}})
assert(reconnect_guest.session.enter("Arandon")); update({reconnect_host,reconnect_guest},16)
assert(reconnect_guest.session.machine.state=="guest")
local severed
for peer in pairs(reconnect_guest.session.peers) do severed=peer; break end
assert(severed); severed:disconnect_now(); update({reconnect_host,reconnect_guest},12)
advance_game_only({reconnect_host,reconnect_guest},60,0.1,12)
assert(next(reconnect_guest.session.peers)==nil,
   "time compression accelerated configured endpoint retries")
advance({reconnect_host,reconnect_guest},6,32)
assert(reconnect_guest.session.machine.state=="guest" and reconnect_guest.session.machine.host=="60",
   "configured endpoint did not reconnect and resolve its temporary claim")
reconnect_host.session.stop(); reconnect_guest.session.stop()

-- A verified directory can introduce two otherwise unconfigured players.
-- Both use the same ENet host/socket for the directory and direct gameplay,
-- which is the invariant required for the public NAT mapping to be useful.
local directory_port=61301
local fake_directory=setmetatable({events={},address="0.0.0.0:"..directory_port},host_mt)
network.hosts[directory_port]=fake_directory
local punch_host=new_world("Punch Host")
local punch_guest=new_world("Punch Guest")
assert(punch_host.session.start{enabled=true,node_id="80",listen_port=61302,
   directory="",bootstrap={},recent={}})
assert(punch_host.session.enter("Gamma Polaris"))
assert(punch_guest.session.start{enabled=true,node_id="90",listen_port=0,
   directory="127.0.0.1:"..directory_port,bootstrap={},recent={}})
assert(punch_guest.session.enter("Gamma Polaris"))
update({punch_guest},4)
local directory_peer
local directory_event=fake_directory:service(0)
while directory_event do
   if directory_event.type=="connect" then directory_peer=directory_event.peer end
   directory_event=fake_directory:service(0)
end
assert(directory_peer,"guest did not connect to fake directory")
directory_peer:send(assert(wire_codec.encode{
   type="hello",node="d1",cap="directory",features="activity"}),0,"reliable")
update({punch_guest},4)
assert(not punch_guest.session.machine.members.d1,
   "directory-only node entered the gameplay election membership")
local activity_query
directory_event=fake_directory:service(0)
while directory_event do
   if directory_event.type=="receive" then
      local message=assert(wire_codec.decode(directory_event.data))
      if message.type=="activity_query" then activity_query=message end
   end
   directory_event=fake_directory:service(0)
end
assert(activity_query and activity_query.node=="90",
   "activity-capable directory was not queried")
directory_peer:send(assert(wire_codec.encode{
   type="activity",node="d1",entries=
      wire_codec.escape("Gamma Polaris")..",1,0;"
      ..wire_codec.escape("Old Haven")..",0,120"}),0,"reliable")
update({punch_guest},4)
local recent=punch_guest.session.recent_activity()
assert(#recent==2 and recent[1].system=="Gamma Polaris" and recent[1].active
      and recent[2].system=="Old Haven" and not recent[2].active
      and recent[2].age>=120,
   "directory activity response was not cached")
assert(punch_guest.session.identities:add("80","Stale Relay Name"),
   "failed to establish relayed identity test fixture")
directory_peer:send(assert(wire_codec.encode{
   type="punch",node="d1",system="Gamma Polaris",peer="80",
   endpoint="127.0.0.1:61302"}),0,"reliable")
-- A directory can provide observed and advertised candidates for the same
-- node. Both may connect, but only one gameplay peer may survive verification.
network.hosts[61303]=network.hosts[61302]
directory_peer:send(assert(wire_codec.encode{
   type="punch",node="d1",system="Gamma Polaris",peer="80",
   endpoint="127.0.0.1:61303"}),0,"reliable")
update({punch_host,punch_guest},16)
local host_verified,guest_verified=0,0
for _peer,meta in pairs(punch_host.session.peer_meta) do
   if meta.verified and meta.node=="90" then host_verified=host_verified+1 end
end
for _peer,meta in pairs(punch_guest.session.peer_meta) do
   if meta.verified and meta.node=="80" then guest_verified=guest_verified+1 end
end
assert(host_verified==1 and guest_verified==1,
   "directory candidates did not converge on one verified player connection")
assert(punch_guest.session.identities:raw_name("80")=="Punch Host",
   "direct hello did not refresh a relay-only player identity")
punch_guest.wall_clock=punch_guest.wall_clock+61
recent=punch_guest.session.recent_activity()
assert(#recent==2 and not recent[1].active and recent[1].age>=61,
   "stale directory snapshot remained marked active")
punch_guest.wall_clock=punch_guest.wall_clock+840
assert(#punch_guest.session.recent_activity()==0,
   "expired directory activity remained cached")
punch_host.session.stop(); punch_guest.session.stop()
print("ok - three-peer session integration")
