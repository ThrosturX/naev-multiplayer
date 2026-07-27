package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local clock=100
local cache={}
naev={
   ticks=function() return clock end,
   cache=function() return cache end,
}
player={name=function() return "Local Captain" end}

local events={}
local sent={}
local peer={
   send=function(_self,packet)
      sent[#sent+1]=packet
   end,
   disconnect_now=function() end,
}
local host={
   connect=function() return peer end,
   get_socket_address=function() return "0.0.0.0:12345" end,
   service=function()
      return table.remove(events,1)
   end,
}
package.preload.enet=function()
   return {host_create=function() return host end}
end
package.preload["multiplayer.pod_racing"]=function()
   return {
      local_profile=function(node,track)
         return {
            type="contestant_register",node=node,track=track,division=1,
            name="Local Captain",ship="Hyena",
            outfits="Laser",slots="1:Laser",
         }
      end,
   }
end

local codec=require "multiplayer.p2p.codec"
local network=require "multiplayer.pod_racing_network"
assert(not network.start{
   enabled=true,directory="127.0.0.1:60939",node_id="a1",captain="Stale Captain",
})
assert(network.start({
   enabled=true,directory="127.0.0.1:60939",node_id="a1",captain="Local Captain",
},"death_knot"))

events[#events+1]={type="connect",peer=peer}
network.update()
assert(codec.decode(sent[1]).type=="hello")

events[#events+1]={type="receive",peer=peer,data=assert(codec.encode{
   type="hello",node="d1",cap="directory",
   features="activity,contestants,contestants_by_track",
})}
network.update()
local requests={}
for _index,packet in ipairs(sent) do
   local message=assert(codec.decode(packet))
   if message.type=="contestant_query" then
      assert(message.limit==11)
      assert(message.track=="death_knot")
      requests[message.division]=message.request
   elseif message.type=="contestant_register" then
      assert(message.track=="death_knot")
   end
end
assert(requests[1] and requests[2] and requests[3])

for division=1,3 do
   if division==1 then
      events[#events+1]={type="receive",peer=peer,data=assert(codec.encode{
         type="contestant_entry",node="d1",contestant="b2",
         track="death_knot",
         division=division,request=requests[division],
         name="Remote",ship="Shark",outfits="Laser",slots="1:Laser",
      })}
   end
   events[#events+1]={type="receive",peer=peer,data=assert(codec.encode{
      type="contestant_done",node="d1",division=division,
      track="death_knot",
      request=requests[division],count=division==1 and 1 or 0,
   })}
end
assert(not network.update())
assert(cache.multiplayer_contestants)
assert(cache.multiplayer_contestants.node_id=="a1")
assert(cache.multiplayer_contestants.captain=="Local Captain")
assert(cache.multiplayer_contestants.directory=="127.0.0.1:60939")
assert(cache.multiplayer_contestants.track=="death_knot")
assert(cache.multiplayer_contestants.divisions[1][1].name=="Remote")
assert(#cache.multiplayer_contestants.divisions[2]==0)

-- Omitting the track retains the original generic request shape.
local previous=#sent
assert(network.start{
   enabled=true,directory="127.0.0.1:60939",node_id="a1",
   captain="Local Captain",
})
events[#events+1]={type="connect",peer=peer}
network.update()
events[#events+1]={type="receive",peer=peer,data=assert(codec.encode{
   type="hello",node="d1",cap="directory",features="activity,contestants",
})}
network.update()
for index=previous+1,#sent do
   local message=assert(codec.decode(sent[index]))
   if message.type=="contestant_register" or message.type=="contestant_query" then
      assert(message.track==nil)
   end
end
network.stop(true)

print("ok - death race contestant network")
