package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local codec=require "multiplayer.p2p.codec"
local gameplay=require "multiplayer.p2p.gameplay_codec"
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
   assert(not codec.encode{type="contestant_query",node="a1",division=1,
      request=1,limit=12})
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

test("gameplay control carries complete held visual state", function()
   local packet=assert(gameplay.encode{
      type="player_control",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="b2",entity="b2.a1.player",seq=2,
      x=1,y=2,vx=3,vy=4,dir=5,energy=90,target="-",
      weapset=1,accel=1,turn=-1,reverse=0,
      primary=0,secondary=0,active="-",
   })
   local message=assert(gameplay.decode(packet))
   eq(message.turn,-1)
   eq(message.reverse,0)
   eq(message.active,"-")
   assert(not gameplay.encode{
      type="player_control",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",owner="b2",entity="b2.a1.player",seq=2,
      x=1,y=2,vx=3,vy=4,dir=5,energy=90,target="-",
      weapset=1,accel=1,primary=0,secondary=0,active="-",
   })
end)

test("gameplay entity queries request unknown descriptions", function()
   local packet=assert(gameplay.encode{
      type="entity_query",node="b2",system="X",visit="b2",
      epoch="a1:a1:1",entity="a1.a1.n.2.9",seq=3,
   })
   local message=assert(gameplay.decode(packet))
   eq(message.entity,"a1.a1.n.2.9")
   eq(message.seq,3)
   assert(not gameplay.encode{
      type="entity_manifest",node="a1",system="X",visit="a1",
      epoch="a1:a1:1",kind="npc",owner="a1",
      entity="a1.a1.n.2.9",origin="a1.a1.npc.9",
      ship="Lancelot",name="Raider",faction="Pirate",ai="pirate",
      outfits="-",slots="-",
   })
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
      primary=0,secondary=0,active="",
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
end)

test("owned craft nesting and cleanup", function()
   local ids=owned.classify({"escort"},{escort={"fighter"},fighter={"drone"}})
   assert(ids.escort and ids.fighter and ids.drone)
   local removed=false
   local replicas={a={owner="owner"},b={owner="guest"}}; owned.cleanup(replicas,"owner",function() removed=true end)
   assert(removed)
   eq(replicas.a,nil); assert(replicas.b)
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
