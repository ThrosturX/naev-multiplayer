package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local codec=require "multiplayer.p2p.codec"
local topology=require "multiplayer.p2p.topology"
local reconcile=require "multiplayer.p2p.reconcile"
local owned=require "multiplayer.p2p.owned"
local core=require "multiplayer.p2p.core"
local identity=require "multiplayer.p2p.identity"

local tests={}
local function test(name, fn) tests[#tests+1]={name,fn} end
local function eq(a,b) assert(a==b, tostring(a).." != "..tostring(b)) end

test("protocol escaping and validation", function()
   local packet=assert(codec.encode{type="chat",node="a1",system="A=B% C",seq=1,text="hi\nthere?"})
   local msg=assert(codec.decode(packet))
   eq(msg.system,"A=B% C"); eq(msg.text,"hi\nthere?"); eq(msg.seq,1)
   assert(not codec.decode("MP2P/9 chat\nnode=a1\n"))
   assert(not codec.decode(string.rep("x",codec.MAX_PACKET+1)))
   assert(not codec.decode("MP2P/1 chat\nnode=a1\nnode=b2\nsystem=x\nseq=1\ntext=x\n"))
   assert(not codec.decode("MP2P/1 chat\nnode=a1\nsystem=x\nseq=1\ntext=bad%A\n"))
   assert(codec.encode{type="hello",node="a1",cap="player",name="Jane"})
   assert(not codec.encode{type="hello",node="a1",cap="player"})
   assert(codec.encode{type="hello",node="a1",cap="directory"})
   assert(codec.encode{type="hint",node="d1",system="X",host="a1",
      endpoint="host:9",claim="c",ttl=60})
   assert(not codec.encode{type="hint",node="d1",system="X",host="a1",
      endpoint="host:9",claim="c",ttl=61})
end)

test("local-only player name aliases", function()
   local ids=identity.new("a1","John")
   eq(ids:add("b2","Jane"),"Jane")
   eq(ids:add("b2","Jane"),"Jane")
   eq(ids:add("c3","John"),"John #2")
   eq(ids:add("d4","John"),"John #3")
   assert(not ids:add("b2","Janet"))
   ids:remove("b2")
   eq(ids:add("e5","Jane"),"Jane")
   ids:remove("a1")
   eq(ids:raw_name("a1"),"John")
   eq(ids:display_name("a1"),"John")
end)

test("peer cache persistence and bound", function()
   local now=100
   local t=topology.new("10",function() return now end)
   for i=1,40 do t:add_peer("127.0.0.1:"..i,i) end
   eq(#t.peers,32); eq(t.peers[1].endpoint,"127.0.0.1:40")
   local t2=topology.new("10",function() return now end); t2:load_peers(t:serialize_peers())
   eq(#t2.peers,32)
end)

test("stale hints and peer-to-peer forwarding", function()
   local now=100
   local a=topology.new("a",function() return now end)
   local b=topology.new("b",function() return now end)
   assert(a:remember_hint("X","1","host:9","c",160))
   local hint=a:answer("X"); assert(hint)
   assert(b:remember_hint("X",hint.host,hint.endpoint,hint.claim,hint.expires))
   eq(b:hint("X").endpoint,"host:9")
   now=161; eq(b:hint("X"),nil)
end)

test("split brain and election order", function()
   eq(topology.resolve_claim("20","10"),"10")
   eq(topology.elect{"30","10","20"},"10")
end)

test("session transitions and host loss", function()
   local now=0; local s=core.new("20",function() return now end)
   assert(s:start()); assert(s:enter("X")); eq(s.state,"discovering")
   now=1.6; eq(s:tick(),"claim"); eq(s.state,"host")
   assert(not s:accept_claim{system="X",node="20",claim="reflected"}); eq(s.state,"host")
   s:accept_claim{system="X",node="10",claim="c"}; eq(s.state,"guest"); eq(s.host,"10")
   s.members["30"]=true; eq(s:host_lost(),"20"); eq(s.state,"host")
   s:leave(); eq(s.state,"idle"); s:stop(); eq(s.state,"stopped")
end)

test("sequence rejection", function()
   local seen={}; assert(reconcile.accept(seen,"npc",2)); assert(not reconcile.accept(seen,"npc",2)); assert(not reconcile.accept(seen,"npc",1)); assert(reconcile.accept(seen,"npc",3))
end)

test("capped reconciliation and local health", function()
   local m=reconcile.motion({x=0,y=0,vx=0,vy=0},{x=100,y=-100,vx=9,vy=-9,dir=2},10,2)
   eq(m.x,10); eq(m.y,-10); eq(m.vx,2); eq(m.vy,-2)
   local health=0
   local placed=0
   local adapter={soft_motion=function() end,set_motion=function() placed=placed+1 end,
      set_health=function(_e,a,s,t) health=a+s+t end,set_energy=function() end}
   assert(not reconcile.apply_player(adapter,{}, {},true)); eq(health,0)
   reconcile.apply_npc(adapter,{}, {armour=4,shield=5,stress=6,energy=7},true)
   eq(placed,1); eq(health,15)
   local replicas={a={native_ai=true}}; reconcile.host_lost(replicas)
   assert(replicas.a.native_ai and replicas.a.authoritative)
end)

test("owned craft nesting, authority, relay, cleanup", function()
   local ids=owned.classify({"escort"},{escort={"fighter"},fighter={"drone"}})
   assert(ids.escort and ids.fighter and ids.drone)
   local got=0; local host={members={owner=function() end,guest=function(msg,reliable) got=got+1; assert(not reliable) end}}
   assert(owned.relay(host,"owner",{type="craft_state",owner="owner"})); eq(got,1)
   assert(not owned.relay(host,"owner",{type="craft_state",owner="liar"}))
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
if failed>0 then os.exit(1) end
print(string.format("1..%d",#tests))
