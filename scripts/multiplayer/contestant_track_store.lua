local codec = require "multiplayer.p2p.codec"

local store = {}
local HEADER = "MP2P-CONTESTANT-TRACKS/1"
local FIELDS = {
   "node", "track", "seen", "division", "name", "ship",
   "ship_fallbacks", "outfits", "slots",
}

local function key_for ( node, track, division )
   return node..":"..track..":"..tostring(division)
end

local function valid_record ( record )
   local message = {
      type="contestant_register",
      node=record.node,
      track=record.track,
      division=record.division,
      name=record.name,
      ship=record.ship,
      ship_fallbacks=record.ship_fallbacks or "",
      outfits=record.outfits,
      slots=record.slots,
   }
   local checked=codec.validate(message)
   local seen=tonumber(record.seen)
   if not checked or not seen or seen<0 then return nil end
   checked.seen=seen
   return checked
end

function store.encode ( contestants )
   local records={}
   for _key,record in pairs(contestants or {}) do
      local checked=valid_record(record)
      if checked then records[#records+1]=checked end
   end
   table.sort(records,function(a,b)
      if a.node~=b.node then return a.node<b.node end
      if a.track~=b.track then return a.track<b.track end
      return a.division<b.division
   end)

   local lines={HEADER}
   for _index,record in ipairs(records) do
      local fields={}
      for index,key in ipairs(FIELDS) do
         fields[index]=codec.escape(record[key] or "")
      end
      lines[#lines+1]=table.concat(fields,"\t")
   end
   return table.concat(lines,"\n").."\n"
end

function store.decode ( data )
   local contestants={}
   if type(data)~="string" then return contestants end
   local first=true
   for line in data:gmatch("([^\n]*)\n?") do
      if first then
         first=false
         if line~=HEADER then return {} end
      elseif line~="" then
         local fields={}
         for field in (line.."\t"):gmatch("(.-)\t") do
            local value=codec.unescape(field)
            if value==nil then fields={}; break end
            fields[#fields+1]=value
         end
         if #fields==#FIELDS then
            local record={}
            for index,key in ipairs(FIELDS) do record[key]=fields[index] end
            record.division=tonumber(record.division)
            local checked=valid_record(record)
            if checked then
               contestants[key_for(checked.node,checked.track,
                  checked.division)]=checked
            end
         end
      end
   end
   return contestants
end

return store
