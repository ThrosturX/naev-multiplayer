local topology = require "multiplayer.p2p.topology"
local reconcile = require "multiplayer.p2p.reconcile"

local core = {}
core.__index = core

function core.new ( node_id, now )
   local self=setmetatable({}, core)
   self.node_id=node_id
   self.now=now or os.clock
   self.topology=topology.new(node_id, self.now)
   self.state="stopped"
   self.sequences={}
   self.members={}
   return self
end

function core:start ()
   if self.state ~= "stopped" then return nil, "already started" end
   self.state="idle"
   return true
end

function core:stop ()
   self.state="stopped"; self.system=nil; self.host=nil; self.claim=nil
end

function core:enter ( system_name )
   if self.state == "stopped" then return nil, "not started" end
   self.system=system_name
   self.state="discovering"
   self.deadline=self.now()+1.5
   self.host=nil; self.claim=nil
   self.members={[self.node_id]=true}
   return true
end

function core:leave ()
   self.system=nil; self.host=nil; self.claim=nil; self.members={}
   if self.state ~= "stopped" then self.state="idle" end
end

function core:tick ()
   if self.state == "discovering" and self.now() >= self.deadline then
      self.state="host"; self.host=self.node_id
      self.claim=self.node_id .. ":" .. tostring(math.floor(self.now()*1000))
      return "claim"
   end
end

function core:accept_claim ( message )
   if message.system ~= self.system then return false end
   if message.node == self.node_id then return false end
   if self.state == "discovering" or self.state == "host" then
      local winner=topology.resolve_claim(self.node_id, message.node)
      if winner == message.node then
         self.state="guest"; self.host=message.node; self.claim=message.claim
      elseif self.state == "discovering" then
         self.state="host"; self.host=self.node_id
         self.claim=self.claim or (self.node_id .. ":" .. tostring(math.floor(self.now()*1000)))
      end
   end
   self.members[message.node]=true
   return self.host == message.node
end

function core:host_lost ()
   if not self.host then return nil end
   self.members[self.host]=nil
   local nodes={}
   for node in pairs(self.members) do nodes[#nodes+1]=node end
   local winner=topology.elect(nodes)
   self.host=winner
   self.state=(winner == self.node_id) and "host" or "discovering"
   if winner == self.node_id then
      self.claim=self.node_id .. ":" .. tostring(math.floor(self.now()*1000))
   else
      self.claim=nil
      self.deadline=self.now()+1.5
   end
   return winner
end

function core:accept_sequence ( stream, seq )
   return reconcile.accept(self.sequences, stream, seq)
end

return core
