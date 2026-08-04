-- Sender-only transient participant bridge. Directory discovery is MP2P/1;
-- the temporary participant speaks the one current MP2G/2 gameplay format.
local directory_codec = require "multiplayer.p2p.codec"
local gameplay_codec = require "multiplayer.p2p.gameplay_codec"
local enet = require "enet"

local transient = {}

local DIRECTORY_TIMEOUT = 8
local TARGET_TIMEOUT = 8
local DRAIN_TIMEOUT = 3
local MAX_EVENTS_PER_UPDATE = 24

local job

local function now ()
   return naev.ticks()
end

local function send_packet ( peer, message, wire_codec )
   local packet = (wire_codec or directory_codec).encode(message)
   if not packet or not peer then return false end
   peer:send(packet, 0, "reliable")
   return true
end

local function remove_peer ( peer, immediate )
   if not peer then return end
   if immediate then peer:disconnect_now()
   else peer:disconnect_later() end
   if job then job.peers[peer] = nil end
end

local function clear_target ()
   if not job then return end
   for peer, meta in pairs(job.peers) do
      if meta.role == "target" then
         peer:disconnect_now()
         job.peers[peer] = nil
      end
   end
   job.candidates = {}
   job.published_peer = nil
   job.expected_node = nil
end

local function finish_job ()
   if not job then return end
   for peer in pairs(job.peers) do
      peer:disconnect_now()
   end
   job.host:destroy()
   job = nil
end

function transient.stop ( kind )
   if job and (not kind or job.kind==kind) then finish_job() end
end

function transient.active ( kind )
   return job ~= nil and (not kind or job.kind==kind)
end

local function base_message ( kind )
   return {
      type = kind,
      node = job.node,
      system = job.target.system,
      visit = job.visit,
      epoch = job.epoch,
   }
end

local start_next_target
local start_next_scan

local function complete_target ()
   if job.on_target then job.on_target(job.target) end
   start_next_target()
end

local function queue_transmission ( peer )
   local x,y,dir=job.position(job.target)
   if not x or not y then return false end
   dir=dir or 0

   local join = base_message("join")
   job.sequence = job.sequence+1
   join.seq = job.sequence

   local entity = job.node.."."..job.visit..".player"
   local manifest = base_message("player_manifest")
   manifest.owner = job.node
   manifest.entity = entity
   manifest.origin = job.node.."."..job.visit..job.origin_suffix
   manifest.ship = job.ship
   manifest.name = job.name
   manifest.outfits = "-"
   manifest.slots = "-"
   manifest.weapsets = "1:"
   manifest.x = x
   manifest.y = y
   manifest.vx = 0
   manifest.vy = 0
   manifest.dir = dir
   manifest.armour = 100
   manifest.shield = 0
   manifest.stress = 0
   manifest.energy = 100
   manifest.target = "-"
   manifest.weapset = 1
   manifest.accel = 0
   manifest.turn = 0
   manifest.reverse = 0
   manifest.primary = 0
   manifest.secondary = 0

   job.sequence = job.sequence+1
   local chat = base_message("chat")
   chat.owner = job.node
   chat.seq = job.sequence
   chat.text = job.text

   local leave = base_message("leave")
   leave.owner = job.node

   if not send_packet(peer, join, gameplay_codec)
         or not send_packet(peer, manifest, gameplay_codec)
         or not send_packet(peer, chat, gameplay_codec)
         or not send_packet(peer, leave, gameplay_codec) then
      return false
   end

   job.phase = "draining"
   job.published_peer = peer
   job.deadline = now()+DRAIN_TIMEOUT

   for candidate, meta in pairs(job.peers) do
      if meta.role == "target" then
         if candidate == peer then candidate:disconnect_later()
         else
            candidate:disconnect_now()
            job.peers[candidate] = nil
         end
      end
   end
   return true
end

local function hello ( peer )
   local meta=job.peers[peer]
   if meta and meta.role=="target" then
      return send_packet(peer,{
         type="hello",node=job.node,name=job.name,
         endpoint=job.endpoint,
      },gameplay_codec)
   end
   return send_packet(peer,{
      type="hello",node=job.node,cap="player",
      name=job.name,endpoint=job.endpoint,
   },directory_codec)
end

local function connect_candidate ( endpoint, expected_node )
   if type(endpoint) ~= "string" or endpoint == ""
         or job.candidates[endpoint] then
      return
   end

   job.candidates[endpoint] = true
   local peer = job.host:connect(endpoint)
   if not peer then return end

   job.peers[peer] = {
      role = "target",
      expected_node = expected_node,
      verified = false,
   }
