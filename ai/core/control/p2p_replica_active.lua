-- luacheck: globals control_rate control attacked create mem ai
local atk = require "ai.core.attack.util"

-- The runtime chooses the target and the bounded active set. This controller
-- only reproduces the host's firing intent and never chooses motion or tasks.
control_rate = 0.08

function control ()
   ai.accel(0)
   if mem.p2p_weapset~=nil and mem.p2p_applied_weapset~=mem.p2p_weapset then
      ai.weapset(mem.p2p_weapset)
      mem.p2p_applied_weapset=mem.p2p_weapset
   end
   if mem.p2p_primary then atk.primary() end
   if mem.p2p_secondary then atk.secondary() end
end

function attacked ( _attacker )
end

function create ()
   mem.p2p_primary=false
   mem.p2p_secondary=false
   mem.p2p_weapset=1
   mem.p2p_applied_weapset=nil
end
