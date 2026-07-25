notactive = true

local MEMORY = 5*60

local function snapshot ()
   local s=naev.cache().multiplayer_activity
   if type(s)~="table" or type(s.received)~="number"
         or type(s.entries)~="table" then
      return nil
   end
   return s
end

local function process ( entries, stamp )
   local reported=mem.reported

   for system_name,last in pairs(reported) do
      if stamp<last or stamp-last>=MEMORY then
         reported[system_name]=nil
      end
   end
   for _index,entry in ipairs(entries) do
      if not entry.active then reported[entry.system]=nil end
   end

   local origin=system.cur()
   if not origin then return end
   local origin_name=origin:nameRaw()
   local nearest,farthest

   for _index,entry in ipairs(entries) do
      local system_name=entry.system
      if entry.active and system_name==origin_name then
         reported[system_name]=stamp
      elseif entry.active and not reported[system_name] then
         local target=system.exists(system_name)
         local distance=target and origin:jumpDist(target,false,true)
         if distance and distance<math.huge then
            distance=math.floor(distance)
            reported[system_name]=stamp
            nearest=nearest and math.min(nearest,distance) or distance
            farthest=farthest and math.max(farthest,distance) or distance
         end
      end
   end

   if not nearest then return end
   if nearest==farthest then
      player.msg(string.format(_("Activity detected within %d jumps."),nearest))
   else
      player.msg(string.format(
         _("Activity detected between %d-%d jumps."),nearest,farthest))
   end
end

function init ( p, _po )
   if p~=player.pilot() then return end
   mem.reported=mem.reported or {}
   local s=snapshot()
   mem.last_received=s and s.received or nil
end

function update ( p, _po, _dt )
   if p~=player.pilot() then return end
   local s=snapshot()
   if not s or s.received==mem.last_received then return end
   mem.last_received=s.received
   if player.isLanded() then return end
   process(s.entries,s.received)
end
