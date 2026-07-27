-- Typed persistent-object validation and compact wire encoding. This module
-- deliberately has no Naev or ENet dependencies.
local codec = require "multiplayer.p2p.codec"

local objects = {}

objects.MAX_OBJECTS = 4096
objects.MAX_ENDPOINTS = 8
objects.MAX_DATA = 2048

local kinds = {
   message_buoy=true,
   one_way_wormhole=true,
   two_way_wormhole=true,
   registration_post=true,
}

local function plain_string ( value, maximum, pattern )
   return type(value)=="string" and value~="" and #value<=maximum
      and not value:find("[%z\1-\31\127]")
      and (not pattern or value:match(pattern)~=nil)
end

local function finite ( value, minimum, maximum )
   return type(value)=="number" and value==value
      and value>=minimum and value<=maximum
end

local function copy_endpoint ( endpoint )
   return {
      id=endpoint.id,
      system=endpoint.system,
      x=endpoint.x,
      y=endpoint.y,
      dir=endpoint.dir,
      role=endpoint.role,
      visible=endpoint.visible,
      target=endpoint.target,
   }
end

local function copy_object ( object )
   local out={
      id=object.id,
      kind=object.kind,
      owner=object.owner,
      created=object.created,
      revision=object.revision,
      data={},
      endpoints={},
   }
   for key,value in pairs(object.data or {}) do out.data[key]=value end
   for index,endpoint in ipairs(object.endpoints or {}) do
      out.endpoints[index]=copy_endpoint(endpoint)
   end
   return out
end

local function endpoint_map ( object )
   local endpoints={}
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoints[endpoint.id] then return nil,"duplicate endpoint id" end
      endpoints[endpoint.id]=endpoint
   end
   return endpoints
end

local function validate_relationships ( object, endpoints )
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.target and not endpoints[endpoint.target] then
         return nil,"dangling or cross-object endpoint link"
      end
   end

   if object.kind=="message_buoy" or object.kind=="registration_post" then
      local endpoint=object.endpoints[1]
      if #object.endpoints~=1 or endpoint.role~="physical"
            or endpoint.visible~=true or endpoint.target then
         return nil,"invalid physical endpoint"
      end
   elseif object.kind=="one_way_wormhole" then
      if #object.endpoints~=2 then return nil,"one-way wormhole requires a pair" end
      local source,destination
      for _index,endpoint in ipairs(object.endpoints) do
         if endpoint.role=="entrance" then source=endpoint
         elseif endpoint.role=="destination" then destination=endpoint
         else return nil,"invalid one-way endpoint role" end
      end
      if not source or not destination or source.visible~=true
            or destination.visible~=false or source.target~=destination.id
            or destination.target then
         return nil,"partially specified one-way wormhole"
      end
   elseif object.kind=="two_way_wormhole" then
      if #object.endpoints~=2 then return nil,"two-way wormhole requires a pair" end
      local first,second=object.endpoints[1],object.endpoints[2]
      if first.role~="mouth" or second.role~="mouth"
            or first.visible~=true or second.visible~=true
            or first.target~=second.id or second.target~=first.id then
         return nil,"two-way wormhole links must be reciprocal"
      end
   end
   return true
end

function objects.validate ( object )
   if type(object)~="table" then return nil,"object is not a table" end
   if not plain_string(object.id,128,"^[%w_%-]+$") then return nil,"invalid object id" end
   if not kinds[object.kind] then return nil,"invalid object kind" end
   if not plain_string(object.owner,128,"^[%x]+$") then return nil,"invalid owner" end
   if not finite(object.created,0,9007199254740991)
         or object.created%1~=0 then return nil,"invalid creation time" end
   if not finite(object.revision,1,9007199254740991)
         or object.revision%1~=0 then return nil,"invalid revision" end
   if type(object.data)~="table" then return nil,"invalid object data" end
   if type(object.endpoints)~="table" or #object.endpoints<1
         or #object.endpoints>objects.MAX_ENDPOINTS then
      return nil,"invalid endpoint count"
   end

   local data_count=0
   for key,value in pairs(object.data) do
      data_count=data_count+1
      if data_count>16 or not plain_string(key,32,"^[%w_%-]+$")
            or not plain_string(value,objects.MAX_DATA) then
         return nil,"invalid object data"
      end
   end
   if object.kind=="message_buoy" then
      if data_count~=2 or not plain_string(object.data.text,96)
            or not plain_string(object.data.captain,96) then
         return nil,"invalid message buoy data"
      end
   elseif data_count~=0 then
      -- Registrations intentionally live in a future child store, never in
      -- this immutable object payload.
      return nil,"unexpected immutable object data"
   end

   for _index,endpoint in ipairs(object.endpoints) do
      if type(endpoint)~="table"
            or not plain_string(endpoint.id,128,"^[%w_%-]+$")
            or not plain_string(endpoint.system,240)
            or not finite(endpoint.x,-1e9,1e9)
            or not finite(endpoint.y,-1e9,1e9)
            or not finite(endpoint.dir,-1e6,1e6)
            or not plain_string(endpoint.role,32,"^[%w_%-]+$")
            or type(endpoint.visible)~="boolean"
            or (endpoint.target~=nil
               and not plain_string(endpoint.target,128,"^[%w_%-]+$")) then
         return nil,"invalid endpoint"
      end
   end
   local endpoints,err=endpoint_map(object)
   if not endpoints then return nil,err end
   local ok
   ok,err=validate_relationships(object,endpoints)
   if not ok then return nil,err end
   return copy_object(object)
