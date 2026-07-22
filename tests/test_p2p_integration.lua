package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

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
package.preload["ai.core.setup"]=function() return {setup=function() end} end

local function vector ( x, y )
   return {x=x or 0,y=y or 0,get=function(self) return self.x,self.y end}
end

local function resource ( name )
   return {nameRaw=function() return name end}
end

local function new_world ( player_name )
   local world={clock=0,pilots={},next_id=1,spawn=true,player_name=player_name,
      speed_enabled=true,autonav_resets=0}
   local pilot_methods={}
   pilot_methods.__index=pilot_methods
   function pilot_methods:exists () return not self.removed end
   function pilot_methods:rm () self.removed=true end
   function pilot_methods:name () return self.pilot_name end
   function pilot_methods:ship () return resource(self.ship_name) end
   function pilot_methods:faction () return resource(self.faction_name) end
   function pilot_methods:outfitsList () return {} end
   function pilot_methods:actives () return {} end
   function pilot_methods:pos () return self.position end
   function pilot_methods:vel () return self.velocity end
   function pilot_methods:dir () return self.direction end
   function pilot_methods:target () return self.target_pilot end
   function pilot_methods:health () return self.armour,self.shield,self.stress end
   function pilot_methods:energy () return self.energy_value end
   function pilot_methods:id () return self.pilot_id end
   function pilot_methods:withPlayer () return self.owned or false end
   function pilot_methods:leader () return self.leader_pilot end
   function pilot_methods:setPos (v) self.position=v end
   function pilot_methods:setVel (v) self.velocity=v end
   function pilot_methods:setDir (v) self.direction=v end
   function pilot_methods:setTarget (v) self.target_pilot=v end
   function pilot_methods:setHealth (a,s,t) self.armour=a; self.shield=s; self.stress=t end
   function pilot_methods:setEnergy (v) self.energy_value=v end
   function pilot_methods:setInvincible (v) self.invincible=v end
   function pilot_methods:outfitAdd () end
   function pilot_methods:outfitToggle () end
   function pilot_methods:memory () return {} end
   function pilot_methods:broadcast (text) self.last_chat=text end

   function world:add_pilot ( ship_name, faction_name, pilot_name, owned )
      local p=setmetatable({ship_name=ship_name,faction_name=faction_name,pilot_name=pilot_name,
         owned=owned,position=vector(),velocity=vector(),direction=0,armour=100,shield=100,
         stress=0,energy_value=100,pilot_id=self.next_id},pilot_methods)
      self.next_id=self.next_id+1; table.insert(self.pilots,p); return p
   end
   world.local_pilot=world:add_pilot("Llama","Player","Local Ship",true)

   local env=setmetatable({}, {__index=_G})
   env.naev={ticksGame=function() return world.clock end,cache=function() return {} end,
      keyEnable=function(key,enabled) assert(key=="speed"); world.speed_enabled=enabled end}
   env.rnd={rnd=function(a) return a or 1 end}
   env.vec2={new=vector}
   env.player={name=function() return world.player_name end,pilot=function() return world.local_pilot end,
      isLanded=function() return false end,
      autonavReset=function() world.autonav_resets=world.autonav_resets+1 end}
   env.ship={get=function(name) assert(type(name)=="string" and name~=""); return resource(name) end}
   env.outfit={get=function(name) return resource(name) end}
   env.faction={get=function(name) return resource(name) end,
      dynAdd=function(_base,raw) return resource(raw) end}
   env.pilot={
      get=function() local out={}; for _index,p in ipairs(world.pilots) do if not p.removed then out[#out+1]=p end end; return out end,
      add=function(ship_name,fac,pos,name)
         local faction_name=type(fac)=="string" and fac or fac:nameRaw()
         local p=world:add_pilot(ship_name,faction_name,name,false); p.position=pos; return p
      end,
      toggleSpawn=function(v) world.spawn=v end,
      taskClear=function() end,pushtask=function() end,comm=function() end,
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
assert(host.session.start{enabled=true,node_id="10",listen_port=62001,directory="",bootstrap={},recent={}})
assert(host.session.enter("Delta Polaris"))
assert(not host.speed_enabled,"P2P system entry did not disable the speed key")
advance({host},2,4)
assert(host.autonav_resets>1,"P2P updates did not continually cancel autonav")
assert(host.session.machine.state=="host")
local npc=host:add_pilot("Koala","Empire","Host NPC",false)
local escort=host:add_pilot("Hyena","Player","Host Escort",true)

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
assert(not find(host,"John","P2P Players") and not find(guest,"John","P2P Players"))

local npc_replica=find(guest,"Host NPC","Empire")
assert(npc_replica,"guest did not receive host NPC")
local escort_replica=find(guest,"Host Escort","Player")
assert(escort_replica,"guest did not receive owner-authoritative craft")

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
advance({host,guest,third},0.1,8)
local proxy_x=select(1,host_proxy:pos():get())
assert(proxy_x>0 and proxy_x<=80,"player correction was not soft-capped")
assert(guest.local_pilot.armour==100 and guest.local_pilot.shield==100,"local player health was overwritten")
assert(host.session.send_chat("headless hello")); update({host,guest,third},8)
assert(host_proxy.last_chat=="headless hello","reliable chat was not delivered")

host.session.stop(); update({guest,third},16)
assert(host.speed_enabled,"stopping P2P did not restore the speed key")
assert(guest.session.machine.state=="host","guest did not take over after host loss")
assert(third.session.machine.state=="guest" and third.session.machine.host=="20",
   "third peer did not follow replacement-host election")
assert(npc_replica:exists(),"host NPC replica was removed during takeover")
assert(npc_replica.armour==42,"retained NPC state changed during takeover")
assert(not escort_replica:exists(),"departed owner's craft replica was retained")

guest.session.stop()
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
print("ok - three-peer session integration")
