package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local wire_codec=require "multiplayer.p2p.codec"

local network={hosts={},next_port=63000}
local peer_mt={}
peer_mt.__index=peer_mt
function peer_mt:send ( data, _channel, _flag )
   if self.closed then return end
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
      local host=setmetatable({events={},address="0.0.0.0:"..port},host_mt)
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
   return {nameRaw=function() return name end}
end

local function new_world ( player_name )
   local world={clock=0,pilots={},next_id=1,spawn=true,player_name=player_name,
      speed_enabled=true,autonav_resets=0,unpauses=0,comms={}}
   local pilot_methods={}
   pilot_methods.__index=pilot_methods
   function pilot_methods:exists () return not self.removed end
   function pilot_methods:rm () self.removed=true end
   function pilot_methods:name () return self.pilot_name end
   function pilot_methods:ship () return resource(self.ship_name) end
   function pilot_methods:faction () return resource(self.faction_name) end
   function pilot_methods:outfitsList ()
      local list={}
      for _index,name in ipairs(self.outfit_names) do list[#list+1]=resource(name) end
      return list
   end
   function pilot_methods:outfits ()
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
   function pilot_methods:id () return self.pilot_id end
   function pilot_methods:withPlayer ()
      return self.owned or self.faction_name=="Player" or self.leader_pilot==world.local_pilot
   end
   function pilot_methods:leader () return self.leader_pilot end
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
   function pilot_methods:setTarget (v) self.target_pilot=v end
   function pilot_methods:setHealth (a,s,t) self.armour=a; self.shield=s; self.stress=t end
   function pilot_methods:setEnergy (v) self.energy_value=v end
   function pilot_methods:setInvincible (v) self.invincible=v end
   function pilot_methods:setNoDeath (v) self.no_death=v end
   function pilot_methods:setHostile (v) self.hostile=v==nil or v end
   function pilot_methods:rename (v) self.pilot_name=v end
   function pilot_methods:fillAmmo () self.ammo_fills=(self.ammo_fills or 0)+1 end
   function pilot_methods:outfitAdd (name)
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
   world.cache={}
   env.naev={ticksGame=function() return world.clock end,cache=function() return world.cache end,
      keyEnable=function(key,enabled) assert(key=="speed"); world.speed_enabled=enabled end,
      unpause=function() world.unpauses=world.unpauses+1 end}
   env.rnd={rnd=function(a) return a or 1 end}
   env.vec2={new=vector}
   env.player={name=function() return world.player_name end,pilot=function() return world.local_pilot end,
      isLanded=function() return false end,
      autonavReset=function() world.autonav_resets=world.autonav_resets+1 end}
   env.ship={get=function(name) assert(type(name)=="string" and name~=""); return resource(name) end}
   env.outfit={get=function(name) return resource(name) end}
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
      get=function() local out={}; for _index,p in ipairs(world.pilots) do if not p.removed then out[#out+1]=p end end; return out end,
      add=function(ship_name,fac,pos,name,params)
         local faction_name=type(fac)=="string" and fac or fac:nameRaw()
         local p=world:add_pilot(ship_name,faction_name,name,false,params and params.ai)
         p.position=pos; return p
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
   for _index,w in ipairs(worlds) do w.clock=w.clock+seconds end
   update(worlds,rounds or 8)
end
local function find ( world, name, faction_name )
   for _index,p in ipairs(world.pilots) do
      if not p.removed and p.pilot_name==name and (not faction_name or p.faction_name==faction_name) then return p end
   end
end

local host=new_world("John")
host.local_pilot:outfitAdd("The Bite")
assert(host.session.start{enabled=true,node_id="10",listen_port=62001,directory="",bootstrap={},recent={}})
assert(host.session.enter("Delta Polaris"))
local discovery_deadline=host.session.machine.deadline
assert(host.session.enter("Delta Polaris"))
assert(host.session.machine.deadline==discovery_deadline and host.session.machine.state=="discovering",
   "duplicate same-system entry restarted discovery")
assert(not host.speed_enabled,"P2P system entry did not disable the speed key")
advance({host},2,4)
assert(host.autonav_resets>1,"P2P updates did not continually cancel autonav")
assert(host.session.machine.state=="host")
local npc=host:add_pilot("Koala","Empire","Host NPC",false)
local escort=host:add_pilot("Hyena","Player","Host Escort",true,"escort")
escort:setLeader(host.local_pilot)

local guest=new_world("John")
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
assert(host.player_name=="John" and guest.player_name=="John")
assert(find(host,"John #2","P2P Players"),"host did not locally alias the guest")
local host_proxy=find(guest,"John #2","P2P Players")
assert(host_proxy,"guest did not locally alias the host")
assert(host_proxy.slotted_outfits and host_proxy.slotted_outfits[1]=="The Bite",
   "The Bite was not installed in the remote player's matching ship slot")
local guest_proxy=find(host,"John #2","P2P Players")
assert(guest_proxy,"host did not retain the aliased guest proxy")
assert(guest_proxy.last_chat=="Hi, I'm John!" and guest_proxy.chat_count==1,
   "guest did not send exactly one reliable entry greeting to the host")
assert(#guest.comms==1 and guest.comms[1].name=="John"
      and guest.comms[1].text=="Hi, I'm John!",
   "host did not echo the entry greeting back to the sending client")
update({host,guest},20)
assert(guest_proxy.chat_count==1,"guest repeated its entry greeting without re-entering")
assert(not find(host,"John","P2P Players") and not find(guest,"John","P2P Players"))
assert(host_proxy.no_death and not host_proxy.invincible,
   "remote player proxy cannot receive local projectile impacts")
assert(not host_proxy.hostile,"remote player started hostile before taking hostile action")
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
host_proxy:setHealth(12,7,3)
advance({host,guest},0.1,8)
assert(host_proxy:memory().p2p_primary,"primary fire input was not replicated")
assert(host_proxy.target_pilot==guest.local_pilot,"replicated fire target is not the local player")
assert(host_proxy.hostile,"firing proxy was not made locally damage-capable")
assert(host_proxy.energy_value==63,"remote player energy was not replicated")
assert(host_proxy.ammo_fills and host_proxy.ammo_fills>0,"remote proxy ammo was not maintained")
assert(host_proxy.armour==100 and host_proxy.shield==100 and host_proxy.stress==0,
   "disposable proxy health was not repaired")
assert(guest.local_pilot.armour==100 and guest.local_pilot.shield==100,
   "replicated player state wrote local-player health")
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

local npc_replica=find(guest,"Host NPC","Empire")
assert(npc_replica,"guest did not receive host NPC")
local escort_replica=find(guest,"Host Escort","P2P Craft 10")
assert(escort_replica,"guest did not receive owner-authoritative craft")
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
advance({host,guest},0.25,12)
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
npc:setPos(vector(500,0))
escort:setPos(vector(500,0))
local npc_velocity_sets=npc_replica.velocity_sets or 0
local escort_velocity_sets=escort_replica.velocity_sets or 0
for _index,w in ipairs({host,guest,third}) do w.clock=w.clock+0.25 end
update({host,guest,third},7)
local npc_x=select(1,npc_replica:pos():get())
local escort_x=select(1,escort_replica:pos():get())
local npc_vx=select(1,npc_replica:vel():get())
local escort_vx=select(1,escort_replica:vel():get())
assert(npc_x==0 and (npc_replica.position_sets or 0)==0,
   "NPC reconciliation teleported its replica")
assert(escort_x==0 and (escort_replica.position_sets or 0)==0,
   "owned-craft reconciliation teleported its replica")
assert(npc_vx>0 and npc_vx<=120,"NPC correction velocity was not acceleration-capped")
assert(escort_vx>0 and escort_vx<=160,"owned-craft correction velocity was not acceleration-capped")
assert((npc_replica.velocity_sets or 0)-npc_velocity_sets<=2,
   "NPC reconciliation exceeded its 10 Hz work budget")
assert((escort_replica.velocity_sets or 0)-escort_velocity_sets<=2,
   "owned-craft reconciliation exceeded its 15 Hz work budget")
npc:setHealth(42,17,3); npc:setEnergy(51)
advance({host,guest,third},0.25,8)
assert(npc_replica.armour==42 and npc_replica.shield==17 and npc_replica.stress==3 and npc_replica.energy_value==51)

local removed_npc=host:add_pilot("Rhino","Empire","Removed NPC",false)
advance({host,guest,third},0.25,8)
local removed_replica=find(guest,"Removed NPC","Empire")
assert(removed_replica,"guest did not receive incremental NPC addition")
removed_npc:rm(); advance({host,guest,third},0.25,8)
assert(not removed_replica:exists(),"guest ignored authoritative NPC removal")

host.local_pilot:setPos(vector(500,0))
local player_velocity_sets=host_proxy.velocity_sets or 0
for _index,w in ipairs({host,guest,third}) do w.clock=w.clock+0.1 end
update({host,guest,third},6)
local proxy_x=select(1,host_proxy:pos():get())
local proxy_vx=select(1,host_proxy:vel():get())
assert(proxy_x==0 and (host_proxy.position_sets or 0)==0,
   "player reconciliation teleported its proxy")
assert(proxy_vx>0 and proxy_vx<=240,
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
fourth.session.stop(); update({host,guest,third},16)
assert(host.disconnect_sounds==host_disconnects+1
      and guest.disconnect_sounds==guest_disconnects+1
      and third.disconnect_sounds==third_disconnects+1,
   "guest departure did not notify the host and every other guest exactly once")
assert(host.comms[#host.comms].text=="Disconnected."
      and guest.comms[#guest.comms].text=="Disconnected."
      and third.comms[#third.comms].text=="Disconnected.",
   "guest departure did not display a disconnect communication")

guest_disconnects,third_disconnects=guest.disconnect_sounds or 0,third.disconnect_sounds or 0
host.session.stop(); update({guest,third},16)
assert(host.speed_enabled,"stopping P2P did not restore the speed key")
assert(guest.disconnect_sounds==guest_disconnects+1
      and third.disconnect_sounds==third_disconnects+1,
   "host departure did not play one disconnect sound for every guest")
assert(guest.comms[#guest.comms].text=="Disconnected."
      and third.comms[#third.comms].text=="Disconnected.",
   "host departure did not display a disconnect communication")
assert(guest.session.machine.state=="host","guest did not take over after host loss")
assert(third.session.machine.state=="guest" and third.session.machine.host=="20",
   "third peer did not follow replacement-host election")
assert(npc_replica:exists(),"host NPC replica was removed during takeover")
assert(npc_replica.armour==42,"retained NPC state changed during takeover")
assert(not escort_replica:exists(),"departed owner's craft replica was retained")

third_disconnects=third.disconnect_sounds
guest.session.stop(); update({third},8)
assert(third.disconnect_sounds==third_disconnects+1,
   "replacement-host departure did not play one disconnect sound for its guest")
assert(third.comms[#third.comms].text=="Disconnected.",
   "replacement-host departure did not display a disconnect communication")
third.session.stop()
assert(guest.speed_enabled and third.speed_enabled,"leaving P2P did not restore speed controls")

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
   type="hello",node="d1",cap="directory"}),0,"reliable")
update({punch_guest},4)
assert(not punch_guest.session.machine.members.d1,
   "directory-only node entered the gameplay election membership")
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
punch_host.session.stop(); punch_guest.session.stop()
print("ok - three-peer session integration")
