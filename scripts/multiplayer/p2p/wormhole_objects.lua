-- Shared wormhole-object policy. This module deliberately has no Naev or ENet
-- dependencies so the directory and client can use the same rules.
local Expiry = require "multiplayer.p2p.object_expiry"

local wormholes = {}

function wormholes.is_wormhole ( object )
   return type(object)=="table"
      and (object.kind=="one_way_wormhole"
         or object.kind=="two_way_wormhole")
end

function wormholes.expires_at ( object )
   if not wormholes.is_wormhole(object) then return nil end
   return Expiry.expires_at(object)
end

function wormholes.expired ( object, stamp )
   return wormholes.is_wormhole(object) and Expiry.expired(object,stamp)
end

function wormholes.any ( values )
   for _id,object in pairs(values or {}) do
      if wormholes.is_wormhole(object) then return true end
   end
   return false
end

function wormholes.visible_in ( object, system_name )
   if not wormholes.is_wormhole(object) then return false end
   for _index,endpoint in ipairs(object.endpoints or {}) do
      if endpoint.visible and endpoint.system==system_name then return true end
   end
   return false
end

function wormholes.endpoint_in ( object, system_name )
   if not wormholes.is_wormhole(object) then return nil end
   for _index,endpoint in ipairs(object.endpoints or {}) do
      if endpoint.visible and endpoint.system==system_name then return endpoint end
   end
end

function wormholes.target_of ( object, endpoint )
   if not wormholes.is_wormhole(object) or not endpoint or not endpoint.target then
      return nil
   end
   for _index,candidate in ipairs(object.endpoints or {}) do
      if candidate.id==endpoint.target then return candidate end
   end
end

return wormholes
