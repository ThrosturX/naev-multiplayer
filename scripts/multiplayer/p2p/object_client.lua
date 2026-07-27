-- Optional persistent-space-object directory transport.
--
-- This deliberately does not share the gameplay ENet host. Gameplay is
-- serviced by hook.update, which Naev suspends while paused; this client is
-- serviced by a recurring safe hook and therefore remains live for solo hosts.
local codec = require "multiplayer.p2p.codec"
local enet = require "enet"

local ObjectClient = {}
ObjectClient.__index = ObjectClient

local MAX_EVENTS = 24
local RECONNECT_INTERVAL = 5

local function supports_objects ( message )
   return type(message.features)=="string"
      and (","..message.features..","):find(",objects,",1,true)~=nil
end

function ObjectClient.new ( options )
   return setmetatable({
      endpoint=assert(options.endpoint),
      node=assert(options.node),
      name=assert(options.name),
      now=assert(options.now),
      on_ready=assert(options.on_ready),
      on_message=assert(options.on_message),
      on_disconnect=assert(options.on_disconnect),
      host=nil, peer=nil, directory_node=nil, verified=false,
      last_connect=0,
   },ObjectClient)
end

function ObjectClient:available ()
   return self.verified and self.peer~=nil
end

-- Compatible with an ENet peer so the object protocol sender can remain
-- oblivious to reconnects and transport ownership.
function ObjectClient:send ( packet, channel, flag )
   if not self:available() then return end
   self.peer:send(packet,channel,flag)
end

function ObjectClient:connect ()
   if not self.host or self.peer or self.endpoint=="" then return false end
   local peer=self.host:connect(self.endpoint)
   if not peer then return false end
   self.peer=peer
   self.verified=false
   self.directory_node=nil
   self.last_connect=self.now()
   return true
end

function ObjectClient:start ()
   if self.endpoint=="" then return false end
   local ok,host=pcall(enet.host_create,"*:0")
   if not ok or not host then return nil,"unable to create object client" end
   self.host=host
   self:connect()
   return true
end

function ObjectClient:stop ()
   if self.peer then self.peer:disconnect_now() end
   self.host=nil
   self.peer=nil
   self.directory_node=nil
   self.verified=false
end

function ObjectClient:send_hello ()
   if not self.peer then return end
   local packet=codec.encode{
      type="hello",node=self.node,cap="player",name=self.name,
      endpoint=tostring(self.host:get_socket_address()),
   }
   if packet then self.peer:send(packet,0,"reliable") end
end

function ObjectClient:disconnect ()
   local was_connected=self.peer~=nil or self.verified
   self.peer=nil
   self.directory_node=nil
   self.verified=false
   if was_connected then self.on_disconnect() end
end

function ObjectClient:update ()
   if not self.host then return false end
   local processed=0
   local event=self.host:service(0)
   while event do
      processed=processed+1
      if event.type=="connect" then
         if not self.peer then self.peer=event.peer end
         if event.peer==self.peer then self:send_hello() end
      elseif event.type=="receive" and event.peer==self.peer then
         local message,err=codec.decode(event.data)
         if not message then
            print("P2P: rejected object-directory packet: "..tostring(err))
         elseif not self.verified then
            if message.type=="hello" and message.cap=="directory"
                  and message.node~=self.node and supports_objects(message) then
               self.verified=true
               self.directory_node=message.node
               self.on_ready(self)
            else
               event.peer:disconnect_now()
            end
         elseif message.node==self.directory_node then
            self.on_message(message)
         end
      elseif event.type=="disconnect" and event.peer==self.peer then
         self:disconnect()
      end
      if processed>=MAX_EVENTS then break end
      event=self.host:service(0)
   end
   if not self.peer and self.now()-self.last_connect>=RECONNECT_INTERVAL then
      self:connect()
   end
   return true
end

return ObjectClient
