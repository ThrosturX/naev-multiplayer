package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Object=require "multiplayer.p2p.objects"
local Directory=require "multiplayer.p2p.object_directory"
local Expiry=require "multiplayer.p2p.object_expiry"
local Wormholes=require "multiplayer.p2p.wormhole_objects"

local clock=100
local sent={}
local dirty=0
local permanent={
   id="post_keep",kind="registration_post",owner="a1",created=0,revision=1,
   data={},endpoints={{id="post_keep_p",system="Halir",x=0,y=0,dir=0,
      role="physical",visible=true}},
}
local service=Directory.new{
   node_id="d1",now=function() return clock end,
   values={post_keep=permanent},
   dirty=function() dirty=dirty+1 end,
   send=function(peer,message)
      sent[#sent+1]={peer=peer,message=message}
      return true
   end,
}
local peer={}
service.subscriptions[peer]="Halir"

local function wormhole ( id, kind )
   if kind=="one_way_wormhole" then
      return {
         id=id,kind=kind,owner="a1",created=1,revision=1,data={},
         endpoints={
            {id=id.."_a",system="Halir",x=1,y=2,dir=0,role="entrance",
               visible=true,target=id.."_b"},
            {id=id.."_b",system="Arandon",x=3,y=4,dir=1,
               role="destination",visible=false},
         },
      }
   end
   return {
      id=id,kind="two_way_wormhole",owner="a1",created=1,revision=1,data={},
      endpoints={
         {id=id.."_a",system="Halir",x=1,y=2,dir=0,role="mouth",
            visible=true,target=id.."_b"},
         {id=id.."_b",system="Arandon",x=3,y=4,dir=1,role="mouth",
            visible=true,target=id.."_a"},
      },
   }
end

assert(Expiry.lifetime("one_way_wormhole")==120)
assert(Expiry.lifetime("two_way_wormhole")==300)
assert(Expiry.lifetime("registration_post")==nil)
assert(Expiry.expires_at(wormhole("one", "one_way_wormhole"))==121)
assert(not Expiry.expires_at(permanent))

local first=wormhole("worm_a1","two_way_wormhole")
assert(service:create(peer,"a1",{request=1,object_id=first.id,
   object=assert(Object.encode(first))}))
assert(service.values.worm_a1 and service.values.worm_a1.created==clock)
assert(Expiry.expires_at(service.values.worm_a1)==400)
assert(Wormholes.expires_at(service.values.worm_a1)==400)

local second=wormhole("worm_a2","two_way_wormhole")
local before=#sent
assert(service:create(peer,"a1",{request=2,object_id=second.id,
   object=assert(Object.encode(second))}))
assert(not service.values.worm_a2)
assert(sent[#sent].message.type=="object_result"
   and sent[#sent].message.code=="occupied")
assert(#sent==before+1)

clock=399
assert(service:prune()==0 and service.values.worm_a1)
assert(service.values.post_keep)
clock=400
assert(service:prune()==1 and not service.values.worm_a1)
assert(service.values.post_keep,"permanent object was pruned")
assert(dirty==2)
local deletion=sent[#sent].message
assert(deletion.type=="object_deleted" and deletion.object_id=="worm_a1")

local emergency=wormhole("worm_emergency","one_way_wormhole")
assert(service:create(peer,"a1",{request=3,object_id=emergency.id,
   object=assert(Object.encode(emergency))}))
assert(service.values.worm_emergency
   and service.values.worm_emergency.created==clock)
assert(Expiry.expires_at(service.values.worm_emergency)==520)
assert(Wormholes.endpoint_in(service.values.worm_emergency,"Halir"))
assert(not Wormholes.endpoint_in(service.values.worm_emergency,"Arandon"))

local target_peer={}
service:query(target_peer,{request=4,system="Arandon"})
local target_done=sent[#sent].message
assert(target_done.type=="object_done" and target_done.count==0)

clock=519
assert(service:prune()==0 and service.values.worm_emergency)
clock=520
assert(service:prune()==1 and not service.values.worm_emergency)
assert(service.values.post_keep)
assert(dirty==4)
local emergency_deletion=sent[#sent].message
assert(emergency_deletion.type=="object_deleted"
   and emergency_deletion.object_id=="worm_emergency")

print("ok - generic persistent-object expiry")
