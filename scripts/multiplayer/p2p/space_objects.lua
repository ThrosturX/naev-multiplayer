-- Event-facing service adapter for optional persistent space objects.
--
-- The object transport is independent from gameplay peers. A one-second timer
-- maintains subscriptions; a safe hook remains armed only while an
-- acknowledgement, delete, or reconnect is pending so paused requests live.
require "multiplayer.p2p.wormhole_extension"

local space_objects = {}

local SERVICE_INTERVAL = 1
local generation = 0
local scheduled = false
local consumption_scheduled = false
local consumption_queue = {}
local last_service = -math.huge
local runtime
local timer_hook

local function schedule_consumption ()
   if consumption_scheduled or #consumption_queue==0 then return end
   consumption_scheduled=true
   hook.safe("P2P_OBJECT_CONSUME",generation)
end

local function dispatch_consumption ()
   if runtime and runtime.take_object_consumptions then
      local incoming=runtime.take_object_consumptions()
      if type(incoming)=="table" then
         for _index,consume in ipairs(incoming) do
            consumption_queue[#consumption_queue+1]=consume
         end
      end
   end
   schedule_consumption()
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

local function schedule_timer ()
   if timer_hook or not runtime then return end
   timer_hook=hook.timer(SERVICE_INTERVAL,"P2P_OBJECT_TIMER",generation)
end

function space_objects.start ( session )
   generation=generation+1
   scheduled=false
   consumption_scheduled=false
   last_service=-math.huge
   runtime=session
   dispatch_consumption()
   schedule_if_pending()
   schedule_timer()
end

function space_objects.stop ()
   dispatch_consumption()
   space_objects.consume(generation)
   generation=generation+1
   scheduled=false
   last_service=-math.huge
   if timer_hook then hook.rm(timer_hook) end
   timer_hook=nil
   runtime=nil
   schedule_consumption()
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
   if runtime and runtime.update_signal_relay then
      runtime.update_signal_relay()
   end
   service_if_due()
   schedule_if_pending()
end

function space_objects.wake ()
   schedule_if_pending()
end

function space_objects.consume ( expected_generation )
   if expected_generation~=nil and expected_generation~=generation then return end
   consumption_scheduled=false
   local queue=consumption_queue
   consumption_queue={}
   local p=player.pilot()
   if p then
      for _index,consume in ipairs(queue) do
         local slot=tonumber(consume.slot)
         local name=type(consume.outfit)=="string" and consume.outfit or nil
         local fitted=slot and p:outfitSlot(slot)
         if fitted and name and fitted:nameRaw()==name then
            p:outfitRmSlot(slot)
         end
      end
   end
   dispatch_consumption()
end

function space_objects.chat ( text )
   if not runtime or not runtime.relay_chat then return false end
   local sent=runtime.relay_chat(text)
   schedule_if_pending()
   return sent
end

function space_objects.object_destroyed ( object_id, destroyed_pilot )
   if not runtime or not runtime.object_destroyed then return false end
   local removed=runtime.object_destroyed(object_id,destroyed_pilot)
   schedule_if_pending()
   return removed
end

function space_objects.timer ( expected_generation )
   if expected_generation~=generation then return end
   timer_hook=nil
   service_if_due()
   schedule_if_pending()
   schedule_timer()
end

return space_objects
