-- luacheck: globals control_rate control attacked create mem ai
local atk = require "ai.core.attack.util"

-- State packets arrive at 15 Hz. Reading durable desired controls avoids the
-- old task queue race where the next packet cleared a fire task before the AI
-- controller had a chance to execute it.
control_rate = 0.05

function control ()
   ai.accel(mem.p2p_accel or 0)
   if mem.p2p_primary then atk.primary() end
   if mem.p2p_secondary then atk.secondary() end
end

function attacked ( _attacker )
end

function create ()
   mem.p2p_accel=0
   mem.p2p_primary=false
   mem.p2p_secondary=false
end
