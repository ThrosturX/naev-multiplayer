local topology = require "multiplayer.p2p.topology"
local reconcile = require "multiplayer.p2p.reconcile"

local core = {}
core.__index = core

local DISCOVERY_TIME = 2
local HOST_LEASE = 5
local RECOVERY_TIME = 2
local MEMBER_LEASE = 7

function core.new ( node_id, now )
   local self=setmetatable({},core)
   self.node_id=node_id
   self.now=now or os.clock
   self.topology=topology.new(node_id,self.now)
   self.state="stopped"
   self.sequences={}
   self.members={}
   self.member_seen={}
   self.member_visits={}
   self.claim_support={}
   return self
end

function core:start ()
   if self.state~="stopped" then return nil,"already started" end
   self.state="idle"
   return true
end

function core:stop ()
   self.state="stopped"
   self.system=nil; self.visit=nil; self.host=nil; self.claim=nil
   self.members={}; self.member_seen={}; self.member_visits={}
   self.claim_support={}
end

function core:enter ( system_name, visit )
   if self.state=="stopped" then return nil,"not started" end
   self.system=system_name
   self.visit=visit or self.node_id
   self.state="discovering"
   self.deadline=self.now()+DISCOVERY_TIME
   self.host=nil; self.claim=nil; self.host_seen=nil
   self.members={[self.node_id]=true}
   self.member_seen={[self.node_id]=self.now()}
   self.member_visits={[self.node_id]=self.visit}
   self.claim_support={}
   self.sequences={}
   return true
end

function core:leave ()
   self.system=nil; self.visit=nil; self.host=nil; self.claim=nil
   self.host_seen=nil; self.deadline=nil
   self.members={}; self.member_seen={}; self.member_visits={}
   self.claim_support={}
   self.sequences={}
   if self.state~="stopped" then self.state="idle" end
end

function core:new_claim ()
   self.state="host"
   self.host=self.node_id
   self.claim=table.concat({
      self.node_id,self.visit or self.node_id,
      tostring(math.floor(self.now()*1000)),
   },":")
   self.host_seen=self.now()
   self.recovery_candidate=nil
   self.claim_support[self.claim]=self.claim_support[self.claim] or {}
   self.claim_support[self.claim][self.node_id]=true
   return self.claim
end

function core:observe_member ( node, visit, accepted_host, accepted_claim, stamp )
   if not node then return false end
   stamp=stamp or self.now()
   self.members[node]=true
   self.member_seen[node]=stamp
   if visit then self.member_visits[node]=visit end
   if accepted_host and accepted_claim then
      local support=self.claim_support[accepted_claim] or {}
      support[node]=true
      self.claim_support[accepted_claim]=support
   end
   if node==self.host and (not accepted_claim or accepted_claim==self.claim) then
      self.host_seen=stamp
   end
   if self.state=="recovering" and node==self.host
         and accepted_host==self.host and accepted_claim==self.claim then
      self.state="guest"
      self.deadline=nil
   end
   return true
end

function core:remove_member ( node )
   self.members[node]=nil
   self.member_seen[node]=nil
   self.member_visits[node]=nil
   for _claim,support in pairs(self.claim_support) do support[node]=nil end
end

function core:reset_member_sequences ( node )
   self.sequences["chat:"..node]=nil
   self.sequences["resync:"..node]=nil
   self.sequences["craft:"..node]=nil
   self.sequences["craft_order:"..node]=nil
end

function core:claim_acknowledged ( claim )
   local support=self.claim_support[claim]
   if not support then return false end
   for node in pairs(support) do
      if node~=claim:match("^([^:]+)") then return true end
   end
   return false
end

local function choose_claim ( self, message )
   local current_ack=self.claim and self:claim_acknowledged(self.claim)
   local remote_ack=self:claim_acknowledged(message.claim)
   if current_ack~=remote_ack then return remote_ack and message.node or self.host end
   return topology.resolve_claim(self.host or self.node_id,message.node)
end

