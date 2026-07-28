-- Event-facing service adapter for optional persistent space objects.
--
-- The object transport is independent from gameplay peers. Normal and modal
-- multiplayer updates service it at a bounded real-time cadence. A safe hook
-- remains armed only while an acknowledgement, initial subscription, delete,
-- or reconnect is pending, so paused requests remain live without permanent
-- per-frame hook churn.
local space_objects = {}

local SERVICE_INTERVAL = 1
local generation = 0
local scheduled = false
local last_service = -math.huge
local runtime

local function dispatch_consumption ()
   local cache=naev.cache()
   local consume=cache.multiplayer_buoy_consume
   if not consume then return end
   cache.multiplayer_buoy_consume=nil
   hook.safe("P2P_BUOY_CONSUME",consume.slot,consume.object_id)
end

local function service_pending ()
   return runtime and runtime.object_service_pending
      and runtime.object_service_pending()
end

local function schedule_if_pending ()
   if scheduled or not service_pending() then return end
   scheduled=true
   hook.safe("P2P_OBJECT_UPDATE",generation)
end

function space_objects.start ( session )
   generation=generation+1
   scheduled=false
   last_service=-math.huge
   runtime=session
   schedule_if_pending()
end

function space_objects.stop ()
   generation=generation+1
   scheduled=false
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
   if expected_generation~=generation then return end
   scheduled=false
   service_if_due()
   schedule_if_pending()
end

function space_objects.pump ()
   service_if_due()
   schedule_if_pending()
end

return space_objects
