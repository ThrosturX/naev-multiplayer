package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

local cache={}
local safe_hooks={}
local clock=0
naev={
   cache=function() return cache end,
   ticks=function() return clock end,
}
hook={safe=function(name,...)
   safe_hooks[#safe_hooks+1]={name=name,args={...}}
end}

local updates=0
local session={update_object_client=function()
   updates=updates+1
   return true
end}
local objects=require "multiplayer.p2p.space_objects"

objects.start(session)
assert(#safe_hooks==1 and safe_hooks[1].name=="P2P_OBJECT_UPDATE",
   "space-object service did not schedule its pause-safe pump")
local first=safe_hooks[1]
cache.multiplayer_buoy_consume={slot=7,object_id="object-1"}
objects.update(first.args[1])
assert(updates==1 and cache.multiplayer_buoy_consume==nil,
   "pause-safe pump did not service the object client")
assert(safe_hooks[2].name=="P2P_BUOY_CONSUME"
      and safe_hooks[2].args[1]==7
      and safe_hooks[3].name=="P2P_OBJECT_UPDATE",
   "acknowledgement consumption was not safely dispatched before rescheduling")

objects.pump()
assert(updates==1,"live update ignored the one-second service interval")
objects.update(safe_hooks[3].args[1])
assert(updates==1,
   "safe fallback ignored the shared one-second service interval")

clock=0.99
objects.pump()
assert(updates==1,"object client was serviced faster than one hertz")
clock=1
objects.pump()
assert(updates==2,"one-hertz object service deadline was not honoured")

objects.stop()
objects.update(safe_hooks[4].args[1])
assert(updates==2,"stale safe hook survived object-service shutdown")

print("ok - pause-safe persistent space-object lifecycle")
