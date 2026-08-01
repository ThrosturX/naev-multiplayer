package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local codec=require "multiplayer.p2p.codec"
local gameplay=require "multiplayer.p2p.gameplay_codec"
local p2p_settings=require "multiplayer.p2p.settings"
local topology=require "multiplayer.p2p.topology"
local reconcile=require "multiplayer.p2p.reconcile"
local owned=require "multiplayer.p2p.owned"
local core=require "multiplayer.p2p.core"
local identity=require "multiplayer.p2p.identity"
package.preload["ai.core.setup"]=function()
   return {setup=function () end}
end
local session=require "multiplayer.p2p.session"

local tests={}
local function test(name, fn) tests[#tests+1]={name,fn} end
local function eq(a,b) assert(a==b, tostring(a).." != "..tostring(b)) end

test("directory protocol escaping and validation", function()
   local packet=assert(codec.encode{
      type="query",node="a1",system="A=B% C",
   })
   local msg=assert(codec.decode(packet))
   eq(msg.system,"A=B% C")
   assert(not codec.decode("MP2P/9 query\nnode=a1\nsystem=X\n"))
   assert(not codec.decode(string.rep("x",codec.MAX_PACKET+1)))
   assert(not codec.decode(
      "MP2P/1 query\nnode=a1\nnode=b2\nsystem=x\n"))
   assert(not codec.decode(
      "MP2P/1 query\nnode=a1\nsystem=bad%A\n"))
   assert(codec.encode{type="hello",node="a1",cap="player",name="Jane"})
   assert(not codec.encode{type="hello",node="a1",cap="player"})
   assert(codec.encode{type="hello",node="a1",cap="directory",features="activity,contestants"})
   assert(not codec.encode{type="hello",node="a1",cap="directory",
      features="activity list"})
   assert(codec.encode{type="activity_query",node="a1"})
   assert(codec.encode{type="activity",node="d1",
      entries=codec.escape("Delta Polaris")..",1,0"})
   assert(codec.encode{type="contestant_query",node="a1",division=1,
      request=1,limit=11})
   assert(codec.encode{type="contestant_query",node="a1",
      track="death_knot",division=1,request=1,limit=11})
   assert(not codec.encode{type="contestant_query",node="a1",
      track="death knot",division=1,request=1,limit=11})
   assert(codec.encode{type="hint",node="d1",system="X",host="a1",
      endpoint="host:9",claim="c",ttl=60})
   assert(not codec.encode{type="hint",node="d1",system="X",host="a1",
      endpoint="host:9",claim="c",ttl=61})
   assert(codec.encode{type="punch",node="d1",system="X",peer="a1",
      endpoint="198.51.100.2:4567"})
   assert(not codec.encode{type="punch",node="d1",system="X",peer="not-a-node",
      endpoint="198.51.100.2:4567"})
end)

test("gameplay world carries bounded object state separately", function()
   local packet=assert(gameplay.encode{
      type="world",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",seq=1,players="-",entities="-",
      objects="a1_buoy,1,2,3,4,5,250,300,0",
   })
   local message=assert(gameplay.decode(packet))
   eq(message.objects,"a1_buoy,1,2,3,4,5,250,300,0")
   assert(not gameplay.encode{
      type="world",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",seq=1,players="-",entities="-",
   })
end)

test("gameplay control carries bounded held control state", function()
   local packet=assert(gameplay.encode{
      type="player_control",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="b2",entity="b2.a1.player",seq=2,
      x=1,y=2,vx=3,vy=4,dir=5,energy=90,target="-",
      weapset=1,accel=1,turn=-1,reverse=0,
      primary=0,secondary=0,
   })
   local message=assert(gameplay.decode(packet))
   eq(message.turn,-1)
   eq(message.reverse,0)
   assert(not gameplay.encode{
      type="player_control",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="b2",entity="b2.a1.player",seq=2,
      x=1,y=2,vx=3,vy=4,dir=5,energy=90,target="-",
      weapset=1,accel=1,primary=0,secondary=0,
   })
   local toggle=assert(gameplay.encode{
      type="outfit_toggle",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="a1",entity="a1.a1.player",
      seq=3,slot=4,on=1,
   })
   local decoded=assert(gameplay.decode(toggle))
   eq(decoded.slot,4); eq(decoded.on,1)
   assert(not gameplay.encode{
      type="player_control",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="a1",entity="a1.a1.player",seq=4,
      x=1,y=2,vx=3,vy=4,dir=5,energy=90,target="-",
      weapset=1,accel=1,turn=0,reverse=0,
      primary=0,secondary=0,active="still-on",
   })
end)

test("gameplay entity queries and guest-owned NPC state", function()
   local packet=assert(gameplay.encode{
      type="entity_query",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",entity="a1.a1.n.2.9",seq=3,
   })
   local message=assert(gameplay.decode(packet))
   eq(message.entity,"a1.a1.n.2.9")
   eq(message.seq,3)
   local manifest=assert(gameplay.encode{
      type="entity_manifest",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="npc",owner="b2",
      entity="b2.b2.n.2.9",origin="b2.b2.npc.9",
      ship="Lancelot",name="Raider",faction="Pirate",ai="pirate",
      outfits="-",slots="-",leader="-",x=1,y=2,vx=3,vy=4,dir=0,
      armour=100,shield=100,stress=0,energy=100,target="b2.b2.player",
      weapset=1,accel=0,turn=0,reverse=0,primary=0,secondary=0,
   })
   local description=assert(gameplay.decode(manifest))
   eq(description.kind,"npc")
   eq(description.owner,"b2")
   local state=assert(gameplay.encode{
      type="entity_state",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="npc",owner="b2",
      entity="b2.b2.n.2.9",seq=4,
      state="b2.b2.n.2.9,1,2,3,4,0,100,100,0,100,-,1,0,0,0,0,0,-",
   })
   eq(assert(gameplay.decode(state)).kind,"npc")
   assert(not gameplay.encode{
      type="entity_state",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="npc",owner="c3",
      entity="c3.b2.n.2.9",seq=4,state="-",
   })
   assert(not gameplay.encode{
      type="entity_manifest",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="npc",owner="b2",
      entity="b2.b2.n.2.9",origin="c3.b2.npc.9",
      ship="Lancelot",name="Raider",faction="Pirate",ai="pirate",
      outfits="-",slots="-",
   })
   local death=assert(gameplay.encode{
      type="entity_remove",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="player",owner="b2",
      entity="b2.b2.player",seq=5,reason="death",
   })
   eq(assert(gameplay.decode(death)).kind,"player")
   assert(not gameplay.encode{
      type="entity_remove",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",kind="player",owner="b2",
      entity="b2.b2.player",seq=6,reason="removed",
   })
end)

test("player descriptions refresh current spawn coordinates", function()
   local old_settings,old_machine,old_visit=
      session.settings,session.machine,session.visit
   local old_states=session.player_states
   session.settings={node_id="a1"}
   session.machine={system="X",claim="a1:a1:1"}
   session.visit="a1"
   session.player_states={b2={
      x=900,y=-400,vx=12,vy=34,dir=1,
      armour=80,shield=70,stress=0,energy=60,target="-",
      weapset=1,accel=0,turn=0,reverse=0,primary=0,secondary=0,
   }}
   local refreshed=session._refresh_player_manifest_state{
      type="player_manifest",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="b2",entity="b2.b2.player",
      x=1,y=2,
   }
   eq(refreshed.x,900); eq(refreshed.y,-400)
   session.settings,session.machine,session.visit=
      old_settings,old_machine,old_visit
   session.player_states=old_states
end)

test("target and combat interactions admit both local pilots", function()
   local old_running,old_machine=session.running,session.machine
   local old_admit=session._admit_local_pilot
   local admitted={}
   session.running=true
   session.machine={system="X"}
   session._admit_local_pilot=function ( p )
      if not p then return end
      admitted[#admitted+1]=p
      return {}
   end
   local target={}
   local participant={exists=function () return true end,
      target=function () return target end}
   assert(session._admit_player_target(participant))
   assert(session.pilot_attacked("victim","attacker"))
   eq(admitted[1],target)
   eq(admitted[2],"victim")
   eq(admitted[3],"attacker")
   session._admit_local_pilot=old_admit
   session.running,session.machine=old_running,old_machine
end)

test("player death tombstones clear replaceable state", function()
   local old_settings,old_visit=session.settings,session.visit
   local old_dead,old_states=session.dead_players,session.player_states
   local old_outfits,old_cache=session.outfit_messages,session.manifest_cache
   local old_queries,old_pending=session.manifest_queries,session.pending_states
   local old_pending_count=session.pending_state_count
   session.settings={node_id="a1"}
   session.visit="a1"
   session.dead_players={}
   session.player_states={b2={entity="b2.b2.player"}}
   session.outfit_messages={b2={}}
   session.manifest_cache={["b2.b2.player"]={}}
   session.manifest_queries={["b2.b2.player"]=1}
   session.pending_states={["b2.b2.player"]={}}
   session.pending_state_count=1
   assert(session._mark_player_dead("b2","b2.b2.player"))
   assert(session.dead_players["b2.b2.player"])
   eq(session.player_states.b2,nil)
   eq(session.outfit_messages.b2,nil)
   eq(session.manifest_cache["b2.b2.player"],nil)
   eq(session.manifest_queries["b2.b2.player"],nil)
   eq(session.pending_states["b2.b2.player"],nil)
   eq(session.pending_state_count,0)
   assert(not session._mark_player_dead("b2","b2.b2.player"))
   session.settings,session.visit=old_settings,old_visit
   session.dead_players,session.player_states=old_dead,old_states
   session.outfit_messages,session.manifest_cache=old_outfits,old_cache
   session.manifest_queries,session.pending_states=old_queries,old_pending
   session.pending_state_count=old_pending_count
end)

test("gameplay world batches stay below unreliable ENet budget", function()
   local host=string.rep("a",32)
   local visit=string.rep("d",32)
   local function entity(node,kind,index)
      if kind=="player" then return node.."."..visit..".player" end
      return node.."."..visit.."."..kind.."."..index.."."..(1000+index)
   end
   local function state(id,target)
      return table.concat({
         id,"12345.678901234","-12345.678901234",
         "145.678901234","-89.123456789","3.1415926535",
         "100","100","0","100",target,"1","1","0","0","0","0","-",
      },",")
   end
   local nodes={host,string.rep("b",32),string.rep("c",32)}
   local target=entity(host,"n",1)
   local players={}
   for _index,node in ipairs(nodes) do
      players[#players+1]=state(entity(node,"player"),target)
   end
   local entities={}
   for index=1,3 do
      entities[#entities+1]=state(
         entity(host,index==3 and "c" or "n",index),players[index] and
            entity(nodes[index],"player") or "-")
   end
   local object=host.."_buoy_"..visit
      ..",12345.678901234,-12345.678901234,145.678901234"
      ..",-89.123456789,3.1415926535,100,100,0"
   local batches=assert(gameplay.encode_world_batches({
      type="world",node=host,system="Gamma Polaris",visit=visit,
      epoch=host..":"..visit..":1",seq=1,
   },{
      players=players,entities=entities,objects={object},
   },1200))
   assert(#batches>1)
   local seen={players=0,entities=0,objects=0}
   for _index,batch in ipairs(batches) do
      assert(#batch.packet<=1200)
      local decoded=assert(gameplay.decode(batch.packet))
      for _field in pairs(seen) do
         if decoded[_field]~="-" then
            for _line in decoded[_field]:gmatch("([^;]+)") do
               seen[_field]=seen[_field]+1
            end
         end
      end
   end
   eq(seen.players,#players)
   eq(seen.entities,#entities)
   eq(seen.objects,1)
end)

test("oversized NPC announcements preserve the bounded world stream", function()
   local player_state=table.concat({
      "a1.a1.player",0,0,0,0,0,100,100,0,100,"-",1,0,0,0,0,0,"-",
   },",")
   local oversized="n,"..player_state..","..string.rep("x",1400)
   local batches,err,fallbacks=gameplay.encode_world_batches({
      type="world",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",seq=1,
   },{
      players={player_state},entities={oversized},objects={},
   },1200)
   assert(batches,err)
   eq(#batches,1)
   assert(#batches[1].packet<=1200)
   eq(#fallbacks,1)
   eq(fallbacks[1],oversized)
end)

test("complete NPC announcements round trip packed state", function()
   local record={
      entity="a1.b2.n.1.9",x=1,y=2,vx=0,vy=0,dir=1,
      armour=100,shield=50,stress=0,energy=90,target="-",
      weapset=1,accel=0,turn=0,reverse=0,
      primary=0,secondary=0,
   }
   local entry={description={
      owner="a1",origin="a1.b2.npc.9",ship="Lancelot",
      name="Raider One",faction="Pirate",ai="pirate",
      outfits="Laser Cannon",slots="1:Laser%20Cannon",leader="-",
   }}
   local packed=assert(session._pack_npc_announcement(entry,record))
   local decoded,description=session._unpack_npc_announcement(packed)
   assert(decoded and description)
   eq(decoded.vx,0); eq(decoded.vy,0)
   eq(description.name,"Raider One")
   eq(description.slots,"1:Laser%20Cannon")
end)

test("local-only player name aliases", function()
   local ids=identity.new("a1","John")
   eq(ids:add("b2","Jane"),"Jane")
   eq(ids:add("b2","Jane"),"Jane")
   eq(ids:add("c3","John"),"John (2)")
   eq(ids:add("d4","John"),"John (3)")
   assert(not ids:add("b2","Janet"))
   eq(ids:update("b2","Janet"),"Janet")
   eq(ids:raw_name("b2"),"Janet")
   ids:remove("b2")
   eq(ids:add("e5","Jane"),"Jane")
   ids:remove("a1")
   eq(ids:raw_name("a1"),"John")
   eq(ids:display_name("a1"),"John")
   assert(not ids:update("a1","Other John"))
end)

test("peer cache persistence and bound", function()
   local now=100
   local t=topology.new("10",function() return now end)
   for i=1,40 do t:add_peer("127.0.0.1:"..i,i) end
   eq(#t.peers,32); eq(t.peers[1].endpoint,"127.0.0.1:40")
   local t2=topology.new("10",function() return now end); t2:load_peers(t:serialize_peers())
   eq(#t2.peers,32)
end)

test("stale host hints", function()
   local now=100
   local a=topology.new("a",function() return now end)
   local b=topology.new("b",function() return now end)
   assert(a:remember_hint("X","1","host:9","c",160))
   local hint=a:hint("X"); assert(hint)
   assert(b:remember_hint("X",hint.host,hint.endpoint,hint.claim,hint.expires))
   eq(b:hint("X").endpoint,"host:9")
   assert(b:remember_hint("X","2","new-host:10","d",160))
   eq(b:hint("X").host,"2")
   eq(b:hint("X").endpoint,"new-host:10")
   now=161; eq(b:hint("X"),nil)
end)

test("split brain and election order", function()
   eq(topology.resolve_claim("20","10"),"10")
   eq(topology.elect{"30","10","20"},"10")
end)

test("simultaneous discovery claims converge", function()
   local now=0
   local a=core.new("10",function() return now end)
   local b=core.new("20",function() return now end)
   assert(a:start()); assert(b:start())
   assert(a:enter("X","a1")); assert(b:enter("X","b1"))
   now=2.1
   eq(a:tick(),"claim"); eq(b:tick(),"claim")
   assert(not a:accept_claim{
      system="X",node="20",visit="b1",claim=b.claim,
   })
   assert(b:accept_claim{
      system="X",node="10",visit="a1",claim=a.claim,
   })
   eq(a.state,"host"); eq(a.host,"10")
   eq(b.state,"guest"); eq(b.host,"10"); eq(b.claim,a.claim)
end)

test("session transitions and host loss", function()
   local now=0; local s=core.new("20",function() return now end)
   assert(s:start()); assert(s:enter("X")); eq(s.state,"discovering")
   assert(s:accept_claim{system="X",node="30",claim="incumbent"})
   eq(s.state,"guest"); eq(s.host,"30")
   s:leave(); assert(s:enter("X")); eq(s.state,"discovering")
   now=2.1; eq(s:tick(),"claim"); eq(s.state,"host")
   assert(not s:accept_claim{system="X",node="20",claim="reflected"}); eq(s.state,"host")
   s:accept_claim{system="X",node="10",claim="c"}; eq(s.state,"guest"); eq(s.host,"10")
   s.members["30"]=true; s:host_lost(); eq(s.state,"recovering")
   now=4.2; eq(s:tick(),"claim"); eq(s.state,"host")
   s:leave(); eq(s.state,"idle"); s:stop(); eq(s.state,"stopped")
end)

test("sequence rejection", function()
   local seen={}; assert(reconcile.accept(seen,"npc",2)); assert(not reconcile.accept(seen,"npc",2)); assert(not reconcile.accept(seen,"npc",1)); assert(reconcile.accept(seen,"npc",3))
end)

test("capped reconciliation", function()
   local near_x,near_y,near_moved=reconcile.catchup_position(
      0,0,1999,0,2000,0.5)
   eq(near_x,0); eq(near_y,0); eq(near_moved,false)
   local far_x,far_y,far_moved=reconcile.catchup_position(
      0,0,6000,-2000,2000,0.5)
   eq(far_x,3000); eq(far_y,-1000); eq(far_moved,true)
   local smooth=reconcile.steer({x=0,y=0,vx=0,vy=0,dir=2*math.pi-0.1},
      {x=10000,y=-10000,vx=1000,vy=-1000,dir=0.1},1/60,0,
      {correction_speed=600,acceleration=600})
   eq(smooth.vx,10); eq(smooth.vy,-10)
   assert(smooth.dir<0.1 or smooth.dir>2*math.pi-0.1,
      "direction smoothing took the long way around")
   local turn=reconcile.steer({x=0,y=0,vx=0,vy=0,dir=0},
      {x=0,y=0,vx=0,vy=0,dir=math.pi},1/3,0,
      {direction_rate=10,direction_speed=1.5})
   local turned=math.abs((turn.dir+math.pi)%(2*math.pi)-math.pi)
   assert(math.abs(turned-0.15)<1e-9,
      "direction correction exceeded its angular speed cap")
   local sparse_turn=reconcile.steer(
      {x=0,y=0,vx=0,vy=0,dir=0},
      {x=0,y=0,vx=0,vy=0,dir=math.pi},0.25,0,
      {
         direction_rate=30,direction_speed=8,max_dt=0.25,
      })
   local sparse_turned=math.abs(
      (sparse_turn.dir+math.pi)%(2*math.pi)-math.pi)
   assert(math.abs(sparse_turned-2)<1e-9,
      "sparse direction correction ignored its elapsed-time cap")
   local unpredicted=reconcile.steer(
      {x=0,y=0,vx=0,vy=0,dir=0},
      {x=0,y=0,vx=100,vy=0,dir=0},0.1,0,
      {
         position_gain=1.5,correction_speed=250,
         velocity_rate=8,acceleration=600,max_prediction=0.125,
      })
   local predicted=reconcile.steer(
      {x=0,y=0,vx=0,vy=0,dir=0},
      {x=0,y=0,vx=100,vy=0,dir=0},0.1,0.05,
      {
         position_gain=1.5,correction_speed=250,
         velocity_rate=8,acceleration=600,max_prediction=0.125,
      })
   assert(predicted.vx>unpredicted.vx,
      "bounded prediction did not lead the received motion")
   local resting=reconcile.steer(
      {x=0.5,y=0,vx=0.5,vy=0,dir=0},
      {x=0,y=0,vx=0,vy=0,dir=0},1/15,0,
      {
         position_gain=2.5,correction_speed=600,velocity_rate=12,
         acceleration=2400,rest_source_speed=0.25,
         rest_position=1,rest_replica_speed=8,
      })
   eq(resting.vx,0); eq(resting.vy,0)
   local declared_stop=reconcile.steer(
      {x=500,y=0,vx=300,vy=-20,dir=0},
      {x=0,y=0,vx=0,vy=0,dir=0},1/15,0,
      {
         position_gain=1.5,correction_speed=400,
         rest_source_speed=0.25,follow_velocity=true,
      })
   eq(declared_stop.vx,0); eq(declared_stop.vy,0)
   local stationary_offset=reconcile.steer(
      {x=0,y=0,vx=0,vy=0,dir=0},
      {x=100,y=-50,vx=0,vy=0,dir=0},1/15,0,
      {
         position_gain=1.5,correction_speed=250,
         follow_velocity=true,
      })
   eq(stationary_offset.vx,150); eq(stationary_offset.vy,-75)
end)

test("autonav thrust is inferred beyond keyboard state", function()
   local previous_player=_G.player
   _G.player={autonav=function () return true end}
   local p={
      dir=function () return 0 end,
      speed=function () return 100 end,
      accel=function () return 50 end,
   }
   session.local_motion_sample=nil
   eq(session._local_accel_control(p,false,1,120,0),1)
   session.local_motion_sample=nil
   eq(session._local_accel_control(p,false,2,50,0),0)
   eq(session._local_accel_control(p,false,2.1,60,0),1)
   eq(session._local_accel_control(p,true,2.2,60,0),1)
   _G.player=previous_player
end)

test("shared-time lock requires online same-system evidence", function()
   local previous={
      settings=session.settings,
      running=session.running,
      machine=session.machine,
      peer_meta=session.peer_meta,
      activity=session.activity,
      skip_host_grace=session.skip_host_grace,
      solo_since=session.solo_since,
      autonav_locked=session.autonav_locked,
      indicators=session.indicators,
      player=_G.player,
      naev=_G.naev,
   }
   local function restore ()
      session.settings=previous.settings
      session.running=previous.running
      session.machine=previous.machine
      session.peer_meta=previous.peer_meta
      session.activity=previous.activity
      session.skip_host_grace=previous.skip_host_grace
      session.solo_since=previous.solo_since
      session.autonav_locked=previous.autonav_locked
      session.indicators=previous.indicators
      _G.player=previous.player
      _G.naev=previous.naev
   end

   local ok,err=pcall(function ()
      local remote={}
      local speed_enabled=false
      local configured_game_speed=1.25
      local dt_mod=p2p_settings.MULTIPLAYER_TIME_RATE*0.5
      local canonical_resets=0
      local cleared=0
      local countdowns=0
      session.settings={node_id="a1"}
      session.running=true
      session.machine={
         state="discovering",system="Arandon",members={a1=true},
      }
      session.peer_meta={
         [remote]={
            verified=true,protocol="gameplay",system="Gamma Polaris",
         },
      }
      session.activity={{system="Gamma Polaris",active=true}}
      session.skip_host_grace=true
      session.autonav_locked=true
      session.indicators={
         clear_host_alone=function () cleared=cleared+1 end,
         host_alone=function () countdowns=countdowns+1 end,
      }
      _G.naev={
         ticks=function () return 10 end,
         conf=function () return {game_speed=configured_game_speed} end,
         keyEnable=function ( key, enabled )
            eq(key,"speed")
            speed_enabled=enabled
         end,
      }
      _G.player={
         autonav=function () return false,1 end,
         autonavSetSpeed=function () end,
         dt_mod=function () return dt_mod end,
         setSpeed=function ( speed, sound )
            if speed==nil then return end
            eq(speed,
               p2p_settings.MULTIPLAYER_TIME_RATE/configured_game_speed)
            eq(sound,p2p_settings.MULTIPLAYER_TIME_RATE)
            dt_mod=p2p_settings.MULTIPLAYER_TIME_RATE
            canonical_resets=canonical_resets+1
         end,
      }

      session.peer_meta={[remote]={verified=false,connected_at=9}}
      local network,refresh_after=session.network_status()
      eq(network,"unknown")
      eq(refresh_after,1)
      session.peer_meta[remote].connected_at=7
      network,refresh_after=session.network_status()
      eq(network,"unavailable")
      eq(refresh_after,p2p_settings.NETWORK_STATUS_RECHECK_INTERVAL)
      session.peer_meta={[remote]={
         verified=true,protocol="gameplay",system="Gamma Polaris",
      }}

      assert(session._no_other_players_discovered("Arandon"),
         "remote-system connection or activity counted as nearby")
      assert(not session.has_online_shared_time_peer("Arandon"),
         "remote-system gameplay peer counted as shared-time evidence")
      session._refresh_time_controls(10)
      assert(speed_enabled and not session.autonav_locked
            and session.skip_host_grace and cleared==1 and countdowns==0,
         "confirmed solo discovery did not preserve normal time controls")

      session.peer_meta[remote].system="Arandon"
      session.machine.state="host"
      assert(session.has_online_shared_time_peer("Arandon"),
         "online same-system gameplay peer was not detected")
      session._refresh_time_controls(10)
      assert(not speed_enabled and session.autonav_locked
            and not session.skip_host_grace and countdowns==1
            and dt_mod==p2p_settings.MULTIPLAYER_TIME_RATE
            and canonical_resets==1,
         "same-system gameplay peer did not cancel the solo bypass")
      session.enforce_time_controls()
      eq(canonical_resets,1)

      session.peer_meta={}
      session.machine.members.b2=true
      assert(not session._no_other_players_discovered("Arandon"),
         "same-system member was treated as solo")
      assert(not session.has_online_shared_time_peer("Arandon"),
         "stale membership without a reachable network counted as online")
      session._refresh_time_controls(11)
      assert(speed_enabled and not session.autonav_locked
            and cleared==2 and countdowns==1,
         "unreachable network kept solo time controls locked")

      session.machine.state="discovering"
      session.machine.members={a1=true}
      session.peer_meta={[remote]={
         verified=true,protocol="directory",system=nil,
      }}
      session.autonav_locked=true
      speed_enabled=false
      session._refresh_time_controls(12)
      assert(speed_enabled and not session.autonav_locked
            and not session.has_online_shared_time_peer("Arandon"),
         "directory reachability alone locked solo time controls")
   end)
   restore()
   assert(ok,err)
end)

test("owned craft nesting and cleanup", function()
   local ids=owned.classify({"escort"},{escort={"fighter"},fighter={"drone"}})
   assert(ids.escort and ids.fighter and ids.drone)
   local removed=false
   local replicas={a={owner="owner"},b={owner="guest"}}; owned.cleanup(replicas,"owner",function() removed=true end)
   assert(removed)
   eq(replicas.a,nil); assert(replicas.b)
end)

test("authoritative NPC targets repair only stale attack tasks", function()
   local old_target,new_target={},{}
   local function npc ( task, target )
      local state={task=task,target=target,cleared=0}
      local p={
         exists=function () return true end,
         taskname=function () return state.task end,
         taskdata=function () return state.target end,
         taskClear=function ()
            state.cleared=state.cleared+1
            state.task=nil
            state.target=nil
         end,
         pushtask=function ( _self, name, data )
            state.task=name
            state.target=data
         end,
      }
      return {kind="npc",pilot=p},state
   end
   local entry,state=npc("attack",old_target)
   assert(session._sync_replica_attack_task(entry,new_target))
   eq(state.cleared,1); eq(state.task,"attack"); eq(state.target,new_target)
   assert(session._sync_replica_attack_task(entry,nil))
   eq(state.cleared,2); eq(state.task,nil)
   local fleeing,flee_state=npc("runaway",old_target)
   assert(not session._sync_replica_attack_task(fleeing,new_target))
   eq(flee_state.cleared,0); eq(flee_state.task,"runaway")
end)

test("remote owned craft require explicit attack orders", function()
   local memory={aggressive=true,atk_kill=true}
   session._apply_owned_craft_ai_policy{
      memory=function () return memory end,
   }
   eq(memory.aggressive,false)
   eq(memory.atk_kill,false)
end)

test("session lifecycle resolves extracted settings helpers", function()
   local old_naev,old_player,old_pilot,old_rnd,old_system=
      _G.naev,_G.player,_G.pilot,_G.rnd,_G.system
   local enet=require "enet"
   local old_host_create=enet.host_create
   local cache={}
   _G.naev={
      cache=function () return cache end,
      ticks=function () return 10 end,
      claimTest=function () return true end,
      keyEnable=function () end,
   }
   _G.player={
      pilot=function () return nil end,
      name=function () return "Lifecycle Test" end,
      autonavSetSpeed=function () end,
      setSpeed=function () end,
   }
   _G.pilot={toggleSpawn=function () end}
   _G.rnd={rnd=function () return 1 end}
   _G.system={cur=function () return {} end}
   enet.host_create=function ()
      return {
         get_socket_address=function () return "0.0.0.0:62000" end,
         connect=function ()
            return {disconnect_now=function () end}
         end,
         broadcast=function () end,
         service=function () return nil end,
      }
   end

   local ok,err=pcall(function ()
      assert(session.start{
         enabled=true,node_id="a1",directory="",
         bootstrap={"127.0.0.1:9"},recent={},
      })
      assert(session.enter("Lifecycle Test System"))
      assert(session.visit and session.visit~="")
   end)
   local stopped,stop_err=pcall(session.stop)
   enet.host_create=old_host_create
   _G.naev,_G.player,_G.pilot,_G.rnd,_G.system=
      old_naev,old_player,old_pilot,old_rnd,old_system
   if not ok then error(err) end
   if not stopped then error(stop_err) end
end)

test("session lifecycle retries transient ENet peer exhaustion", function()
   local old_naev,old_player,old_pilot,old_rnd,old_system=
      _G.naev,_G.player,_G.pilot,_G.rnd,_G.system
   local enet=require "enet"
   local old_host_create=enet.host_create
   local cache={}
   local connect_attempts=0
   _G.naev={
      cache=function () return cache end,
      ticks=function () return 10 end,
      claimTest=function () return true end,
      keyEnable=function () end,
   }
   _G.player={
      pilot=function () return nil end,
      name=function () return "Lifecycle Retry Test" end,
      autonavSetSpeed=function () end,
      setSpeed=function () end,
   }
   _G.pilot={toggleSpawn=function () end}
   _G.rnd={rnd=function () return 1 end}
   _G.system={cur=function () return {} end}
   enet.host_create=function ()
      return {
         get_socket_address=function () return "0.0.0.0:62000" end,
         connect=function ()
            connect_attempts=connect_attempts+1
            error("Failed to create peer")
         end,
         broadcast=function () end,
         service=function () return nil end,
      }
   end

   local ok,err=pcall(function ()
      assert(session.start{
         enabled=true,node_id="a1",directory="",
         bootstrap={"127.0.0.1:9"},recent={},
      })
      assert(session.enter("Lifecycle Retry Test System"))
      assert(connect_attempts>=2,
         "failed connection was not left eligible for a later retry")
   end)
   local stopped,stop_err=pcall(session.stop)
   enet.host_create=old_host_create
   _G.naev,_G.player,_G.pilot,_G.rnd,_G.system=
      old_naev,old_player,old_pilot,old_rnd,old_system
   if not ok then error(err) end
   if not stopped then error(stop_err) end
end)

test("remote player AI gives owned craft the normal no-kill policy", function()
   local chunk=assert(loadfile("ai/core/control/p2p_remote_control.lua"))
   local env={
      mem={},
      ai={},
      require=function ( name )
         if name=="ai.core.attack.util" then
            return {primary=function () end,secondary=function () end}
         end
         return require(name)
      end,
   }
   setmetatable(env,{__index=_G})
   setfenv(chunk,env)
   chunk()
   env.create()
   eq(env.mem.atk_kill,false)
end)

local failed=0
for _index, item in ipairs(tests) do
   local ok, err=pcall(item[2])
   if ok then print("ok - "..item[1]) else failed=failed+1; io.stderr:write("not ok - "..item[1]..": "..tostring(err).."\n") end
end

do
   local register={
      type="contestant_register",node="a1",division=1,name="Ace",ship="Hyena",
      outfits="Laser%20Cannon",slots="1:Laser%20Cannon",
      ship_fallbacks="Hyena",
   }
   local packet=assert(codec.encode(register))
   local decoded=assert(codec.decode(packet))
   assert(decoded.division==1 and decoded.name=="Ace")
   assert(not codec.encode{
      type="contestant_register",node="a1",division=4,name="Ace",ship="Hyena",
      outfits="Laser",slots="1:Laser",
   })
   assert(not codec.encode{
      type="contestant_entry",node="d1",contestant="not-hex",division=1,
      request=1,name="Ace",ship="Hyena",outfits="Laser",slots="1:Laser",
   })
end
if failed>0 then os.exit(1) end
print(string.format("1..%d",#tests))
