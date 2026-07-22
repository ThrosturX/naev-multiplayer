-- Owned-craft graph traversal and relay bookkeeping.
local owned = {}

function owned.classify ( roots, relationships )
   local result, queue = {}, {}
   for _index, id in ipairs(roots or {}) do queue[#queue+1]=id end
   local at=1
   while at <= #queue do
      local id=queue[at]; at=at+1
      if id and not result[id] then
         result[id]=true
         for _index, child in ipairs((relationships or {})[id] or {}) do queue[#queue+1]=child end
      end
   end
   return result
end

function owned.relay ( host, owner, message )
   if message.owner ~= owner then return nil, "owner mismatch" end
   for node, send in pairs(host.members or {}) do
      if node ~= owner then send(message, message.type ~= "craft_state") end
   end
   return true
end

function owned.cleanup ( replicas, owner, remove )
   for id, craft in pairs(replicas) do
      if craft.owner == owner then
         if remove then remove(craft) end
         replicas[id]=nil
      end
   end
end

return owned
