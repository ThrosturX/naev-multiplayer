#!/usr/bin/env lua
local script=arg[0] or "directory/main.lua"
local root=script:match("^(.*)/directory/main%.lua$") or "."
package.path=root.."/scripts/?.lua;"..root.."/scripts/?/init.lua;"..package.path

local enet=require "enet"
local Directory=require "multiplayer.p2p.directory"

local bind=arg[1] or os.getenv("MP2P_DIRECTORY_BIND") or "*:60939"
local node_id=os.getenv("MP2P_DIRECTORY_NODE_ID")
if not node_id or not node_id:match("^[%x]+$") then
   math.randomseed(os.time())
   node_id=string.format("%x%08x",os.time(),math.random(0,0x7fffffff))
end

local host=assert(enet.host_create(bind,256,1),"unable to bind "..bind)
local service=Directory.new{
   node_id=node_id,
   send=function(peer,packet) return peer:send(packet,0,"reliable") end,
   disconnect=function(peer) peer:disconnect_now() end,
}

io.stdout:write("MP2P/1 directory listening on ",bind,"\n")
io.stdout:flush()

while true do
   local event=host:service(1000)
   while event do
      if event.type=="connect" then
         service:connect(event.peer,tostring(event.peer))
      elseif event.type=="receive" then
         service:receive(event.peer,event.data)
      elseif event.type=="disconnect" then
         service:disconnect_peer(event.peer)
      end
      event=host:service(0)
   end
   service:prune()
end
