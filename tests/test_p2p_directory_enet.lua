package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local enet=require "enet"
local codec=require "multiplayer.p2p.codec"
local Directory=require "multiplayer.p2p.directory"
local Object=require "multiplayer.p2p.objects"

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

local host_ready,guest_ready,hint,host_punch,guest_punch
local deadline=os.clock()+2
while (not hint or not host_punch or not guest_punch) and os.clock()<deadline do
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
         host_peer:send(assert(codec.encode{type="hello",node="10",cap="player",name="Host",
            endpoint=advertised}),0,"reliable")
         host_peer:send(assert(codec.encode{type="claim",node="10",system="Delta Polaris",
            claim="10:1",endpoint=advertised}),0,"reliable")
      elseif event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="punch" then host_punch=message end
      end
      event=host_client:service(0)
   end

   event=guest_client:service(0)
   while event do
      if event.type=="connect" and not guest_ready then
         guest_ready=true
         guest_peer:send(assert(codec.encode{type="hello",node="20",cap="player",name="Guest",
            endpoint=guest_client:get_socket_address()}),0,"reliable")
         guest_peer:send(assert(codec.encode{type="query",node="20",system="Delta Polaris"}),0,"reliable")
      elseif event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="hint" then hint=message end
         if message.type=="punch" then guest_punch=message end
      end
      event=guest_client:service(0)
   end
end

assert(hint,"real ENet directory did not return a hint")
assert(hint.host=="10")
assert(hint.endpoint=="127.0.0.1:"..advertised:match(":(%d+)$"))
assert(hint.ttl>=1 and hint.ttl<=60)
assert(host_punch and host_punch.peer=="20")
assert(guest_punch and guest_punch.peer=="10")

local buoy={
   id="enet_buoy",kind="message_buoy",owner="10",created=1,revision=1,
   data={text="ENet loopback",captain="Host"},
   endpoints={{id="enet_buoy_p",system="Delta Polaris",x=1,y=2,dir=3,
      role="physical",visible=true}},
}
host_peer:send(assert(codec.encode{
   type="object_query",node="10",system="Delta Polaris",request=1,
}),0,"reliable")
guest_peer:send(assert(codec.encode{
   type="object_query",node="20",system="Delta Polaris",request=2,
}),0,"reliable")
host_peer:send(assert(codec.encode{
   type="object_create",node="10",request=3,object_id=buoy.id,
   object=assert(Object.encode(buoy)),
}),0,"reliable")

local create_result,host_entry,guest_entry
deadline=os.clock()+2
while (not create_result or not host_entry or not guest_entry)
      and os.clock()<deadline do
   local event=server:service(5)
   while event do
      if event.type=="receive" then assert(service:receive(event.peer,event.data)) end
      event=server:service(0)
   end
   event=host_client:service(0)
   while event do
      if event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="object_result" and message.action=="create" then
            create_result=message
         elseif message.type=="object_entry" then host_entry=message end
      end
      event=host_client:service(0)
   end
   event=guest_client:service(0)
   while event do
      if event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="object_entry" then guest_entry=message end
      end
      event=guest_client:service(0)
   end
end
assert(create_result and create_result.ok==1)
assert(host_entry and guest_entry,
   "real ENet subscriptions did not receive live object creation")
assert(Object.decode(guest_entry.object).id=="enet_buoy")

guest_peer:send(assert(codec.encode{
   type="object_delete",node="20",request=4,object_id="enet_buoy",
}),0,"reliable")
local host_deleted,guest_deleted
deadline=os.clock()+2
while (not host_deleted or not guest_deleted) and os.clock()<deadline do
   local event=server:service(5)
   while event do
      if event.type=="receive" then assert(service:receive(event.peer,event.data)) end
      event=server:service(0)
   end
   event=host_client:service(0)
   while event do
      if event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="object_deleted" then host_deleted=message end
      end
      event=host_client:service(0)
   end
   event=guest_client:service(0)
   while event do
      if event.type=="receive" then
         local message=assert(codec.decode(event.data))
         if message.type=="object_deleted" then guest_deleted=message end
      end
      event=guest_client:service(0)
   end
end
assert(host_deleted and guest_deleted and not service:dump_objects().enet_buoy,
   "real ENet object deletion did not cascade to subscribers")

host_client:destroy(); guest_client:destroy(); server:destroy()
print("ok - real ENet directory loopback")
