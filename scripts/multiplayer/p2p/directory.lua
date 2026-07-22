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
   self.peers[peer]={endpoint=observed_endpoint,queries={}}
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

function directory:publish_hint ( system_name, claim )
   for peer,meta in pairs(self.peers) do
      if meta.node and meta.queries[system_name] then self:send_hint(peer,system_name,claim) end
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
      return true
   end
   if not meta.node or message.node~=meta.node then
      self:reject(peer); return nil,"unverified node"
   end

   if message.type=="claim" then
      local host=endpoint_host(meta.endpoint)
      local port=endpoint_port(message.endpoint)
      if not host or not port then return nil,"unusable endpoint" end
      local stamp=self.now()
      local old=self.hosts[message.system]
      if not old or not old.active or old.node==message.node or message.node<old.node then
         if not old then self:make_host_room() end
         local claim={node=message.node,claim=message.claim,
            endpoint=host..":"..tostring(port),seen=stamp,active=true,peer=peer}
         self.hosts[message.system]=claim
         self:publish_hint(message.system,claim)
      end
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
      return self:send_hint(peer,message.system,claim)
   end

   -- Directory peers never join systems or relay gameplay messages.
   return true
end

return directory
