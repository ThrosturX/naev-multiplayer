require "ai.core.core"
local atk = require "ai.core.attack.util"
local pod = require "multiplayer.pod_racing"

-- luacheck: globals create control attacked pod_race (AI callbacks/tasks)

mem.aggressive = true
mem.atk_kill = true
mem.atk_board = false
mem.land_planet = false

function create ()
   create_pre()
   create_post()
end

function control ()
   if not ai.taskname() then ai.pushtask("pod_race") end
end

function attacked ( _attacker )
   -- Staying on the course takes precedence over the generic retaliation task.
end

function pod_race ()
   local p=ai.pilot()
   local gate=mem.pod_gate
   if not gate then
      if mem._o and mem._o.afterburner and mem.pod_afterburning then
         p:outfitToggle(mem._o.afterburner,false)
         mem.pod_afterburning=false
      end
      ai.brake()
      return
   end

   local dir=ai.face(gate,nil,true)
   if math.abs(dir)<math.rad(80) then ai.accel() end

   if mem._o and mem._o.afterburner then
      local afterburning=pod.boost_desired(
         mem.pod_afterburning==true,dir,p:energy())
      if afterburning and not mem.pod_afterburning then
         -- Only cache a successful activation so an outfit that is briefly
         -- unavailable is retried on the next AI cycle.
         if p:outfitToggle(mem._o.afterburner,true) then
            mem.pod_afterburning=true
         end
      elseif not afterburning and mem.pod_afterburning then
         p:outfitToggle(mem._o.afterburner,false)
         -- Automatic energy shutdown can make the explicit toggle a no-op.
         -- Clear our request regardless so the boost is retried after recovery.
         mem.pod_afterburning=false
      end
   end

   local target=ai.getenemy()
   if not target or not target:exists() then return end
   local distance=ai.dist(target)
   ai.settarget(target)
   atk.pointdefence()
   atk.fighterbays()
   if distance<=(atk.turrets_range() or 0) then atk.turrets() end
   if distance<=(atk.seeker_turrets_range() or 0) then atk.seeker_turrets() end
   if math.abs(ai.dir(target))<math.rad(18) then
      if distance<=(atk.primary_range() or 0) then atk.primary() end
      if distance<=(atk.secondary_range() or 0) then atk.secondary() end
   end
end
