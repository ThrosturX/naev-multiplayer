package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local codec=require "multiplayer.p2p.codec"
local Object=require "multiplayer.p2p.objects"
local Directory=require "multiplayer.p2p.directory"

local sent={}
local dirty=0
local clock=100
local service=Directory.new{
   node_id="d1",
   now=function() return clock end,
   objects={},
   object_dirty=function() dirty=dirty+1 end,
   send=function(peer,packet)
      sent[#sent+1]={peer=peer,message=assert(codec.decode(packet))}
      return true
   end,
}
local function find ( at, peer, kind )
   for index=at,#sent do
      local entry=sent[index]
      if entry.peer==peer and entry.message.type==kind then return entry.message end
   end
end
local function receive ( peer, message )
   return service:receive(peer,assert(codec.encode(message)))
end
local function buoy ( id, owner, system_name )
   return {
      id=id,kind="message_buoy",owner=owner,created=1,revision=1,
      data={text="Hello",captain="Captain"},
      endpoints={{id=id.."_p",system=system_name,x=1,y=2,dir=3,
         role="physical",visible=true}},
   }
end

local first,second={},{}
assert(service:connect(first,"127.0.0.1:10001"))
assert(sent[#sent].message.features:find("objects",1,true))
assert(receive(first,{type="hello",node="a1",cap="player",name="One"}))
assert(service:connect(second,"127.0.0.1:10002"))
assert(receive(second,{type="hello",node="b2",cap="player",name="Two"}))
assert(receive(first,{type="object_query",node="a1",system="Halir",request=1}))
assert(receive(second,{type="object_query",node="b2",system="Halir",request=2}))
assert(find(1,first,"object_done").count==0)

local create_at=#sent+1
local value=buoy("buoy_a1","a1","Halir")
assert(receive(first,{type="object_create",node="a1",request=3,
   object_id=value.id,object=assert(Object.encode(value))}))
assert(dirty==1 and service:dump_objects().buoy_a1)
assert(next(service.activity)==nil,
   "persistent object creation leaked into player activity")
assert(find(create_at,first,"object_result").code=="created")
assert(find(create_at,first,"object_entry") and find(create_at,second,"object_entry"),
   "subscribers did not receive live creation")

local occupied_at=#sent+1
local occupied=buoy("buoy_b2","b2","Halir")
assert(receive(second,{type="object_create",node="b2",request=4,
   object_id=occupied.id,object=assert(Object.encode(occupied))}))
assert(find(occupied_at,second,"object_result").code=="occupied")

local delete_at=#sent+1
assert(receive(second,{type="object_delete",node="b2",request=5,
   object_id="buoy_a1"}))
assert(not service:dump_objects().buoy_a1 and dirty==2)
assert(find(delete_at,first,"object_deleted")
   and find(delete_at,second,"object_deleted"),
   "cascading deletion was not pushed")
local duplicate_at=#sent+1
assert(receive(second,{type="object_delete",node="b2",request=6,
   object_id="buoy_a1"}))
assert(find(duplicate_at,second,"object_result").code=="not_found",
   "duplicate destruction report was not idempotent")

-- A two-way relationship is installed and removed as one logical record.
local wormhole={
   id="worm_b2",kind="two_way_wormhole",owner="b2",created=1,revision=1,
   data={},
   endpoints={
      {id="worm_b2_a",system="Halir",x=0,y=0,dir=0,role="mouth",
         visible=true,target="worm_b2_b"},
      {id="worm_b2_b",system="Arandon",x=10,y=20,dir=1,role="mouth",
         visible=true,target="worm_b2_a"},
   },
}
assert(receive(second,{type="object_create",node="b2",request=8,
   object_id=wormhole.id,object=assert(Object.encode(wormhole))}))
assert(service:dump_objects().worm_b2
   and #service:dump_objects().worm_b2.endpoints==2,
   "two-way wormhole was partially created")
local forbidden_at=#sent+1
assert(receive(first,{type="object_delete",node="a1",request=9,
   object_id=wormhole.id}))
assert(find(forbidden_at,first,"object_result").code=="forbidden"
   and service:dump_objects().worm_b2,
   "message-buoy observer deletion leaked to a wormhole")
assert(receive(second,{type="object_delete",node="b2",request=10,
   object_id=wormhole.id}))
assert(not service:dump_objects().worm_b2,
   "two-way wormhole deletion left an endpoint behind")

-- Capacity rejects a new logical object without evicting an old one.
local full={}
for index=1,Object.MAX_OBJECTS do full["post_"..index]={} end
local capacity_service=Directory.new{
   node_id="d1",objects=full,send=function(_peer,_packet) return true end,
}
local peer={}
capacity_service:connect(peer,"127.0.0.1:10003")
capacity_service:receive(peer,assert(codec.encode{
   type="hello",node="c3",cap="player",name="Full"}))
local post={
   id="new_post",kind="registration_post",owner="c3",created=1,revision=1,
   data={},endpoints={{id="new_post_p",system="Halir",x=0,y=0,dir=0,
      role="physical",visible=true}},
}
assert(capacity_service:receive(peer,assert(codec.encode{
   type="object_create",node="c3",request=7,object_id=post.id,
   object=assert(Object.encode(post))})))
assert(not full.new_post)

print("ok - persistent-object directory protocol")
