package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local enet=require "enet"
local codec=require "multiplayer.p2p.codec"
local Directory=require "multiplayer.p2p.directory"

local server=assert(enet.host_create("*:0",16,1))
local server_port=assert(server:get_socket_address():match(":(%d+)$"))
local host_client=assert(enet.host_create("*:0",2,1))
local guest_client=assert(enet.host_create("*:0",2,1))
local advertised=host_client:get_socket_address()
local host_peer=host_client:connect("127.0.0.1:"..server_port)
local guest_peer=guest_client:connect("127.0.0.1:"..server_port)

local service=Directory.new{
   node_id="d1",
   send=function(peer,packet) peer:send(packet,0,"reliable"); return true end,
   disconnect=function(peer) peer:disconnect_now() end,
}

local host_ready,guest_ready,hint
local deadline=os.clock()+2
while not hint and os.clock()<deadline do
   local event=server:service(5)
   while event do
      if event.type=="connect" then service:connect(event.peer,tostring(event.peer))
      elseif event.type=="receive" then assert(service:receive(event.peer,event.data))
      elseif event.type=="disconnect" then service:disconnect_peer(event.peer) end
      event=server:service(0)
   end

   event=host_client:service(0)
   while event do
      if event.type=="connect" and not host_ready then
         host_ready=true
         host_peer:send(assert(codec.encode{type="hello",node="10",cap="player",name="Host"}),0,"reliable")
         host_peer:send(assert(codec.encode{type="claim",node="10",system="Delta Polaris",
            claim="10:1",endpoint=advertised}),0,"reliable")
      end
      event=host_client:service(0)
   end

   event=guest_client:service(0)
   while event do
      if event.type=="connect" and not guest_ready then
         guest_ready=true
         guest_peer:send(assert(codec.encode{type="hello",node="20",cap="player",name="Guest"}),0,"reliable")
         guest_peer:send(assert(codec.encode{type="query",node="20",system="Delta Polaris"}),0,"reliable")
      elseif event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="hint" then hint=message end
      end
      event=guest_client:service(0)
   end
end

assert(hint,"real ENet directory did not return a hint")
assert(hint.host=="10")
assert(hint.endpoint=="127.0.0.1:"..advertised:match(":(%d+)$"))
assert(hint.ttl>=1 and hint.ttl<=60)

host_client:destroy(); guest_client:destroy(); server:destroy()
print("ok - real ENet directory loopback")
