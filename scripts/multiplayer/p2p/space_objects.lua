-- Event-facing lifecycle adapter for optional persistent space objects.
--
-- Safe hooks keep the dedicated object client alive while Naev suspends
-- gameplay update hooks for a paused solo host.
local space_objects = {}

local SERVICE_INTERVAL = 1
local generation = 0
local scheduled = false
local checked_since_safe = false
local last_service = -math.huge
local runtime

local function dispatch_consumption ()
   local cache=naev.cache()
   local consume=cache.multiplayer_buoy_consume
   if not consume then return end
   cache.multiplayer_buoy_consume=nil
   hook.safe("P2P_BUOY_CONSUME",consume.slot,consume.object_id)
end

local function schedule ()
   if scheduled or not runtime then return end
   scheduled=true
   hook.safe("P2P_OBJECT_UPDATE",generation)
end

function space_objects.start ( session )
   generation=generation+1
   scheduled=false
   checked_since_safe=false
   last_service=-math.huge
   runtime=session
   schedule()
end

function space_objects.stop ()
   generation=generation+1
   scheduled=false
   checked_since_safe=false
   last_service=-math.huge
   runtime=nil
end

local function service_if_due ()
   if not runtime then return false end
   local stamp=naev.ticks()
   if stamp-last_service<SERVICE_INTERVAL then return true end
   last_service=stamp
   if not runtime.update_object_client() then return false end
   dispatch_consumption()
   return true
end

function space_objects.update ( expected_generation )
   if expected_generation and expected_generation~=generation then return end
   scheduled=false
   if checked_since_safe then
      checked_since_safe=false
      schedule()
   elseif service_if_due() then
      schedule()
   end
end

function space_objects.pump ()
   service_if_due()
   checked_since_safe=true
end

return space_objects
