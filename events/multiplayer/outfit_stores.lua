--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Multiplayer Outfit Stores">
 <location>load</location>
 <chance>100</chance>
 <priority>-10</priority>
</event>
--]]

function create ()
   local stores_diff = "multiplayer_outfit_stores"
   if not diff.isApplied(stores_diff) then
      diff.apply(stores_diff)
   end

   local emergency_generator=outfit.get("Emergency Wormhole Generator")
   local unstable_store_diff="multiplayer_unstable_wormhole_store"
   if player.outfitNum(emergency_generator,true)>0
         and not diff.isApplied(unstable_store_diff) then
      diff.apply(unstable_store_diff)
   end
   evt.finish()
end
