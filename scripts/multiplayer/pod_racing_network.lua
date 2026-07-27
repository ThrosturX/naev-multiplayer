-- Short-lived directory client used only by the Qex contestant-roster event.
local codec = require "multiplayer.p2p.codec"
local pod = require "multiplayer.pod_racing"
local enet = require "enet"

local network = {}
local TIMEOUT = 8
local MAX_EVENTS_PER_UPDATE = 24
local MAX_CONTESTANTS_PER_DIVISION = 11
local job

local function now () return naev.ticks() end

local function send ( message )
   local packet=codec.encode(message)
   if not packet or not job or not job.peer then return false end
   job.peer:send(packet,0,"reliable")
   return true
end

function network.stop ( clear_cache )
   if job and job.peer then job.peer:disconnect_now() end
   job=nil
   if clear_cache then naev.cache().multiplayer_contestants=nil end
end

function network.active () return job~=nil end

local function publish ()
   naev.cache().multiplayer_contestants={
      received=now(),
      directory=job.directory,
      node_id=job.node,
      captain=job.captain,
      track=job.track,
      divisions=job.divisions,
   }
end

local function request_rosters ()
   local profile=pod.local_profile(job.node,job.track)
   if not profile or not send(profile) then return false end
   for division=1,3 do
      job.request=job.request+1
      local request=job.request
      job.pending[division]={request=request,entries={}}
      if not send{
         type="contestant_query",
         node=job.node,
         division=division,
         track=job.track,
         request=request,
         limit=MAX_CONTESTANTS_PER_DIVISION,
      } then return false end
   end
   return true
end

local function receive ( packet )
   local message=codec.decode(packet)
   if not message then return end
   if not job.verified then
      if message.type~="hello" or message.cap~="directory"
            or not (","..(message.features or "")..","):find(
               ",contestants,",1,true) then
         network.stop(true)
         return
      end
      job.verified=true
      job.directory_node=message.node
      if not request_rosters() then network.stop(true) end
      return
   end
   if message.node~=job.directory_node then return end
   if message.type~="contestant_entry" and message.type~="contestant_done" then
      return
   end
   local pending=job.pending[message.division]
   if not pending or pending.request~=message.request then return end
   if message.track~=job.track then return end
   if message.type=="contestant_entry" then
      if #pending.entries>=MAX_CONTESTANTS_PER_DIVISION then return end
      for _index,entry in ipairs(pending.entries) do
         if entry.contestant==message.contestant then return end
      end
      pending.entries[#pending.entries+1]={
         contestant=message.contestant,
         division=message.division,
         name=message.name,
         ship=message.ship,
         ship_fallbacks=message.ship_fallbacks or "",
         outfits=message.outfits,
         slots=message.slots,
      }
      return
   end
   if message.count~=#pending.entries then return end
   job.divisions[message.division]=pending.entries
   job.pending[message.division]=nil
   if next(job.pending)==nil then
      publish()
      network.stop(false)
   end
end

function network.start ( config, track )
   network.stop(true)
   if type(config)~="table" or config.enabled~=true
         or type(config.directory)~="string" or config.directory==""
         or type(config.node_id)~="string"
         or not config.node_id:match("^[%x]+$")
         or type(config.captain)~="string"
         or config.captain~=player.name()
         or (track~=nil and (type(track)~="string" or track==""
            or #track>64 or track:find("[^%w_%-]"))) then
      return nil,"contestant directory unavailable"
   end
   local host=enet.host_create("*:0")
   if not host then return nil,"unable to create contestant client" end
   local peer=host:connect(config.directory)
   if not peer then return nil,"unable to connect contestant directory" end
   job={
      host=host,
      peer=peer,
      node=config.node_id,
      captain=config.captain,
      track=track,
      directory=config.directory,
      endpoint=tostring(host:get_socket_address()),
      verified=false,
      request=0,
      pending={},
      divisions={},
      deadline=now()+TIMEOUT,
   }
   return true
end

function network.update ()
   if not job then return false end
   local current=job
   local processed=0
   local event=current.host:service(0)
   while event and job==current do
      processed=processed+1
      if event.type=="connect" then
         send{
            type="hello",
            node=current.node,
            cap="player",
            name=player.name(),
            endpoint=current.endpoint,
         }
      elseif event.type=="receive" then
         receive(event.data)
      elseif event.type=="disconnect" then
         network.stop(true)
      end
      if processed>=MAX_EVENTS_PER_UPDATE then break end
      event=current.host:service(0)
   end
   if job==current and now()>=current.deadline then network.stop(true) end
   return job~=nil
end

return network
