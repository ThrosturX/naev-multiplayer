-- Event-facing lifecycle adapter for optional persistent space objects.
--
-- Safe hooks keep the dedicated object client alive while Naev suspends
-- gameplay update hooks for a paused solo host.
local space_objects = {}

local generation = 0
local scheduled = false
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
   runtime=session
   schedule()
end

function space_objects.stop ()
   generation=generation+1
   scheduled=false
   runtime=nil
end

function space_objects.update ( expected_generation )
   if expected_generation and expected_generation~=generation then return end
   scheduled=false
   if not runtime or not runtime.update_object_client() then return end
   dispatch_consumption()
   schedule()
end

function space_objects.pump ()
   if not runtime then return end
   runtime.update_object_client()
   dispatch_consumption()
end

return space_objects
