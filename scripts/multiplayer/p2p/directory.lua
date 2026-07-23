-- Minimal in-memory MP2P/1 directory. Networking is injected so this module
-- can be tested without lua-enet or a Naev process.
local codec = require "multiplayer.p2p.codec"

local directory = {}
directory.__index = directory
local MAX_HOSTS = 4096
local MAX_QUERIES_PER_PEER = 128

local function endpoint_host ( endpoint )
   if type(endpoint)~="string" then return nil end
   return endpoint:match("^([^:%s]+):%d+$")
end

local function endpoint_port ( endpoint )
   if type(endpoint)~="string" then return nil end
   local port=tonumber(endpoint:match(":(%d+)$"))
   if not port or port<1 or port>65535 then return nil end
   return math.floor(port)
end

local function canonical_endpoint ( endpoint )
   local host=endpoint_host(endpoint)
   local port=endpoint_port(endpoint)
   if not host or not port then return nil end
   return host..":"..tostring(port)
end

function directory.new ( options )
   options=options or {}
   return setmetatable({
      node_id=assert(options.node_id,"directory node ID required"),
      now=options.now or os.time,
      send_packet=assert(options.send,"directory send callback required"),
      disconnect=options.disconnect or function() end,
      peers={}, hosts={},
   },directory)
end

function directory:send ( peer, message )
   local packet=codec.encode(message)
   if not packet then return nil end
   return self.send_packet(peer,packet)
end

function directory:connect ( peer, observed_endpoint )
   self.peers[peer]={endpoint=canonical_endpoint(observed_endpoint),queries={}}
   return self:send(peer,{type="hello",node=self.node_id,cap="directory"})
end

function directory:disconnect_peer ( peer )
   for _system_name,claim in pairs(self.hosts) do
      if claim.peer==peer then claim.peer=nil; claim.active=false end
   end
   self.peers[peer]=nil
end

function directory:reject ( peer )
   self:disconnect_peer(peer)
   self.disconnect(peer)
end

function directory:prune ()
   -- Claims are deliberately retained while bounded by MAX_HOSTS. A stale
   -- hint costs one failed direct connection before normal local claiming,
   -- while forgetting a reachable host can create a needless split brain.
end

function directory:make_host_room ()
   local count,oldest_name,oldest_seen=0
   for system_name,claim in pairs(self.hosts) do
      count=count+1
      if not oldest_seen or claim.seen<oldest_seen then
         oldest_name,oldest_seen=system_name,claim.seen
      end
   end
   if count>=MAX_HOSTS and oldest_name then self.hosts[oldest_name]=nil end
end

function directory:send_hint ( peer, system_name, claim )
   return self:send(peer,{type="hint",node=self.node_id,system=system_name,
      host=claim.node,endpoint=claim.endpoint,claim=claim.claim,
      ttl=60})
end

function directory:send_punch ( peer, system_name, node, endpoint )
   if not endpoint then return end
   return self:send(peer,{type="punch",node=self.node_id,system=system_name,
      peer=node,endpoint=endpoint})
end

function directory:send_candidates ( peer, system_name, node, candidate, same_public_ip )
   local sent={}
   local function send_candidate ( endpoint )
      if endpoint and not sent[endpoint] then
         sent[endpoint]=true
         self:send_punch(peer,system_name,node,endpoint)
      end
   end
   send_candidate(candidate.endpoint)
   send_candidate(candidate.alternate)
   if same_public_ip and candidate.advertised_port then
      send_candidate("127.0.0.1:"..tostring(candidate.advertised_port))
   end
end

function directory:introduce ( peer, system_name, claim )
   self:send_hint(peer,system_name,claim)
   local guest=self.peers[peer]
   local host=self.peers[claim.peer]
   if not guest or not guest.node or not claim.active or not host or peer==claim.peer then return end
   local same_public_ip=endpoint_host(guest.endpoint)==endpoint_host(claim.endpoint)
   self:send_candidates(peer,system_name,claim.node,claim,same_public_ip)
   self:send_candidates(claim.peer,system_name,guest.node,guest,same_public_ip)
end

function directory:publish_hint ( system_name, claim )
   for peer,meta in pairs(self.peers) do
      if meta.node and meta.queries[system_name] then self:introduce(peer,system_name,claim) end
   end
end

function directory:receive ( peer, packet )
   local meta=self.peers[peer]
   if not meta then return nil,"unknown peer" end
   local message,err=codec.decode(packet)
   if not message then self:reject(peer); return nil,err end

   if message.type=="hello" then
      if message.cap~="player" or meta.node then
         self:reject(peer); return nil,"invalid hello"
      end
      meta.node=message.node
      meta.advertised_port=endpoint_port(message.endpoint)
      local observed_host=endpoint_host(meta.endpoint)
      if observed_host and meta.advertised_port then
         meta.alternate=observed_host..":"..tostring(meta.advertised_port)
         if meta.alternate==meta.endpoint then meta.alternate=nil end
      end
      return true
   end
   if not meta.node or message.node~=meta.node then
      self:reject(peer); return nil,"unverified node"
   end

   if message.type=="claim" then
      local host=endpoint_host(meta.endpoint)
      local observed=canonical_endpoint(meta.endpoint)
      local advertised_port=endpoint_port(message.endpoint)
      if not host or not observed or not advertised_port then return nil,"unusable endpoint" end
      meta.advertised_port=advertised_port
      local alternate=host..":"..tostring(advertised_port)
      if alternate==observed then alternate=nil end
      local stamp=self.now()
      local old=self.hosts[message.system]
      -- The directory is only a rendezvous hint service. Record the latest
      -- verified claim instead of imposing the clients' split-brain ordering
      -- on otherwise healthy system hosts.
      if not old then self:make_host_room() end
      local claim={node=message.node,claim=message.claim,
         endpoint=observed,alternate=alternate,advertised_port=advertised_port,
         seen=stamp,active=true,peer=peer}
      self.hosts[message.system]=claim
      self:publish_hint(message.system,claim)
      return true
   end

   if message.type=="leave" then
      local old=self.hosts[message.system]
      if old and old.node==message.node and old.peer==peer then self.hosts[message.system]=nil end
      return true
   end

   if message.type=="query" then
      self:prune()
      if not meta.queries[message.system] then
         local count=0
         for _system_name in pairs(meta.queries) do count=count+1 end
         if count<MAX_QUERIES_PER_PEER then meta.queries[message.system]=true end
      end
      local claim=self.hosts[message.system]
      if not claim then return true end
      self:introduce(peer,message.system,claim)
      return true
   end

   -- Directory peers never join systems or relay gameplay messages.
   return true
end

return directory
