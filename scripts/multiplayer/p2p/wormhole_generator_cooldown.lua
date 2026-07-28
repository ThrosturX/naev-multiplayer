-- Shared presentation state for wormhole-generator outfits. The directory
-- confirms the activation before the real cooldown begins. Confirmed deadlines
-- live in naev.cache() so outfit reinitialization does not make an active
-- generator appear ready again.
local cooldown = {}

local function deadlines ()
   local cache=naev.cache()
   cache.multiplayer_wormhole_cooldowns=
      cache.multiplayer_wormhole_cooldowns or {}
   return cache.multiplayer_wormhole_cooldowns
end

local function remaining ( key )
   local deadline=tonumber(deadlines()[key]) or 0
   return math.max(0,deadline-naev.ticks())
end

local function refresh ( po, state, key, duration )
   if state.activation_id then
      po:state("cooldown")
      po:progress(1)
      return
   end
   local left=remaining(key)
   if left>0 then
      po:state("cooldown")
      po:progress(math.min(1,left/duration))
   else
      deadlines()[key]=nil
      po:state("off")
      po:progress(0)
   end
end

function cooldown.init ( p, po, state, key, duration )
   if p~=player.pilot() then return end
   local pending=naev.cache().multiplayer_wormhole_activation_pending
   state.activation_id=type(pending)=="table" and pending.generator==key
      and pending.id or nil
   refresh(po,state,key,duration)
end

function cooldown.ready ( state, key )
   local pending=naev.cache().multiplayer_wormhole_activation_pending
   local waiting=state.activation_id~=nil
      or (type(pending)=="table" and pending.generator==key)
   return not waiting and remaining(key)<=0
end

function cooldown.next_id ( key )
   local cache=naev.cache()
   local sequence=(tonumber(cache.multiplayer_wormhole_activation_sequence) or 0)+1
   cache.multiplayer_wormhole_activation_sequence=sequence
   return tostring(key).."_"..tostring(sequence)
end

function cooldown.begin ( po, state, key, activation_id )
   local cache=naev.cache()
   cache.multiplayer_wormhole_activation_result=nil
   cache.multiplayer_wormhole_activation_pending={
      id=activation_id,generator=key,
   }
   state.activation_id=activation_id
   po:state("cooldown")
   po:progress(1)
end

function cooldown.update ( p, po, _dt, state, key, duration )
   if p~=player.pilot() then return end
   local cache=naev.cache()
   local result=cache.multiplayer_wormhole_activation_result
   if type(result)=="table" and result.generator==key
         and (state.activation_id==nil or result.id==state.activation_id) then
      cache.multiplayer_wormhole_activation_result=nil
      local pending=cache.multiplayer_wormhole_activation_pending
      if type(pending)=="table" and pending.id==result.id then
         cache.multiplayer_wormhole_activation_pending=nil
      end
      state.activation_id=nil
      if result.ok then
         deadlines()[key]=(tonumber(result.started) or naev.ticks())+duration
      else
         deadlines()[key]=nil
      end
   end
   refresh(po,state,key,duration)
end

return cooldown
