package.path = "scripts/?.lua;scripts/?/init.lua;" .. package.path

mem={pod_gate={}}
local timers={[0]=0,[1]=0}
local primary,secondary=0,0
local aligned=true
local target={exists=function() return true end}
local pilot={
   energy=function() return 100 end,
   weapset=function(_self,weapon_set)
      if weapon_set==1 then
         return "Primary",{{
            charge=1,
            outfit={specificstats=function() return {duration=4} end},
         }}
      end
      return "Secondary",{{
         outfit={specificstats=function() return {} end},
      }}
   end,
}

ai={
   pilot=function() return pilot end,
   taskname=function() return "pod_race" end,
   getenemy=function() return target end,
   dist=function() return 100 end,
   dir=function() return aligned and 0 or math.rad(30) end,
   face=function() return 0 end,
   accel=function() end,
   settarget=function() end,
   timeup=function(index) return timers[index]<=0 end,
   settimer=function(index,duration) timers[index]=duration end,
}
create_pre=function() end
create_post=function() end

package.preload["ai.core.core"]=function() return true end
package.preload["ai.core.attack.util"]=function()
   return {
      pointdefence=function() end,
      fighterbays=function() end,
      turrets_range=function() return 0 end,
      seeker_turrets_range=function() return 0 end,
      primary_range=function() return 500 end,
      secondary_range=function() return 500 end,
      primary=function() primary=primary+1 end,
      secondary=function() secondary=secondary+1 end,
   }
end
package.preload["multiplayer.pod_racing"]=function()
   return {boost_desired=function() return false end}
end

assert(loadfile("ai/pod_racer.lua"))()
create()
assert(mem.pod_primary_beam_duration==4)
assert(mem.pod_secondary_beam_duration==0)

pod_race()
assert(primary==1 and secondary==1 and timers[0]==4 and timers[1]==0)

aligned=false
pod_race()
assert(primary==2,"beam group was not held after leaving the firing cone")
assert(secondary==1,"non-beam group was incorrectly held")

timers[0]=0
pod_race()
assert(primary==2,"beam group remained held after its configured duration")

print("ok - pod racer sustained beam fire")
