local wormhole = require "spob.lua.lib.wormhole"

wormhole.setup("multiplayer_wormhole")

function can_land ()
   local target=naev.cache().multiplayer_wormhole_target
   if type(target)~="table" or type(target.system)~="string" then
      return false,_("The unstable wormhole has collapsed.")
   end
   return true,_("The unstable wormhole is active.")
end

function land ( _spob, p )
   local target=naev.cache().multiplayer_wormhole_target
   if type(target)~="table" or type(target.system)~="string" then return end
   if p:shipvarPeek("wormhole") then return end
   p:shipvarPush("wormhole",true)
   if p~=player.pilot() then
      p:effectAdd("Wormhole Enter")
      return
   end
   naev.cache().multiplayer_wormhole_travel={
      object_id=target.object_id,
      system=target.system,x=target.x,y=target.y,
   }
   naev.eventStart("Multiplayer Wormhole")
end