function core:accept_claim ( message )
   if message.system~=self.system or message.node==self.node_id then return false end
   local old_host,old_claim=self.host,self.claim
   if self.state=="recovering" then
      local allowed=self.recovery_candidate
         and message.node==self.recovery_candidate
         or (not self.recovery_candidate and message.node==self.host
            and message.claim==self.claim)
         or (not self.recovery_candidate and not self.host)
      if not allowed then return false end
   end
   self:observe_member(message.node,message.visit,message.node,message.claim)

   if self.state=="discovering" or self.state=="recovering" or not self.host then
      self.state="guest"
      self.host=message.node
      self.claim=message.claim
      self.host_seen=self.now()
      self.deadline=nil
      self.recovery_candidate=nil
      if old_host~=self.host or old_claim~=self.claim then
         self.sequences.npc_manifest=nil
         self.sequences.npc_done=nil
         self.sequences.npc_control=nil
         self.sequences.npc=nil
      end
      return true
   end

   if self.host==message.node then
      if self.claim~=message.claim then
         self.claim=message.claim
         self.claim_support[message.claim]=self.claim_support[message.claim] or {}
         self.sequences.npc_manifest=nil
         self.sequences.npc_done=nil
         self.sequences.npc_control=nil
         self.sequences.npc=nil
      end
      self.host_seen=self.now()
      if self.state~="host" then self.state="guest" end
      return true
   end

   -- A live acknowledged incumbent cannot be displaced by a late claimant.
   if self.host_seen and self.now()-self.host_seen<=HOST_LEASE
         and self:claim_acknowledged(self.claim) then
      return false
   end

   local winner=choose_claim(self,message)
   if winner==message.node then
      self.state="guest"
      self.host=message.node
      self.claim=message.claim
      self.host_seen=self.now()
      self.deadline=nil
      self.recovery_candidate=nil
      self.sequences.npc_manifest=nil
      self.sequences.npc_done=nil
      self.sequences.npc_control=nil
      self.sequences.npc=nil
      return true
   end
   return false
end

local function live_nodes ( self, stamp )
   local nodes={}
   for node in pairs(self.members) do
      if node==self.node_id
            or stamp-(self.member_seen[node] or -math.huge)<=MEMBER_LEASE then
         nodes[#nodes+1]=node
      end
   end
   return nodes
end

function core:tick ()
   local stamp=self.now()
   self.member_seen[self.node_id]=stamp
   if self.state=="discovering" and stamp>=self.deadline then
      self:new_claim()
      return "claim"
   end
   if self.state=="guest" and self.host_seen
         and stamp-self.host_seen>HOST_LEASE then
      self:remove_member(self.host)
      self.state="recovering"
      self.deadline=stamp+RECOVERY_TIME
      return "recover"
   end
   if self.state=="recovering" and stamp>=self.deadline then
      local winner=topology.elect(live_nodes(self,stamp))
      if winner==self.node_id or not winner then
         self:new_claim()
         return "claim"
      end
      -- All recovering members elect the same candidate. Wait for its claim
      -- instead of independently creating another authority.
      self.recovery_candidate=winner
      self.host=nil
      self.claim=nil
      self.host_seen=nil
      self.deadline=stamp+RECOVERY_TIME
      return "query"
   end
end

function core:host_stale ()
   if self.state~="host" then return nil end
   self.state="recovering"
   self.host=nil
   self.claim=nil
   self.host_seen=nil
   self.recovery_candidate=nil
   self.deadline=self.now()+RECOVERY_TIME
   return true
end

function core:host_lost ()
   if not self.host then return nil end
   if self.state=="recovering" then return nil end
   self:remove_member(self.host)
   self.host_seen=nil
   self.state="recovering"
   self.recovery_candidate=nil
   self.deadline=self.now()+RECOVERY_TIME
   return nil
end

function core:accept_sequence ( stream, seq )
   return reconcile.accept(self.sequences,stream,seq)
end

core.DISCOVERY_TIME=DISCOVERY_TIME
core.HOST_LEASE=HOST_LEASE
core.RECOVERY_TIME=RECOVERY_TIME
core.MEMBER_LEASE=MEMBER_LEASE

return core
