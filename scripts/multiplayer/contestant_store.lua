-- Safe, non-executable persistence format for directory contestant profiles.
-- Filesystem access remains in directory/main.lua so this module is testable.
local codec = require "multiplayer.p2p.codec"

local store = {}
local HEADER = "MP2P-CONTESTANTS/1"
local FIELDS = {
   "node", "seen", "division", "name", "ship", "ship_fallbacks",
   "outfits", "slots",
}

local function valid_record ( record )
   local message = {
      type="contestant_register",
      node=record.node,
      division=record.division,
      name=record.name,
      ship=record.ship,
      ship_fallbacks=record.ship_fallbacks,
      outfits=record.outfits,
      slots=record.slots,
   }
   if not codec.validate(message) then return nil end
   local seen=tonumber(record.seen)
   if not seen or seen<0 or seen~=seen then return nil end
   message.seen=math.floor(seen)
   return message
end

function store.encode ( contestants )
   local records={}
   for _node,record in pairs(contestants or {}) do
      local checked=valid_record(record)
      if checked then records[#records+1]=checked end
   end
   table.sort(records,function(a,b) return a.node<b.node end)

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
   if type(data)~="string" then return {} end
   local header,body=data:match("^([^\n]*)\n?(.*)$")
   if header~=HEADER then return {} end

   local contestants={}
   for line in body:gmatch("([^\n]+)") do
      local fields={}
      for value in (line.."\t"):gmatch("([^\t]*)\t") do
         fields[#fields+1]=codec.unescape(value)
      end
      if #fields==#FIELDS then
         local record={}
         for index,key in ipairs(FIELDS) do record[key]=fields[index] end
         record.division=tonumber(record.division)
         local checked=valid_record(record)
         if checked then contestants[checked.node]=checked end
      end
   end
   return contestants
end

return store
