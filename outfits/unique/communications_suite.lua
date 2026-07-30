-- luacheck: globals init ontoggle player

function init ( p, po )
   if p~=player.pilot() then return end
   po:state("off")
   po:progress(0)
end

function ontoggle ( p, po, on )
   if p~=player.pilot() then return false end
   po:state(on and "on" or "off")
   po:progress(on and 1 or 0)
   return true
end
