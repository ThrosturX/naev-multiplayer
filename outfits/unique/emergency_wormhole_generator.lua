local Cooldown = require "multiplayer.p2p.wormhole_generator_cooldown"

local FUEL_PER_JUMP = 600
local ENERGY_COST = 600
local COOLDOWN = 2*60
local SOURCE_OFFSET = 600
local TARGET_RADIUS_FRACTION = 0.55
local STORAGE_SYSTEM = "Multiplayer Lobby"

local function destination_candidates ( source, maximum_jumps )
   local candidates={}
   for _index,candidate in ipairs(system.getAll()) do
      local tags=candidate:tags() or {}
      local name=candidate:nameRaw()
      if candidate~=source and name~=STORAGE_SYSTEM
            and not tags.restricted and not tags.spoiler then
         local ok,distance=pcall(source.jumpDist,source,candidate,false)
         distance=ok and tonumber(distance) or nil
         if distance and distance>=1 and distance<=maximum_jumps then
            candidates[#candidates+1]={system=candidate,distance=distance}
         end
      end
   end
   return candidates
end

function descextra ()
   return _("Consumes 600 GJ of energy and all remaining fuel. Opens a one-way wormhole with a 2-minute lifetime and cooldown.")
end

function init ( p, po )
   Cooldown.init(p,po,mem,"emergency",COOLDOWN)
end

function update ( p, po, dt )
   Cooldown.update(p,po,dt,mem,"emergency",COOLDOWN)
end

function ontoggle ( p, po, on, natural )
   if p~=player.pilot() or on~=true or natural~=true then return false end
   if not Cooldown.ready(mem,"emergency") then
      player.msg("#r".._("The Emergency Wormhole Generator is cooling down.").."#0")
      return false
   end
   if player.isLanded() then
      player.msg("#r".._("Emergency wormholes can only be opened in space.").."#0")
      return false
   end
   local source=system.cur()
   if not naev.claimTest(source) then
      player.msg("#r".._("The device doesn't seem to be working at the moment.").."#0")
      return false
   end
   local cache=naev.cache()
   local config=cache.multiplayer_p2p_config
   if type(config)~="table" or not config.enabled then
      player.msg("#r".._("Enable P2P multiplayer before opening an emergency wormhole.").."#0")
      return false
   end
   if cache.multiplayer_p2p_objects~=true then
      player.msg("#r".._("The device doesn't seem to be properly calibrated. It plays a sorrow tune.").."#0")
      return false
   end
   if cache.multiplayer_wormhole_request or cache.multiplayer_wormhole_pending then
      player.msg("#r".._("A wormhole deployment is already in progress.").."#0")
      return false
   end
   if p:energy(true)<ENERGY_COST then
      player.msg("#r"..string.format(_(
         "The Emergency Wormhole Generator requires %d GJ of energy."),
         ENERGY_COST).."#0")
      return false
   end
   local fuel=p:fuel()
   local maximum_jumps=math.floor(fuel/FUEL_PER_JUMP)
   if maximum_jumps<1 then
      player.msg("#r".._("The Emergency Wormhole Generator requires at least 600 fuel.").."#0")
      return false
   end

   local candidates=destination_candidates(source,maximum_jumps)
   if #candidates==0 then
      player.msg("#r".._("No suitable wormhole destination is within fuel range.").."#0")
      return false
   end
   local selected=candidates[rnd.rnd(1,#candidates)]
   local source_pos=p:pos()+vec2.newP(SOURCE_OFFSET,p:dir())
   local target_pos=vec2.newP(
      selected.system:radius()*TARGET_RADIUS_FRACTION*rnd.rnd(),rnd.angle())
   local source_x,source_y=source_pos:get()
   local target_x,target_y=target_pos:get()
   local activation_id=Cooldown.next_id("emergency")

   p:setFuel(0)
   p:addEnergy(-ENERGY_COST)
   cache.multiplayer_wormhole_request={
      generator="emergency",object_kind="one_way_wormhole",
      activation_id=activation_id,
      source_system=source:nameRaw(),
      source_x=source_x,source_y=source_y,source_dir=p:dir(),
      target_system=selected.system:nameRaw(),
      target_x=target_x,target_y=target_y,target_dir=rnd.angle(),
      fuel_cost=fuel,energy_cost=ENERGY_COST,
   }
   Cooldown.begin(po,mem,"emergency",activation_id)
   player.msg(string.format(_("Magnifying aperture leading to a system %d jumps away…"),
      selected.distance))
   return false
end