end

local function field ( value )
   return codec.escape(value)
end

local function parse_number ( value )
   local number=tonumber(value)
   if not number or number~=number then return nil end
   return number
end

function objects.encode ( object )
   local checked,err=objects.validate(object)
   if not checked then return nil,err end
   local data={}
   for key,value in pairs(checked.data) do
      data[#data+1]=field(key)..":"..field(value)
   end
   table.sort(data)
   local endpoints={}
   for _index,endpoint in ipairs(checked.endpoints) do
      endpoints[#endpoints+1]=table.concat({
         field(endpoint.id),field(endpoint.system),endpoint.x,endpoint.y,
         endpoint.dir,field(endpoint.role),endpoint.visible and "1" or "0",
         endpoint.target and field(endpoint.target) or "-",
      },",")
   end
   table.sort(endpoints)
   return table.concat({
      field(checked.id),field(checked.kind),field(checked.owner),
      checked.created,checked.revision,
      #data>0 and table.concat(data,",") or "-",
      table.concat(endpoints,";"),
   },"|")
end

function objects.decode ( packed )
   if type(packed)~="string" or packed=="" or #packed>12000 then
      return nil,"invalid packed object"
   end
   local fields={}
   for value in (packed.."|"):gmatch("(.-)|") do fields[#fields+1]=value end
   if #fields~=7 then return nil,"malformed object payload" end
   local object={
      id=codec.unescape(fields[1]),
      kind=codec.unescape(fields[2]),
      owner=codec.unescape(fields[3]),
      created=parse_number(fields[4]),
      revision=parse_number(fields[5]),
      data={},
      endpoints={},
   }
   if fields[6]~="-" then
      for item in fields[6]:gmatch("([^,]+)") do
         local raw_key,raw_value=item:match("^([^:]+):(.*)$")
         local key=raw_key and codec.unescape(raw_key)
         local value=raw_value and codec.unescape(raw_value)
         if not key or not value or object.data[key] then
            return nil,"malformed object data"
         end
         object.data[key]=value
      end
   end
   for record in fields[7]:gmatch("([^;]+)") do
      local part={}
      for value in (record..","):gmatch("(.-),") do part[#part+1]=value end
      if #part~=8 then return nil,"malformed endpoint payload" end
      local visible
      if part[7]=="1" then visible=true
      elseif part[7]=="0" then visible=false
      else return nil,"malformed endpoint visibility" end
      object.endpoints[#object.endpoints+1]={
         id=codec.unescape(part[1]),
         system=codec.unescape(part[2]),
         x=parse_number(part[3]),
         y=parse_number(part[4]),
         dir=parse_number(part[5]),
         role=codec.unescape(part[6]),
         visible=visible,
         target=part[8]~="-" and codec.unescape(part[8]) or nil,
      }
   end
   return objects.validate(object)
end

function objects.visible_in ( object, system_name )
   for _index,endpoint in ipairs(object.endpoints) do
      if endpoint.visible and endpoint.system==system_name then return true end
   end
   return false
end

function objects.policy_create ( object, node, existing )
   local checked,err=objects.validate(object)
   if not checked then return nil,err end
   if checked.owner~=node then return nil,"owner does not match verified node" end
   if existing[checked.id] then return nil,"object id already exists" end
   if checked.kind=="message_buoy" then
      local system_name=checked.endpoints[1].system
      for _id,current in pairs(existing) do
         if current.kind=="message_buoy"
               and current.endpoints[1].system==system_name then
            return nil,"system occupied"
         end
      end
   end
   return checked
end

function objects.policy_delete ( object, node )
   if object.kind=="message_buoy" then return true end
   if object.owner~=node then return nil,"owner required" end
   return true
end

return objects