end

local function parse_activity ( entries )
   local active_systems = {}
   if entries == "-" then return active_systems end

   for line in entries:gmatch("([^;]+)") do
      local encoded, active = line:match("^([^,]+),([01]),%d+$")
      if active == "1" then
         local system_name = directory_codec.unescape(encoded)
         if system_name and system_name ~= "" then
            active_systems[#active_systems+1] = system_name
         end
      end
   end
   return active_systems
end

start_next_scan = function ()
   job.scan_index=job.scan_index+1
   job.scan_system=job.scan_systems[job.scan_index]
   job.scan_selected=nil
   if not job.scan_system then
      if #job.targets==0 and job.on_empty then job.on_empty() end
      job.index=0
      start_next_target()
      return
   end
   job.scan_request=job.scan_request+1
   job.phase="scanning"
   job.deadline=now()+DIRECTORY_TIMEOUT
   if not send_packet(job.directory_peer,{
         type="object_query",node=job.node,
         system=job.scan_system,request=job.scan_request,
      }) then finish_job() end
end

start_next_target = function ()
   clear_target()

   job.index = job.index+1
   job.target = job.targets[job.index]
   if not job.target then
      finish_job()
      return
   end

   local directory = job.directory_peer
   local directory_meta = directory and job.peers[directory]
   if not directory_meta or not directory_meta.verified then
      if job.on_error then
         job.on_error(job.lost_error)
      end
      finish_job()
      return
   end

   job.phase = "connecting"
   job.sequence = 0
   job.visit = string.format("%x",math.max(0,math.floor(now()*1000)))
      ..string.format("%08x",rnd.rnd(0,0x7fffffff))
   job.epoch = nil
   job.deadline = now()+TARGET_TIMEOUT

   if not send_packet(directory, {
      type = "query",
      node = job.node,
      system = job.target.system,
   }) then
      finish_job()
   end
end

local function handle_directory ( peer, message, meta )
   if message.type == "hello" then
      if message.cap ~= "directory" then return end
      meta.verified = true

      local features = ","..(message.features or "")..","
      if not features:find(",activity,", 1, true)
            or (job.inspect_object
               and not features:find(",objects,",1,true)) then
         if job.on_error then job.on_error(job.unsupported) end
         finish_job()
         return
      end

      job.phase = "activity"
      job.deadline = now()+DIRECTORY_TIMEOUT
      send_packet(peer, {
         type = "activity_query",
         node = job.node,
      })
      return
   end
   if not meta.verified then return end

   if message.type == "activity" and job.phase == "activity" then
      local systems = parse_activity(message.entries)
      local targets=job.target_systems(systems) or {}
      if job.inspect_object then
         job.scan_systems=targets
         job.scan_index=0
         job.targets={}
         if #targets==0 then
            if job.on_empty then job.on_empty() end
            finish_job()
         else
            start_next_scan()
         end
      else
         job.targets=targets
         if #targets==0 then
            if job.on_empty then job.on_empty() end
            finish_job()
            return
         end
         job.index = 0
         start_next_target()
      end
      return
   end

   if job.phase=="scanning" then
      if message.type=="object_entry" and message.request==job.scan_request then
         job.scan_selected=job.inspect_object(
            message.object,job.scan_system,job.scan_selected)
      elseif message.type=="object_done"
            and message.request==job.scan_request
            and message.system==job.scan_system then
         if job.scan_selected then
            job.targets[#job.targets+1]=job.scan_selected
         end
         start_next_scan()
      end
      return
   end

   if job.phase ~= "connecting" or not job.target then return end

   if message.type == "hint"
         and message.system == job.target.system then
      job.expected_node = message.host
      connect_candidate(message.endpoint, message.host)
   elseif message.type == "punch"
         and message.system == job.target.system then
      job.expected_node = message.peer
      connect_candidate(message.endpoint, message.peer)
   end
end

local function handle_target ( peer, message, meta )
   if message.type=="hello" then
      local expected=meta.expected_node or job.expected_node
      if expected and message.node~=expected then
         remove_peer(peer,true)
         return
      end
      meta.verified=true
      meta.node=message.node
      job.expected_node=job.expected_node or message.node
      send_packet(peer,{
         type="query",node=job.node,system=job.target.system,
         visit=job.visit,
      },gameplay_codec)
      return
   end
   if not meta.verified or message.node~=meta.node then return end
   if message.type=="claim" and message.system==job.target.system then
      job.epoch=message.epoch
      if job.phase=="connecting" and not queue_transmission(peer) then
         start_next_target()
      end
   end
end

local function handle_receive ( peer, packet )
   local meta = job.peers[peer]
   if not meta then return end

   local wire_codec=meta.role=="directory"
      and directory_codec or gameplay_codec
   local message = wire_codec.decode(packet)
   if not message then return end

   if meta.role == "directory" then
      handle_directory(peer, message, meta)
   else
      handle_target(peer, message, meta)
   end
end

local function handle_connect ( peer )
   local meta = job.peers[peer]
   if not meta then
      meta = {
         role = "target",
         expected_node = job.expected_node,
         verified = false,
      }
      job.peers[peer] = meta
   end
   hello(peer)
end

local function handle_disconnect ( peer )
   local meta = job.peers[peer]
   local completed = job.phase == "draining"
      and peer == job.published_peer

   if meta and meta.role == "directory" then
      job.directory_peer = nil
   end
   job.peers[peer] = nil

   if completed then
      complete_target()
      return true
   end

   if meta and meta.role == "directory" and job.phase ~= "draining" then
      if job.on_error then
         job.on_error(job.lost_error)
      end
      finish_job()
      return true
   end
   return false
end

function transient.start ( params )
   params = params or {}

   if job then return nil,_("A transient transmission is already in progress.") end
   if type(params.directory) ~= "string" or params.directory == "" then
      return nil,_("No multiplayer directory is configured.")
   end
   if type(params.node_id) ~= "string"
         or not params.node_id:match("^[%x]+$") then
      return nil,_("No multiplayer identity is configured.")
   end
   if type(params.name)~="string" or params.name==""
         or type(params.ship)~="string" or params.ship==""
         or type(params.text)~="string" or params.text==""
         or type(params.target_systems)~="function"
         or type(params.position)~="function" then
      return nil,_("Invalid transient transmission configuration.")
   end

   local host = enet.host_create("*:0")
   if not host then return nil,params.host_error
      or _("Unable to initialize the transmission.") end

   local peer = host:connect(params.directory)
   if not peer then return nil,params.connect_error
      or _("Unable to contact the multiplayer directory.") end

   job = {
      host = host,
      peers = {},
      directory_peer = peer,
      node = params.node_id..(params.node_suffix or "t"),
      endpoint = tostring(host:get_socket_address()),
      kind = params.kind,
      origin_suffix = params.origin_suffix or ".player",
      ship = params.ship,
      name = params.name,
      text = params.text:sub(1,1024),
      target_systems = params.target_systems,
      inspect_object = params.inspect_object,
      position = params.position,
      on_target = params.on_target,
      on_empty = params.on_empty,
      on_error = params.on_error,
      unsupported = params.unsupported
         or _("The multiplayer directory lacks a required service."),
      lost_error = params.lost_error
         or _("Lost connection to the multiplayer directory."),
      timeout_error = params.timeout_error
         or _("The multiplayer directory did not answer."),
      targets = {},
      index = 0,
      candidates = {},
      scan_systems = {},
      scan_index = 0,
      scan_request = 0,
      phase = "directory",
      deadline = now()+DIRECTORY_TIMEOUT,
   }
   job.peers[peer] = {
      role = "directory",
      verified = false,
   }
   return true
end

function transient.update ()
   if not job or not job.host then return end

   local processed = 0
   local current_host = job.host
   local event = current_host:service(0)

   while event and job and job.host == current_host do
      processed = processed+1

      if event.type == "connect" then
         handle_connect(event.peer)
      elseif event.type == "receive" then
         handle_receive(event.peer, event.data)
      elseif event.type == "disconnect" then
         if handle_disconnect(event.peer) then return end
      end

      if processed >= MAX_EVENTS_PER_UPDATE then break end
      -- A receive handler can complete the job and destroy its ENet host.
      -- Never service the captured userdata again after that teardown.
      if not job or job.host ~= current_host then return end
      event = current_host:service(0)
   end

   if not job or job.host ~= current_host then return end

   if now() >= job.deadline then
      if job.phase=="scanning" then
         start_next_scan()
      elseif job.phase == "connecting" or job.phase == "draining" then
         start_next_target()
      else
         if job.on_error then
            job.on_error(job.timeout_error)
         end
         finish_job()
      end
   end
end

return transient
