--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Pod Racing Roster">
 <location>enter</location>
 <chance>100</chance>
 <system>Qex</system>
</event>
--]]
local network = require "multiplayer.pod_racing_network"
local START_TIMEOUT = 3
local started, deadline

-- luacheck: globals create update leave (Hook callbacks)

function create ()
   started=false
   deadline=naev.ticks()+START_TIMEOUT
   hook.update("update")
   hook.jumpout("leave")
end

function update ()
   if not started then
      local config=naev.cache().multiplayer_p2p_config
      if type(config)=="table" and config.captain==player.name() then
         if config.enabled~=true then evt.finish(false); return end
         if not network.start(config) then evt.finish(false); return end
         started=true
         return
      end
      if naev.ticks()>=deadline then evt.finish(false) end
      return
   end
   if not network.update() then evt.finish(true) end
end

function leave ()
   network.stop(false)
   evt.finish(true)
end
