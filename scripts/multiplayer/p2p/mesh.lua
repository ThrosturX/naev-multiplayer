-- Bounded flood-once routing for low-rate P2P correctness traffic.
local mesh = {}
mesh.__index = mesh

local MAX_HOPS = 8
local MAX_SEEN = 2048
local SEEN_TTL = 30

local routed_types = {
   member_heartbeat=true,host_query=true,claim=true,leave=true,
   player_manifest=true,player_control=true,npc_interest=true,chat=true,
   npc_manifest=true,npc_done=true,npc_control=true,npc_add=true,npc_remove=true,
   npc_state=true,npc_focus_state=true,
   craft_manifest=true,craft_remove=true,craft_order=true,resync=true,
}

function mesh.new ( node_id, now )
   return setmetatable({
      node_id=node_id,
      now=now or os.clock,
      route_sequence=0,
      seen={},
      seen_order={},
   },mesh)
end

function mesh.routed_type ( kind )
   return routed_types[kind]==true
end

local function route_id ( message )
   if not message.node or not message.visit or not message.route_seq then return nil end
   return table.concat({
      message.node,message.visit,message.type,tostring(message.route_seq)
   },":")
end

function mesh:prune ( stamp )
   stamp=stamp or self.now()
   local order=self.seen_order
   local at=1
   while at<=#order do
      local item=order[at]
      if #order-at+1<=MAX_SEEN and stamp-item.seen<=SEEN_TTL then break end
      if self.seen[item.id]==item.seen then self.seen[item.id]=nil end
      at=at+1
   end
   if at>1 then
      local kept={}
      for index=at,#order do kept[#kept+1]=order[index] end
      self.seen_order=kept
   end
end

function mesh:mark ( message, stamp )
   local id=route_id(message)
   if not id then return nil,"missing route identity" end
   stamp=stamp or self.now()
   self:prune(stamp)
   if self.seen[id] then return false end
   self.seen[id]=stamp
   self.seen_order[#self.seen_order+1]={id=id,seen=stamp}
   self:prune(stamp)
   return true
end

function mesh:origin ( message, visit )
   self.route_sequence=self.route_sequence+1
   message.via=self.node_id
   message.visit=visit
   message.route_seq=self.route_sequence
   message.hops=0
   assert(self:mark(message))
   return message
end

function mesh:accept ( message, immediate_node )
   if not mesh.routed_type(message.type) then return nil,"message is not routable" end
   if message.via~=immediate_node then return nil,"relay identity mismatch" end
   if message.hops>MAX_HOPS then return nil,"route hop limit exceeded" end
   return self:mark(message)
end

function mesh:forward ( message )
   if message.hops>=MAX_HOPS then return nil end
   local forwarded={}
   for key,value in pairs(message) do forwarded[key]=value end
   forwarded.via=self.node_id
   forwarded.hops=message.hops+1
   return forwarded
end

function mesh:reset ()
   self.route_sequence=0
   self.seen={}
   self.seen_order={}
end

mesh.MAX_HOPS=MAX_HOPS
mesh.MAX_SEEN=MAX_SEEN
mesh.SEEN_TTL=SEEN_TTL

return mesh
