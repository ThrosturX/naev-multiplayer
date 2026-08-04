package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

_=function ( value ) return value end
naev={ticks=function () return 1 end}
rnd={rnd=function () return 1 end}

local events={}
local destroyed=false
local service_calls=0
local connect_peer
local peer={
   send=function () end,
   disconnect_now=function () end,
   disconnect_later=function () end,
}
local host={
   connect=function () return connect_peer end,
   get_socket_address=function () return "0.0.0.0:62000" end,
   service=function ()
      assert(not destroyed,"serviced a destroyed ENet host")
      service_calls=service_calls+1
      return table.remove(events,1)
   end,
   destroy=function () destroyed=true end,
}
package.preload.enet=function ()
   return {host_create=function () return host end}
end

local codec=require "multiplayer.p2p.codec"
local transient=require "multiplayer.p2p.transient"
connect_peer=peer
assert(transient.start{
   directory="127.0.0.1:60939",
   node_id="a1",
   name="Test Pilot",
   ship="Llama",
   text="test",
   target_systems=function () return {} end,
   position=function () return 0,0,0 end,
})

-- An unsupported directory hello finishes the job from inside the receive
-- handler. update() must return without servicing the destroyed host again.
events[1]={type="receive",peer=peer,data=assert(codec.encode{
   type="hello",node="d1",cap="directory",features="objects",
})}
transient.update()
assert(destroyed,"transient teardown did not destroy its ENet host")
assert(not transient.active(),"transient job survived teardown")
assert(service_calls==1,"transient update serviced its host after teardown")

destroyed=false
connect_peer=nil
assert(not transient.start{
   directory="127.0.0.1:60939",
   node_id="a1",
   name="Test Pilot",
   ship="Llama",
   text="test",
   target_systems=function () return {} end,
   position=function () return 0,0,0 end,
})
assert(destroyed,"failed transient connection leaked its ENet host")

print("ok - transient teardown during update")
