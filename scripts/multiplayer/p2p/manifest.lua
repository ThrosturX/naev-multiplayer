-- Static pilot descriptions used to construct and apply gameplay manifests.
local gameplay_codec = require "multiplayer.p2p.gameplay_codec"

local manifest = {}

local function outfit_names ( p )
   local names={}
   for _index,o in ipairs(p:outfitsList()) do
      names[#names+1]=gameplay_codec.escape(o:nameRaw())
   end
   return table.concat(names,",")
end

local function outfit_slots ( p )
   local slots={}
   for index,o in pairs(p:outfits()) do
      if type(index)=="number" and o then
         slots[#slots+1]={
            index=index,
            value=tostring(index)..":"
               ..gameplay_codec.escape(o:nameRaw()),
         }
      end
   end
   table.sort(slots,function ( a,b ) return a.index<b.index end)
   local values={}
   for index,entry in ipairs(slots) do values[index]=entry.value end
   return table.concat(values,",")
end

local function weapon_sets ( p )
   local sets={}
   for id=1,10 do
      local slots={}
      for _index,slot in ipairs(p:weapsetList(id)) do
         slot=tonumber(slot)
         if slot and slot>=1 and slot<=512 then
            slots[#slots+1]=tostring(math.floor(slot))
         end
      end
      sets[#sets+1]=tostring(id)..":"..table.concat(slots,".")
   end
   return table.concat(sets,";")
end

local function ship_fallback_names ( s )
   local names,seen={},{}
   local inherited=s:inherits()
   while inherited and #names<16 do
      local name=inherited:nameRaw()
      if type(name)~="string" or name=="" or seen[name] then break end
      seen[name]=true
      names[#names+1]=gameplay_codec.escape(name)
      inherited=inherited:inherits()
   end
   local base_type=s:baseType()
   if #names<16 and type(base_type)=="string" and base_type~=""
         and not seen[base_type] and ship.exists(base_type) then
      names[#names+1]=gameplay_codec.escape(base_type)
   end
   return table.concat(names,",")
end

local function resource_get ( getter, name )
   local ok,value=pcall(getter,name)
   if ok then return value end
end

function manifest.player ( p, context )
   local current_ship=p:ship()
   local message=context.base
   message.owner=context.owner
   message.entity=context.entity
   message.origin=context.origin
   message.ship=current_ship:nameRaw()
   message.ship_fallbacks=ship_fallback_names(current_ship)
   message.name=context.name
   message.outfits=outfit_names(p)
   if message.outfits=="" then message.outfits="-" end
   message.slots=outfit_slots(p)
   if message.slots=="" then message.slots="-" end
   message.weapsets=weapon_sets(p)
   if message.weapsets=="" then message.weapsets="-" end
   for key,value in pairs(context.state) do
      if key~="entity" then message[key]=value end
   end
   return message
end

function manifest.authority ( p, entry, context )
   local message=context.base
   message.kind=entry.kind
   message.owner=entry.owner
   message.entity=entry.entity
   message.origin=entry.origin
   message.ship=p:ship():nameRaw()
   message.name=p:name()
   message.faction=p:faction():nameRaw()
   message.ai=entry.ai or p:ainame() or "dummy"
   message.outfits=outfit_names(p)
   if message.outfits=="" then message.outfits="-" end
   message.slots=outfit_slots(p)
   if message.slots=="" then message.slots="-" end
   message.leader=context.leader or "-"
   for key,value in pairs(context.state) do
      if key~="entity" then message[key]=value end
   end
   return message
end

function manifest.resolve_proxy_ship ( message )
   if resource_get(ship.get,message.ship) then return message.ship,true end
   for encoded in (message.ship_fallbacks or ""):gmatch("([^,]+)") do
      local name=gameplay_codec.unescape(encoded)
      if name and resource_get(ship.get,name) then return name,true end
   end
   if resource_get(ship.get,"Plowshare") then return "Plowshare",false end
end

local function replica_outfit_allowed ( o )
   -- Fighter craft have their own owner-generated manifests. A replica carrier
   -- must never launch a second speculative copy.
   return o:type()~="Fighter Bay"
end

function manifest.install_outfits ( p, message, compatible )
   local used_slots=false
   if not compatible then
      for item in (message.slots or ""):gmatch("([^,]+)") do
         local index,encoded=item:match("^(%d+):(.+)$")
         index=tonumber(index)
         local name=encoded and gameplay_codec.unescape(encoded)
         local o=name and outfit.exists(name) or nil
         if index and index>=1 and index<=512 and o
               and replica_outfit_allowed(o) then
            p:outfitAddSlot(o,index,true,true)
            used_slots=true
         end
      end
   end
   if used_slots then return end
   for item in (message.outfits or ""):gmatch("([^,]+)") do
      local name=gameplay_codec.unescape(item)
      local o=name and outfit.exists(name) or nil
      if o and replica_outfit_allowed(o) then
         p:outfitAdd(o,1,true,compatible and false or nil)
      end
   end
end

function manifest.install_weapon_sets ( p, packed )
   if packed==nil then return end
   p:weapsetCleanup()
   local installed=p:outfits()
   for line in packed:gmatch("([^;]+)") do
      local id,slots=line:match("^(%d+):(.*)$")
      id=tonumber(id)
      if id and id>=1 and id<=10 then
         for value in slots:gmatch("(%d+)") do
            local slot=tonumber(value)
            if slot and slot>=1 and slot<=512 and installed[slot] then
               p:weapsetAdd(id,slot)
            end
         end
      end
   end
end

return manifest
