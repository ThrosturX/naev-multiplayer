-- Sender-only transient distress relay.
local codec = require "multiplayer.p2p.codec"
local enet = require "enet"
local fmt = require "format"

local distress = {}

local BEACON_SHIP = "Distress Beacon"
local BEACON_NAME = "Automated Distress Relay"
local DIRECTORY_TIMEOUT = 8
local TARGET_TIMEOUT = 8
local DRAIN_TIMEOUT = 3
local MAX_EVENTS_PER_UPDATE = 24

local job

local function now ()
   return naev.ticks()
end

local function send_packet ( peer, message )
   local packet = codec.encode(message)
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
   job = nil
end

function distress.stop ()
   finish_job()
end

function distress.active ()
   return job ~= nil
end

local function gate_position ( origin_name, target_name )
   local origin = system.get(origin_name)
   local target = system.get(target_name)
   local path = origin:jumpPath(target)
   local final_jump = path and path[#path]
   if not final_jump then return 0, 0 end
   return final_jump:reverse():pos():get()
end

local function base_message ( kind )
   return {
      type = kind,
      node = job.node,
      system = job.target.system,
   }
end

local start_next_target

local function complete_target ()
   local jumps = job.target.distance
   local unit = jumps == 1 and _("jump") or _("jumps")
   player.msg(fmt.f(
      _("Distress beacon successfully deployed {jumps} {unit} away."),
      {jumps=jumps, unit=unit}
   ))
   start_next_target()
end

local function queue_beacon ( peer )
   local x, y = gate_position(job.origin, job.target.system)

   local manifest = base_message("player_manifest")
   manifest.entity = job.node
   manifest.ship = BEACON_SHIP
   manifest.name = BEACON_NAME
   manifest.x = x
   manifest.y = y
   manifest.vx = 0
   manifest.vy = 0
   manifest.dir = 0
   manifest.armour = 100
   manifest.shield = 0
   manifest.stress = 0

   job.sequence = job.sequence+1
   local chat = base_message("chat")
   chat.seq = job.sequence
   chat.text = fmt.f(
      _("Automated distress signal: {ship} in {system} requests assistance."),
      {
         ship = job.ship_name,
         system = _(job.origin),
      }
   )

   local leave = base_message("leave")

   if not send_packet(peer, manifest)
         or not send_packet(peer, chat)
         or not send_packet(peer, leave) then
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
   return send_packet(peer, {
      type = "hello",
      node = job.node,
      cap = "player",
      name = BEACON_NAME,
      endpoint = job.endpoint,
   })
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
         local system_name = codec.unescape(encoded)
         if system_name and system_name ~= "" then
            active_systems[#active_systems+1] = system_name
         end
      end
   end
   return active_systems
end

local function active_targets ( origin_name, range, active_systems )
   local targets = {}
   local seen = {}
   local origin = system.get(origin_name)

   for _index, system_name in ipairs(active_systems) do
      if system_name ~= origin_name and not seen[system_name] then
         seen[system_name] = true
         local target = system.exists(system_name)
         if target then
            local distance = origin:jumpDist(target)
            if distance and distance <= range then
               targets[#targets+1] = {
                  system = system_name,
                  distance = distance,
               }
            end
         end
      end
   end

   table.sort(targets, function ( a, b )
      if a.distance ~= b.distance then
         return a.distance < b.distance
      end
      return a.system < b.system
   end)
   return targets
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
      player.msg("#r".._("Lost connection to the multiplayer directory.").."#0")
      finish_job()
      return
   end

   job.phase = "connecting"
   job.sequence = 0
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
      if not features:find(",activity,", 1, true) then
         player.msg("#r".._("The multiplayer directory does not provide activity data.").."#0")
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
      job.targets = active_targets(job.origin, job.range, systems)
      if #job.targets == 0 then
         player.msg("#r".._("The distress beacon completed a round trip in subspace without acknowledgement of receipt. There were no receivers detected in range.").."#0")
         finish_job()
         return
      end
      job.index = 0
      start_next_target()
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
   if message.type ~= "hello" or message.cap ~= "player" then return end

   local expected = meta.expected_node or job.expected_node
   if expected and message.node ~= expected then
      remove_peer(peer, true)
      return
   end

   meta.verified = true
   meta.node = message.node
   job.expected_node = job.expected_node or message.node

   if job.phase == "connecting" and not queue_beacon(peer) then
      start_next_target()
   end
end

local function handle_receive ( peer, packet )
   local meta = job.peers[peer]
   if not meta then return end

   local message = codec.decode(packet)
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
      player.msg("#r".._("Lost connection to the multiplayer directory.").."#0")
      finish_job()
      return true
   end
   return false
end

function distress.send ( params )
   params = params or {}

   if job then
      return nil, _("A distress transmission is already in progress.")
   end
   if player.isLanded() then
      return nil, _("The distress beacon can only be used in space.")
   end
   if params.enabled ~= true then
      return nil, _("The distress beacon can only be activated when P2P multiplayer is enabled.")
   end
   if type(params.directory) ~= "string" or params.directory == "" then
      return nil, _("No subspace relay configuration found.")
   end
   if type(params.node_id) ~= "string"
         or not params.node_id:match("^[%x]+$") then
      return nil, _("No multiplayer identity is configured.")
   end
   if type(params.ship_name) ~= "string" or params.ship_name == "" then
      return nil, _("Unable to identify the ship in distress.")
   end

   local host = enet.host_create("*:0")
   if not host then
      return nil, _("The distress beacon doesn't have a functional transponder..")
   end

   local peer = host:connect(params.directory)
   if not peer then
      return nil, _("The distress beacon doesn't appear to be functional.")
   end

   job = {
      host = host,
      peers = {},
      directory_peer = peer,
      node = params.node_id.."b",
      endpoint = tostring(host:get_socket_address()),
      origin = system.cur():nameRaw(),
      ship_name = params.ship_name,
      range = math.max(1, math.floor(tonumber(params.range) or 3)),
      targets = {},
      index = 0,
      candidates = {},
      phase = "directory",
      deadline = now()+DIRECTORY_TIMEOUT,
   }
   job.peers[peer] = {
      role = "directory",
      verified = false,
   }
   return true
end

function distress.update ( _dt )
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
      event = current_host:service(0)
   end

   if not job or job.host ~= current_host then return end

   if now() >= job.deadline then
      if job.phase == "connecting" or job.phase == "draining" then
         start_next_target()
      else
         player.msg("#r".._("The multiplayer directory did not answer the distress beacon.").."#0")
         finish_job()
      end
   end
end

return distress
