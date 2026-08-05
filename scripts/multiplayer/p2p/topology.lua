-- Peer cache, host hints, discovery, and deterministic election.
local topology = {}
topology.__index = topology
topology.AUTO_PEER_RETENTION = 60

local function copy_endpoint ( peer )
   return {endpoint=peer.endpoint,seen=peer.seen or 0,node=peer.node}
end

local function endpoint_valid ( endpoint )
   if type(endpoint)~="string"
         or not endpoint:match("^[^%s:]+:%d+$") then return false end
   local host=endpoint:match("^([^:]+):")
   return host~="0.0.0.0" and host~="*"
end

function topology.new ( node_id, now )
   return setmetatable({ node_id=node_id, now=now or os.time, peers={}, hints={} }, topology)
end

function topology:add_peer ( endpoint, seen, node )
   if not endpoint_valid(endpoint) then return nil end
   local stamp=seen or self.now()
   for index=#self.peers,1,-1 do
      local peer=self.peers[index]
      if peer.endpoint==endpoint or (node and peer.node==node) then
         table.remove(self.peers,index)
      end
   end
   table.insert(self.peers,{endpoint=endpoint,seen=stamp,node=node})
   table.sort(self.peers, function(a,b) return a.seen>b.seen end)
   while #self.peers > 32 do table.remove(self.peers) end
   return true
end

function topology:serialize_peers ()
   local stamp=self.now()
   for index=#self.peers,1,-1 do
      local seen=tonumber(self.peers[index].seen) or 0
      if stamp-seen>topology.AUTO_PEER_RETENTION then
         table.remove(self.peers,index)
      end
   end
   local result={}
   for i, peer in ipairs(self.peers) do result[i]=copy_endpoint(peer) end
   return result
end

function topology:load_peers ( peers )
   self.peers={}
   for _index,peer in ipairs(peers or {}) do
      self:add_peer(peer.endpoint,tonumber(peer.seen) or 0,peer.node)
   end
   self:serialize_peers()
end

function topology:remember_hint ( system_name, host, endpoint, claim, expires )
   if tonumber(expires) <= self.now() then return nil end
   -- Hints are discovery aids, not election votes. Prefer the latest reachable
   -- information instead of allowing a lower-ID former host to pin the cache.
   self.hints[system_name]={host=host, endpoint=endpoint, claim=claim, expires=tonumber(expires)}
   self:add_peer(endpoint,nil,host)
   return true
end

function topology:hint ( system_name )
   local hint=self.hints[system_name]
   if hint and hint.expires > self.now() then return hint end
   self.hints[system_name]=nil
end

function topology.elect ( members )
   local winner
   for _index, node in ipairs(members or {}) do
      if not winner or node < winner then winner=node end
   end
   return winner
end

function topology.resolve_claim ( local_node, remote_node )
   return (remote_node < local_node) and remote_node or local_node
end

return topology
