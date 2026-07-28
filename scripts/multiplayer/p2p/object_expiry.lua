-- Central expiry policy for persistent objects. The directory pruner consumes
-- this module without knowing which object kinds are temporary. A kind omitted
-- from LIFETIMES is permanent.
local expiry = {}

local LIFETIMES = {
   one_way_wormhole=2*60,
   two_way_wormhole=5*60,
}

function expiry.lifetime ( kind )
   return LIFETIMES[kind]
end

function expiry.expires_at ( object )
   if type(object)~="table" or type(object.created)~="number" then return nil end
   local lifetime=LIFETIMES[object.kind]
   if not lifetime then return nil end
   return object.created+lifetime
end

function expiry.expired ( object, stamp )
   local expires=expiry.expires_at(object)
   return expires~=nil and type(stamp)=="number" and stamp>=expires
end

return expiry
