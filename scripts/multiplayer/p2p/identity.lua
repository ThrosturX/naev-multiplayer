-- Participant identity registry. Wire names may collide, but Naev pilot names
-- may not. The local player always keeps their own name; colliding remote
-- players receive a local-only display suffix.
local identity = {}
identity.__index = identity

local function valid_name ( name )
   -- Naev accepts up to 60 UTF-8 characters. Four bytes per character is the
   -- largest valid UTF-8 representation, so this byte bound is conservative.
   return type(name)=="string" and name~="" and #name<=240
      and not name:find("[%z\1-\31\127]")
end

function identity.new ( local_node, local_name )
   assert(type(local_node)=="string" and local_node~="")
   assert(valid_name(local_name))
   return setmetatable({
      local_node=local_node,
      by_node={[local_node]={raw=local_name,display=local_name}},
      by_display={[local_name]=local_node},
   },identity)
end

function identity:add ( node, name )
   if type(node)~="string" or node=="" or not valid_name(name) then
      return nil,"invalid player identity"
   end
   local old=self.by_node[node]
   if old then
      if old.raw==name then return old.display end
      return nil,"node changed player name"
   end
   local display=name
   local suffix=2
   while self.by_display[display] do
      display=name.." #"..suffix
      suffix=suffix+1
   end
   self.by_node[node]={raw=name,display=display}
   self.by_display[display]=node
   return display
end

-- A relayed manifest can arrive before the node's direct hello. Allow that
-- direct connection to refresh the raw name while preserving local uniqueness.
function identity:update ( node, name )
   if node==self.local_node or not valid_name(name) then
      return nil,"invalid player identity update"
   end
   local old=self.by_node[node]
   if not old then return self:add(node,name) end
   if old.raw==name then return old.display end
   self.by_display[old.display]=nil
   local display=name
   local suffix=2
   while self.by_display[display] do
      display=name.." #"..suffix
      suffix=suffix+1
   end
   old.raw=name; old.display=display
   self.by_display[display]=node
   return display
end

function identity:remove ( node )
   if node==self.local_node then return end
   local entry=self.by_node[node]
   if entry then self.by_display[entry.display]=nil; self.by_node[node]=nil end
end

function identity:raw_name ( node )
   local entry=self.by_node[node]
   return entry and entry.raw or nil
end

function identity:display_name ( node )
   local entry=self.by_node[node]
   return entry and entry.display or nil
end

return identity
