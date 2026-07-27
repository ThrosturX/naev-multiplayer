#!/usr/bin/env lua
local script=arg[0] or "directory/main.lua"
local root=script:match("^(.*)/directory/main%.lua$") or "."
package.path=root.."/scripts/?.lua;"..root.."/scripts/?/init.lua;"..package.path

local enet=require "enet"
local Directory=require "multiplayer.p2p.directory"
local ContestantStore=require "multiplayer.contestant_store"
local ContestantTrackStore=require "multiplayer.contestant_track_store"
local ObjectStore=require "multiplayer.object_store"

local bind=arg[1] or os.getenv("MP2P_DIRECTORY_BIND") or "*:60939"
local contestant_path=arg[2] or os.getenv("MP2P_CONTESTANT_FILE")
   or "/var/lib/naev-multiplayer/contestants.db"
local contestant_track_path=arg[3] or os.getenv("MP2P_CONTESTANT_TRACK_FILE")
   or "/var/lib/naev-multiplayer/contestant-tracks.db"
local object_path=arg[4] or os.getenv("MP2P_OBJECT_FILE")
   or "/var/lib/naev-multiplayer/objects.db"
local node_id=os.getenv("MP2P_DIRECTORY_NODE_ID")
math.randomseed(os.time())
if not node_id or not node_id:match("^[%x]+$") then
   node_id=string.format("%x%08x",os.time(),math.random(0,0x7fffffff))
end

local host=assert(enet.host_create(bind,256,1),"unable to bind "..bind)
local contestants={}
local contestant_file=io.open(contestant_path,"rb")
if contestant_file then
   contestants=ContestantStore.decode(contestant_file:read("*a"))
   contestant_file:close()
end
local track_contestants={}
local contestant_track_file=io.open(contestant_track_path,"rb")
if contestant_track_file then
   track_contestants=ContestantTrackStore.decode(
      contestant_track_file:read("*a"))
   contestant_track_file:close()
end
local objects={}
local object_file=io.open(object_path,"rb")
if object_file then
   local warning
   objects,warning=ObjectStore.decode(object_file:read("*a"))
   object_file:close()
   if warning then io.stderr:write("object database: ",warning,"\n") end
end
local contestants_dirty=false
local track_contestants_dirty=false
-- Materialize the separately versioned database on first start so operators
-- can verify the feature without waiting for the first player-created object.
local objects_dirty=object_file==nil
local service=Directory.new{
   node_id=node_id,
   contestants=contestants,
   contestant_dirty=function() contestants_dirty=true end,
   track_contestants=track_contestants,
   track_contestant_dirty=function() track_contestants_dirty=true end,
   objects=objects,
   object_dirty=function() objects_dirty=true end,
   send=function(peer,packet) return peer:send(packet,0,"reliable") end,
   disconnect=function(peer) peer:disconnect_now() end,
}

local function save_contestants ()
   if not contestants_dirty then return end
   local temporary=contestant_path..".tmp"
   local file,err=io.open(temporary,"wb")
   if not file then
      io.stderr:write("unable to write contestant roster: ",tostring(err),"\n")
      return
   end
   file:write(ContestantStore.encode(service:dump_contestants()))
   file:close()
   local ok,rename_err=os.rename(temporary,contestant_path)
   if not ok then
      io.stderr:write("unable to replace contestant roster: ",
         tostring(rename_err),"\n")
      return
   end
   contestants_dirty=false
end

local function save_objects ()
   if not objects_dirty then return end
   local temporary=object_path..".tmp"
   local file,err=io.open(temporary,"wb")
   if not file then
      io.stderr:write("unable to write persistent objects: ",tostring(err),"\n")
      return
   end
   file:write(ObjectStore.encode(service:dump_objects()))
   file:close()
   local ok,rename_err=os.rename(temporary,object_path)
   if not ok then
      io.stderr:write("unable to replace persistent objects: ",
         tostring(rename_err),"\n")
      return
   end
   objects_dirty=false
end

local function save_track_contestants ()
   if not track_contestants_dirty then return end
   local temporary=contestant_track_path..".tmp"
   local file,err=io.open(temporary,"wb")
   if not file then
      io.stderr:write("unable to write track contestant roster: ",
         tostring(err),"\n")
      return
   end
   file:write(ContestantTrackStore.encode(service:dump_track_contestants()))
   file:close()
   local ok,rename_err=os.rename(temporary,contestant_track_path)
   if not ok then
      io.stderr:write("unable to replace track contestant roster: ",
         tostring(rename_err),"\n")
      return
   end
   track_contestants_dirty=false
end

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
   save_contestants()
   save_track_contestants()
   save_objects()
end
