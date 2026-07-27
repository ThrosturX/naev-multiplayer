require "ai.core.core"
local atk = require "ai.core.attack.util"
local pod = require "multiplayer.pod_racing"

-- luacheck: globals create control attacked pod_race (AI callbacks/tasks)

mem.aggressive = true
mem.atk_kill = true
mem.atk_board = false
mem.land_planet = false

local function beam_duration ( p, weapon_set )
   local _name,weapons=p:weapset(weapon_set)
   local duration=0
   for _index,weapon in ipairs(weapons) do
      if weapon.charge~=nil then
         local configured=weapon.outfit:specificstats().duration
         duration=math.max(duration,tonumber(configured) or 0)
      end
   end
   return duration
end

function create ()
   create_pre()
   create_post()
   local p=ai.pilot()
   mem.pod_primary_beam_duration=beam_duration(p,1)
   mem.pod_secondary_beam_duration=beam_duration(p,2)
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
   local primary_held=mem.pod_primary_beam_duration>0 and not ai.timeup(0)
   local secondary_held=mem.pod_secondary_beam_duration>0 and not ai.timeup(1)
   if primary_held then atk.primary() end
   if secondary_held then atk.secondary() end
   if math.abs(ai.dir(target))<math.rad(18) then
      if distance<=(atk.primary_range() or 0) then
         atk.primary()
         if mem.pod_primary_beam_duration>0 and not primary_held then
            ai.settimer(0,mem.pod_primary_beam_duration)
         end
      end
      if distance<=(atk.secondary_range() or 0) then
         atk.secondary()
         if mem.pod_secondary_beam_duration>0 and not secondary_held then
            ai.settimer(1,mem.pod_secondary_beam_duration)
         end
      end
   end
end
