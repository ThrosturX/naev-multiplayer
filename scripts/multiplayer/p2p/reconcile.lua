-- Sequence filtering and capped motion correction, independent of Naev.
local reconcile = {}

function reconcile.accept ( sequences, stream, sequence )
   local seq=tonumber(sequence)
   if not seq or seq <= (sequences[stream] or -1) then return false end
   sequences[stream]=seq
   return true
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
   local length_squared = x * x + y * y

   if length_squared <= cap * cap then
      return x, y
   end

   local scale = cap / math.sqrt(length_squared)
   return x * scale, y * scale
end

-- Returns a partial authoritative position correction only when the squared
-- error exceeds the configured threshold. This keeps the common path free of
-- square roots and leaves smaller errors to velocity reconciliation.
function reconcile.catchup_position ( x, y, wanted_x, wanted_y,
      distance, bias )
   distance=math.max(0,tonumber(distance) or 2000)
   bias=math.max(0,math.min(1,tonumber(bias) or 0.5))
   local dx=wanted_x-x
   local dy=wanted_y-y
   if dx*dx+dy*dy<=distance*distance then return x,y,false end
   return x+dx*bias,y+dy*bias,true
end

-- Allocation-free production path. Steers a replica toward an extrapolated
-- network snapshot without writing its position; Naev's physics remains
-- responsible for visible movement.
function reconcile.steer_values ( x, y, vx, vy, dir, wanted, dt, age, limits )
   limits=limits or {}
   dt=math.max(0,math.min(tonumber(dt) or 1/60,limits.max_dt or 0.1))
   age=math.max(0,math.min(tonumber(age) or 0,limits.max_prediction or 0.25))
   local wanted_x=wanted.x+wanted.vx*age
   local wanted_y=wanted.y+wanted.vy*age
   local correction_x=(wanted_x-x)*(limits.position_gain or 2)
   local correction_y=(wanted_y-y)*(limits.position_gain or 2)
   correction_x,correction_y=capped_vector(correction_x,correction_y,
      limits.correction_speed or 500)
   local wanted_vx=wanted.vx+correction_x
   local wanted_vy=wanted.vy+correction_y
   local velocity_rate=limits.velocity_rate or 12
   local acceleration=limits.acceleration or 2400
   local direction_rate=limits.direction_rate or 14
   local corrected_vx,corrected_vy
   if limits.follow_velocity then
      -- Frequent authoritative records can apply their ordinary velocity
      -- directly. Callers that require an exact stationary declaration opt in
      -- with rest_source_speed; otherwise position bias still closes an offset
      -- when the authoritative velocity happens to be zero.
      local source_speed=wanted.vx*wanted.vx+wanted.vy*wanted.vy
      local rest_speed=limits.rest_source_speed
      if rest_speed
            and source_speed<=rest_speed*rest_speed then
         corrected_vx=0
         corrected_vy=0
      else
         corrected_vx=wanted_vx
         corrected_vy=wanted_vy
      end
   else
      corrected_vx=smooth_value(
         vx,wanted_vx,velocity_rate,acceleration,dt)
      corrected_vy=smooth_value(
         vy,wanted_vy,velocity_rate,acceleration,dt)
   end
   local rest_source_speed=limits.rest_source_speed
   if rest_source_speed
         and wanted.vx*wanted.vx+wanted.vy*wanted.vy
            <=rest_source_speed*rest_source_speed then
      local rest_position=limits.rest_position or 1
      local error_x=wanted_x-x
      local error_y=wanted_y-y
      local rest_replica_speed=limits.rest_replica_speed or 1
      if error_x*error_x+error_y*error_y<=rest_position*rest_position
            and corrected_vx*corrected_vx+corrected_vy*corrected_vy
               <=rest_replica_speed*rest_replica_speed then
         corrected_vx=0
         corrected_vy=0
      end
   end
   local direction_step=angle_delta(dir,wanted.dir)*(1-math.exp(-direction_rate*dt))
   local direction_cap=(limits.direction_speed or math.huge)*dt
   if direction_step>direction_cap then direction_step=direction_cap
   elseif direction_step < -direction_cap then direction_step=-direction_cap end
   return corrected_vx,corrected_vy,(dir+direction_step)%(2*math.pi)
end

-- Table wrapper retained for callers outside the runtime hot path.
function reconcile.steer ( current, wanted, dt, age, limits )
   local vx,vy,dir=reconcile.steer_values(current.x,current.y,current.vx,
      current.vy,current.dir,wanted,dt,age,limits)
   return {vx=vx,vy=vy,dir=dir}
end

return reconcile
