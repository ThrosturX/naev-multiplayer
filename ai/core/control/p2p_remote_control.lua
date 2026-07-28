-- luacheck: globals control_rate control attacked create mem ai
local atk = require "ai.core.attack.util"

-- State packets arrive at 15 Hz. Reading durable desired controls avoids the
-- old task queue race where the next packet cleared a fire task before the AI
-- controller had a chance to execute it.
control_rate = 0.05

function control ()
   ai.accel(mem.p2p_accel or 0)
   if mem.p2p_weapset~=nil and mem.p2p_applied_weapset~=mem.p2p_weapset then
      ai.weapset(mem.p2p_weapset)
      mem.p2p_applied_weapset=mem.p2p_weapset
   end
   if mem.p2p_primary or (mem.p2p_primary_edges or 0)>0 then
      atk.primary()
      mem.p2p_primary_ticks=(mem.p2p_primary_ticks or 0)+1
      if (mem.p2p_primary_edges or 0)>0 then
         mem.p2p_primary_edges=mem.p2p_primary_edges-1
      end
   end
   if mem.p2p_secondary or (mem.p2p_secondary_edges or 0)>0 then
      atk.secondary()
      mem.p2p_secondary_ticks=(mem.p2p_secondary_ticks or 0)+1
      if (mem.p2p_secondary_edges or 0)>0 then
         mem.p2p_secondary_edges=mem.p2p_secondary_edges-1
      end
   end
end

function attacked ( _attacker )
end

function create ()
   mem.p2p_accel=0
   mem.p2p_primary=false
   mem.p2p_secondary=false
   mem.p2p_primary_ticks=0
   mem.p2p_secondary_ticks=0
   mem.p2p_primary_edges=0
   mem.p2p_secondary_edges=0
   mem.p2p_weapset=1
   mem.p2p_applied_weapset=nil
end
