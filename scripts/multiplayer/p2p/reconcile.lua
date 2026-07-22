-- Sequence filtering and capped motion correction, independent of Naev.
local reconcile = {}

function reconcile.accept ( sequences, stream, sequence )
   local seq=tonumber(sequence)
   if not seq or seq <= (sequences[stream] or -1) then return false end
   sequences[stream]=seq
   return true
end

local function capped ( current, wanted, cap )
   local delta=wanted-current
   if delta > cap then return current+cap end
   if delta < -cap then return current-cap end
   return wanted
end

function reconcile.motion ( current, wanted, position_cap, velocity_cap )
   return {
      x=capped(current.x, wanted.x, position_cap),
      y=capped(current.y, wanted.y, position_cap),
      vx=capped(current.vx, wanted.vx, velocity_cap),
      vy=capped(current.vy, wanted.vy, velocity_cap),
      dir=wanted.dir,
   }
end

function reconcile.apply_npc ( adapter, entity, state, initial )
   if initial then adapter.set_motion(entity, state) else adapter.soft_motion(entity, state) end
   adapter.set_health(entity, state.armour, state.shield, state.stress)
   if state.energy then adapter.set_energy(entity, state.energy) end
end

function reconcile.apply_player ( adapter, entity, state, is_local )
   if is_local then return false end -- in particular, never write local health
   adapter.soft_motion(entity, state)
   return true
end

function reconcile.host_lost ( replicas )
   for _entity_id, replica in pairs(replicas) do replica.authoritative=true end
   return replicas -- native AI is intentionally retained
end

return reconcile
