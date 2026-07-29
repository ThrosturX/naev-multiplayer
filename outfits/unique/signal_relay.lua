local OUTFIT_NAME = "Signal Relay"

local function fitted_slot ( p )
   for _index,entry in ipairs(p:actives()) do
      if entry.outfit and entry.outfit:nameRaw()==OUTFIT_NAME then
         return entry.slot
      end
   end
   for index,value in pairs(p:outfits()) do
      if value and value:nameRaw()==OUTFIT_NAME then return index end
   end
end

function init ( p, po )
   if p~=player.pilot() then return end
   po:state("off")
   po:progress(0)
end

function ontoggle ( p, _po, on )
   if p~=player.pilot() or not on then return false end
   if player.isLanded() then
      player.msg("#r".._("Signal relays can only be deployed in space.").."#0")
      return false
   end
   local cache=naev.cache()
   local config=cache.multiplayer_p2p_config
   if type(config)~="table" or config.enabled~=true then
      player.msg("#r".._("Enable P2P multiplayer before deploying a signal relay.").."#0")
      return false
   end
   if cache.multiplayer_p2p_objects~=true then
      player.msg("#r".._("Your systems need more time to calibrate.").."#0")
      return false
   end
   if cache.multiplayer_object_deploy then return false end
   local slot=fitted_slot(p)
   if not slot then
      player.msg("#r".._("The fitted signal relay could not be found.").."#0")
      return false
   end
   cache.multiplayer_object_deploy={kind="signal_relay",slot=slot}
   return false
end
