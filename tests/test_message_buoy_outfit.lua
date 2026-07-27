local fitted={
   [2]={nameRaw=function() return "Other Outfit" end},
   [5]={nameRaw=function() return "Message Buoy" end},
}
local messages={}
local cache={}
local landed=false
local enabled=true
local object_capable=true
local pilot={
   outfits=function() return fitted end,
   actives=function()
      return {{outfit=fitted[5],slot=5,state="off"}}
   end,
   outfitSlot=function(_self,slot) return fitted[slot] end,
   outfitRmSlot=function(_self,slot)
      if not fitted[slot] then return false end
      fitted[slot]=nil
      _self.removed_slot=slot
      return true
   end,
}
local env=setmetatable({
   _=function(value) return value end,
   naev={cache=function()
      cache.multiplayer_p2p_config={enabled=enabled}
      cache.multiplayer_p2p_objects=object_capable
      return cache
   end},
   player={
      pilot=function() return pilot end,
      isLanded=function() return landed end,
      msg=function(message) messages[#messages+1]=message end,
   },
   mem={},
},{__index=_G})
assert(loadfile("outfits/unique/message_buoy.lua","t",env))()
local po={state=function() end,progress=function() end}

landed=true
assert(env.ontoggle(pilot,po,true)==false and not cache.multiplayer_buoy_prompt)
landed=false; enabled=false
assert(env.ontoggle(pilot,po,true)==false and not cache.multiplayer_buoy_prompt)
enabled=true; object_capable=false
assert(env.ontoggle(pilot,po,true)==false and not cache.multiplayer_buoy_prompt)
object_capable=true
assert(env.ontoggle(pilot,po,true)==false)
assert(cache.multiplayer_buoy_prompt
   and cache.multiplayer_buoy_prompt.slot==5,
   "activation did not retain the exact fitted slot")
assert(fitted[5],"activation consumed the outfit before acknowledgement")

package.loaded.format={}
package.loaded["multiplayer.client"]={}
package.loaded["multiplayer.server"]={}
package.loaded["multiplayer.p2p.session"]={}
package.loaded.luatk={}
package.loaded.vn={}
naev={cache=function() return cache end}
player={
   pilot=function() return pilot end,
   name=function() return "Captain" end,
}
_=function(value) return value end
assert(loadfile("events/multiplayer.lua"))()
P2P_BUOY_CONSUME(5,"buoy_id")
assert(pilot.removed_slot==5 and fitted[2],
   "safe acknowledgement removed the wrong outfit slot")

print("ok - message buoy outfit acknowledgement lifecycle")
