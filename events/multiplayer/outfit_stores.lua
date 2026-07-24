--[[
<?xml version='1.0' encoding='utf8'?>
<event name="Multiplayer Outfit Stores">
 <location>load</location>
 <chance>100</chance>
 <priority>-10</priority>
</event>
--]]

function create ()
   local name = "multiplayer_outfit_stores"
   if not diff.isApplied(name) then
      diff.apply(name)
   end
   evt.finish()
end
