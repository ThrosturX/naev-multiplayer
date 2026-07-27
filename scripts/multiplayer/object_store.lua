-- Separately versioned persistence for typed P2P directory objects.
local codec = require "multiplayer.p2p.codec"
local Object = require "multiplayer.p2p.objects"

local store = {}
store.VERSION = "MP2P-OBJECTS/1"

function store.encode ( values )
   local lines={store.VERSION}
   local ids={}
   for id in pairs(values or {}) do ids[#ids+1]=id end
   table.sort(ids)
   for _index,id in ipairs(ids) do
      local packed=assert(Object.encode(values[id]))
      lines[#lines+1]=codec.escape(packed)
   end
   return table.concat(lines,"\n").."\n"
end

function store.decode ( payload )
   local values={}
   if type(payload)~="string" or payload=="" then return values end
   local header=payload:match("^([^\n]+)")
   if header~=store.VERSION then return values,"incompatible object database" end
   local corrupt=0
   local total=0
   local first=true
   for line in payload:gmatch("([^\n]+)") do
      if first then
         first=false
      else
         local packed=codec.unescape(line)
         local object=packed and Object.decode(packed) or nil
         if object and not values[object.id]
               and total<Object.MAX_OBJECTS then
            values[object.id]=object
            total=total+1
         else
            corrupt=corrupt+1
         end
      end
   end
   return values,corrupt>0 and ("skipped "..corrupt.." corrupt object record(s)") or nil
end

return store
