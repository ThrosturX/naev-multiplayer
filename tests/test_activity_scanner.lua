local local_pilot={}
local messages={}
local cache={}
local targets={
   ["One Jump Away"]={name="One Jump Away"},
}
local origin={
   nameRaw=function() return "Origin" end,
   jumpDist=function(_self,target,hidden,known)
      assert(target==targets["One Jump Away"])
      assert(hidden==false and known==true)
      return 1
   end,
}

local env=setmetatable({
   mem={},
   naev={cache=function() return cache end},
   player={
      pilot=function() return local_pilot end,
      isLanded=function() return false end,
      msg=function(message) messages[#messages+1]=message end,
   },
   system={
      cur=function() return origin end,
      get=function(name)
         local target=targets[name]
         if not target then error("unknown system") end
         return target
      end,
   },
   _=function(value) return value end,
},{__index=_G})

assert(loadfile("outfits/unique/activity_scanner.lua","t",env))()
assert(env.notactive==true)

cache.multiplayer_activity={
   received=100,
   entries={
      {system="Unknown System",active=true},
      {system="One Jump Away",active=true},
   },
}
env.init(local_pilot)
assert(#messages==1 and messages[1]=="Activity detected within 1 jumps.",
   "scanner did not report cached activity during system entry")

env.update(local_pilot,nil,0.1)
assert(#messages==1,"scanner repeated an unchanged activity snapshot")

cache.multiplayer_activity.received=101
env.update(local_pilot,nil,0.1)
assert(#messages==1,"scanner repeated activity before its memory expired")

cache.multiplayer_activity.received=400
env.update(local_pilot,nil,0.1)
assert(#messages==2 and messages[2]=="Activity detected within 1 jumps.",
   "scanner did not report activity again after its memory expired")

print("ok - activity scanner resolves and reports remote systems")
