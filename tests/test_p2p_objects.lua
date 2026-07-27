package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local Object=require "multiplayer.p2p.objects"
local Store=require "multiplayer.object_store"

local function endpoint ( id, system_name, role, visible, target )
   return {id=id,system=system_name,x=12.5,y=-90,dir=1.25,
      role=role,visible=visible,target=target}
end

local buoy={
   id="buoy_01",kind="message_buoy",owner="a1",created=10,revision=1,
   data={text="Mind the asteroids.",captain="Aster"},
   endpoints={endpoint("buoy_01_physical","Gamma Polaris","physical",true)},
}
local one_way={
   id="worm_01",kind="one_way_wormhole",owner="a1",created=11,revision=1,
   data={},
   endpoints={
      endpoint("worm_01_source","Gamma Polaris","entrance",true,"worm_01_dest"),
      endpoint("worm_01_dest","Delta Pavonis","destination",false),
   },
}
local two_way={
   id="worm_02",kind="two_way_wormhole",owner="b2",created=12,revision=1,
   data={},
   endpoints={
      endpoint("worm_02_a","Gamma Polaris","mouth",true,"worm_02_b"),
      endpoint("worm_02_b","Delta Pavonis","mouth",true,"worm_02_a"),
   },
}
local post={
   id="post_01",kind="registration_post",owner="c3",created=13,revision=1,
   data={},
   endpoints={endpoint("post_01_physical","Halir","physical",true)},
}

for _index,value in ipairs{buoy,one_way,two_way,post} do
   local packed=assert(Object.encode(value))
   local decoded=assert(Object.decode(packed))
   assert(decoded.id==value.id and decoded.kind==value.kind)
   assert(#decoded.endpoints==#value.endpoints)
end
local decoded_one=assert(Object.decode(assert(Object.encode(one_way))))
assert(decoded_one.endpoints[1].target=="worm_01_dest"
   or decoded_one.endpoints[2].target=="worm_01_dest")
local decoded_two=assert(Object.decode(assert(Object.encode(two_way))))
local linked={}
for _index,value in ipairs(decoded_two.endpoints) do linked[value.id]=value.target end
assert(linked.worm_02_a=="worm_02_b" and linked.worm_02_b=="worm_02_a")
local decoded_post=assert(Object.decode(assert(Object.encode(post))))
assert(decoded_post.id=="post_01" and next(decoded_post.data)==nil,
   "registration post embedded mutable registrations")

local values={buoy_01=buoy,worm_01=one_way,worm_02=two_way,post_01=post}
local persisted=Store.encode(values)
local restored,warning=Store.decode(persisted)
assert(not warning and restored.worm_02 and restored.post_01)
local recovered,recovery_warning=Store.decode(
   persisted.."not%2valid\n"..require("multiplayer.p2p.codec").escape(
      assert(Object.encode(buoy))).."\n")
assert(recovered.worm_01 and recovery_warning,
   "corrupt records did not preserve valid database entries")

local function rejected ( value )
   assert(not Object.validate(value))
end
local dangling=assert(Object.decode(assert(Object.encode(one_way))))
dangling.endpoints[1].target="outside"
rejected(dangling)
local duplicate=assert(Object.decode(assert(Object.encode(two_way))))
duplicate.endpoints[2].id=duplicate.endpoints[1].id
rejected(duplicate)
local invalid_coordinate=assert(Object.decode(assert(Object.encode(post))))
invalid_coordinate.endpoints[1].x=math.huge
rejected(invalid_coordinate)
local excessive=assert(Object.decode(assert(Object.encode(post))))
for index=2,Object.MAX_ENDPOINTS+1 do
   excessive.endpoints[index]=endpoint("extra_"..index,"Halir","physical",true)
end
rejected(excessive)
local partial=assert(Object.decode(assert(Object.encode(two_way))))
partial.endpoints[2].target=nil
rejected(partial)
assert(not Object.decode("malformed"))

local existing={buoy_01=buoy}
local second_buoy=assert(Object.decode(assert(Object.encode(buoy))))
second_buoy.id="buoy_02"
second_buoy.endpoints[1].id="buoy_02_physical"
assert(not Object.policy_create(second_buoy,"a1",existing))
assert(Object.policy_create(one_way,"a1",existing),
   "message-buoy uniqueness leaked into wormhole policy")
assert(Object.policy_delete(buoy,"ffff"),
   "observer deletion was not allowed for a message buoy")
assert(not Object.policy_delete(one_way,"ffff"),
   "observer deletion leaked into wormhole policy")

print("ok - typed persistent objects")
