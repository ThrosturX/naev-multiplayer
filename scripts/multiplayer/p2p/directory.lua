-- Minimal in-memory MP2P/1 directory. Networking is injected so this module
-- can be tested without lua-enet or a Naev process.
local codec = require "multiplayer.p2p.codec"

local directory = {}
directory.__index = directory
local MAX_HOSTS = 4096
local MAX_QUERIES_PER_PEER = 128
local MAX_ACTIVITY_SYSTEMS = 20
local ACTIVITY_RETENTION = 15*60
local ACTIVITY_PAYLOAD = 3000
local MAX_CONTESTANTS = 4096
local CONTESTANT_RETENTION = 90*24*60*60

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
      random=options.random or math.random,
      contestants=options.contestants or {},
      contestant_dirty=options.contestant_dirty or function() end,
      peers={}, hosts={}, activity={},
   },directory)
end

function directory:send ( peer, message )
   local packet=codec.encode(message)
   if not packet then return nil end
   return self.send_packet(peer,packet)
end

function directory:connect ( peer, observed_endpoint )
   self.peers[peer]={endpoint=canonical_endpoint(observed_endpoint),queries={},
      contestant_queries=0,contestant_registered=false}
   return self:send(peer,{type="hello",node=self.node_id,cap="directory",
      features="activity,contestants"})
end

function directory:disconnect_peer ( peer )
   local stamp=self.now()
   for system_name,claim in pairs(self.hosts) do
      if claim.peer==peer then
         claim.peer=nil
         claim.active=false
         self:record_activity(system_name,false,stamp)
      end
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
   local stamp=self.now()
   local removed=false
   for node,entry in pairs(self.contestants) do
      if type(entry.seen)~="number" or stamp-entry.seen>CONTESTANT_RETENTION then
         self.contestants[node]=nil
         removed=true
      end
   end
   local count=0
   for _node in pairs(self.contestants) do count=count+1 end
   if count>MAX_CONTESTANTS then
      local ordered={}
      for node,entry in pairs(self.contestants) do
         ordered[#ordered+1]={node=node,seen=entry.seen}
      end
      table.sort(ordered,function(a,b) return a.seen>b.seen end)
      for index=MAX_CONTESTANTS+1,#ordered do
         self.contestants[ordered[index].node]=nil
      end
      removed=true
   end
   if removed then self.contestant_dirty() end
end

function directory:make_contestant_room ()
   local count,oldest_node,oldest_seen=0
   for node,entry in pairs(self.contestants) do
      count=count+1
      if not oldest_seen or entry.seen<oldest_seen then
         oldest_node,oldest_seen=node,entry.seen
      end
   end
   if count>=MAX_CONTESTANTS and oldest_node then
      self.contestants[oldest_node]=nil
   end
end

function directory:register_contestant ( message )
   if not self.contestants[message.node] then self:make_contestant_room() end
   self.contestants[message.node]={
      node=message.node,
      seen=self.now(),
      division=message.division,
      name=message.name,
      ship=message.ship,
      ship_fallbacks=message.ship_fallbacks or "",
      outfits=message.outfits,
      slots=message.slots,
   }
   self.contestant_dirty()
end

function directory:send_contestants ( peer, message )
   local candidates={}
   for node,entry in pairs(self.contestants) do
      if node~=message.node and entry.division==message.division then
         candidates[#candidates+1]=entry
      end
   end
   for index=#candidates,2,-1 do
      local swap=self.random(1,index)
      candidates[index],candidates[swap]=candidates[swap],candidates[index]
   end

   local count=math.min(message.limit,#candidates)
   for index=1,count do
      local entry=candidates[index]
      self:send(peer,{
         type="contestant_entry",
         node=self.node_id,
         contestant=entry.node,
         division=entry.division,
         request=message.request,
         name=entry.name,
         ship=entry.ship,
         ship_fallbacks=entry.ship_fallbacks,
         outfits=entry.outfits,
         slots=entry.slots,
      })
   end
   return self:send(peer,{
      type="contestant_done",
      node=self.node_id,
      division=message.division,
      request=message.request,
      count=count,
   })
end

function directory:dump_contestants ()
   return self.contestants
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

function directory:record_activity ( system_name, active, stamp )
   if not self.activity[system_name] then
      local count,oldest_name,oldest_seen=0
      for name,entry in pairs(self.activity) do
         count=count+1
         if not oldest_seen or entry.seen<oldest_seen then
            oldest_name,oldest_seen=name,entry.seen
         end
      end
      if count>=MAX_HOSTS and oldest_name then self.activity[oldest_name]=nil end
   end
   self.activity[system_name]={active=active,seen=stamp}
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

function directory:send_activity ( peer )
   local stamp=self.now()
   local recent={}
   for system_name,entry in pairs(self.activity) do
      local age=math.max(0,stamp-entry.seen)
      if entry.active or age<=ACTIVITY_RETENTION then
         recent[#recent+1]={system=system_name,active=entry.active==true,
            seen=entry.seen,age=math.floor(age)}
      end
   end
   table.sort(recent,function(a,b)
      if a.active~=b.active then return a.active end
      if a.seen~=b.seen then return a.seen>b.seen end
      return a.system<b.system
   end)
   local lines,size={},0
   for _index,entry in ipairs(recent) do
      local line=table.concat({
         codec.escape(entry.system),entry.active and "1" or "0",entry.age,
      },",")
      if #lines>=MAX_ACTIVITY_SYSTEMS or size+#line+1>ACTIVITY_PAYLOAD then break end
      lines[#lines+1]=line
      size=size+#line+1
   end
   return self:send(peer,{type="activity",node=self.node_id,
      entries=#lines>0 and table.concat(lines,";") or "-"})
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
      self:record_activity(message.system,true,stamp)
      self:publish_hint(message.system,claim)
      return true
   end

   if message.type=="leave" then
      local old=self.hosts[message.system]
      if old and old.node==message.node and old.peer==peer then
         self.hosts[message.system]=nil
         self:record_activity(message.system,false,self.now())
      end
      return true
   end

   if message.type=="activity_query" then
      return self:send_activity(peer)
   end

   if message.type=="contestant_register" then
      if meta.contestant_registered then return nil,"contestant already registered" end
      meta.contestant_registered=true
      self:register_contestant(message)
      return true
   end

   if message.type=="contestant_query" then
      if meta.contestant_queries>=6 then return nil,"too many contestant queries" end
      meta.contestant_queries=meta.contestant_queries+1
      return self:send_contestants(peer,message)
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
