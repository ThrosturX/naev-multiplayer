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

local function smooth_value ( current, wanted, rate, speed, dt )
   local delta=wanted-current
   local step=delta*(1-math.exp(-rate*dt))
   local cap=speed*dt
   if step > cap then step=cap
   elseif step < -cap then step=-cap end
   return current+step
end

local function angle_delta ( current, wanted )
   local tau=2*math.pi
   return (wanted-current+math.pi)%tau-math.pi
end

local function capped_vector ( x, y, cap )
   local length=math.sqrt(x*x+y*y)
   if length<=cap or length==0 then return x,y end
   local scale=cap/length
   return x*scale,y*scale
end

-- Steers a replica toward an extrapolated network snapshot without writing
-- its position. Naev's own physics remains responsible for visible movement.
function reconcile.steer ( current, wanted, dt, age, limits )
   limits=limits or {}
   dt=math.max(0,math.min(tonumber(dt) or 1/60,limits.max_dt or 0.1))
   age=math.max(0,math.min(tonumber(age) or 0,limits.max_prediction or 0.25))
   local wanted_x=wanted.x+wanted.vx*age
   local wanted_y=wanted.y+wanted.vy*age
   local correction_x=(wanted_x-current.x)*(limits.position_gain or 2)
   local correction_y=(wanted_y-current.y)*(limits.position_gain or 2)
   correction_x,correction_y=capped_vector(correction_x,correction_y,
      limits.correction_speed or 500)
   local wanted_vx=wanted.vx+correction_x
   local wanted_vy=wanted.vy+correction_y
   local velocity_rate=limits.velocity_rate or 12
   local acceleration=limits.acceleration or 2400
   local direction_rate=limits.direction_rate or 14
   local direction_step=angle_delta(current.dir,wanted.dir)*(1-math.exp(-direction_rate*dt))
   return {
      vx=smooth_value(current.vx,wanted_vx,velocity_rate,acceleration,dt),
      vy=smooth_value(current.vy,wanted_vy,velocity_rate,acceleration,dt),
      dir=(current.dir+direction_step)%(2*math.pi),
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
