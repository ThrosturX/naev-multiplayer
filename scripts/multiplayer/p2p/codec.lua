-- MP2P/1 directory/bootstrap/object codec. Gameplay uses the fixed MP2G/2
-- codec in multiplayer.p2p.gameplay_codec.
local codec = {}

codec.VERSION = "MP2P/1"
codec.MAX_PACKET = 16*1024

local function escape ( value )
   local escaped=tostring(value):gsub("([^%w%-%._~])",function ( c )
      return string.format("%%%02X",string.byte(c))
   end)
   return escaped
end

local function unescape ( value )
   local at=1
   while true do
      local mark=value:find("%",at,true)
      if not mark then break end
      if not value:sub(mark+1,mark+2):match("^%x%x$") then
         return nil,"invalid escape"
      end
      at=mark+3
   end
   return (value:gsub("%%(%x%x)",function ( hex )
      return string.char(tonumber(hex,16))
   end))
end

codec.escape=escape
codec.unescape=unescape

local required = {
   hello={"node","cap"},
   query={"node","system"},
   hint={"node","system","host","endpoint","claim","ttl"},
   punch={"node","system","peer","endpoint"},
   claim={"node","system","claim","endpoint"},
   leave={"node","system"},
   activity_query={"node"},
   activity={"node","entries"},
   contestant_register={"node","division","ship","name","outfits","slots"},
   contestant_query={"node","division","request","limit"},
   contestant_entry={"node","contestant","division","request","ship","name",
      "outfits","slots"},
   contestant_done={"node","division","request","count"},
   object_create={"node","request","object_id","object"},
   object_query={"node","system","request"},
   object_entry={"node","request","object"},
   object_done={"node","system","request","count"},
   object_delete={"node","request","object_id"},
   object_deleted={"node","object_id","revision"},
   object_result={"node","request","action","ok","code","object_id","revision"},
}

local numeric = {
   ttl={1,60},division={1,3},request={0,9007199254740991},
   limit={1,32},count={0,4096},revision={1,9007199254740991},
   ok={0,1},
}

local function plain ( value, maximum )
   return type(value)=="string" and value~="" and #value<=maximum
      and not value:find("[%z\1-\31\127]")
end

local function node_id ( value )
   return type(value)=="string" and #value>=1 and #value<=64
      and value:match("^[%x]+$")~=nil
end

local function validate ( message )
   if type(message)~="table" or not required[message.type] then
      return nil,"unknown type"
   end
   for _index,key in ipairs(required[message.type]) do
      if message[key]==nil or message[key]=="" then
         return nil,"missing "..key
      end
   end
   if not node_id(message.node) then return nil,"invalid node" end
   if message.host and not node_id(message.host) then return nil,"invalid host" end
   if message.peer and not node_id(message.peer) then return nil,"invalid peer" end
   if message.contestant and not node_id(message.contestant) then
      return nil,"invalid contestant"
   end
   if message.cap and message.cap~="player"
         and message.cap~="directory" then
      return nil,"invalid capability"
   end
   if message.features and (#message.features>240
         or message.features:find("[^%w_,%-]")) then
      return nil,"invalid features"
   end
   if message.track and (#message.track>64
         or message.track:find("[^%w_%-]")) then
      return nil,"invalid track"
   end
   if message.type=="hello" and message.cap=="player"
         and not plain(message.name,240) then
      return nil,"missing name"
   end
   if message.name and not plain(message.name,240) then
      return nil,"invalid name"
   end
   if message.ship and not plain(message.ship,240) then
      return nil,"invalid ship"
   end
   if message.ship_fallbacks and message.ship_fallbacks~=""
         and not plain(message.ship_fallbacks,2048) then
      return nil,"invalid ship fallbacks"
   end
   if message.outfits and (#message.outfits>12000
         or message.outfits:find("[%z\1-\31\127]")) then
      return nil,"invalid outfits"
   end
   if message.slots and (#message.slots>12000
         or message.slots:find("[%z\1-\31\127]")) then
      return nil,"invalid slots"
   end
   if message.system and not plain(message.system,240) then
      return nil,"invalid system"
   end
   if message.entries and (#message.entries>12000
         or message.entries:find("[%z\1-\31\127]")) then
      return nil,"invalid entries"
   end
   if message.object and (#message.object>12000
         or message.object:find("[%z\1-\31\127]")) then
      return nil,"invalid object"
   end
   if message.object_id and (#message.object_id>128
         or not message.object_id:match("^[%w_%-]+$")) then
      return nil,"invalid object id"
   end
   if message.endpoint and (#message.endpoint>255
         or not message.endpoint:match("^[^%s:]+:%d+$")) then
      return nil,"invalid endpoint"
   end
   if message.claim and not plain(message.claim,160) then
      return nil,"invalid claim"
   end
   if message.action and message.action~="create"
         and message.action~="delete" then
      return nil,"invalid object action"
   end
   if message.code and (#message.code>32
         or not message.code:match("^[%w_%-]+$")) then
      return nil,"invalid result code"
   end
   for key,bounds in pairs(numeric) do
      if message[key]~=nil then
         local value=tonumber(message[key])
         if not value or value~=value
               or value<bounds[1] or value>bounds[2] then
            return nil,"invalid "..key
         end
         message[key]=value
      end
   end
   return message
end

codec.validate=validate

function codec.encode ( message )
   local checked,err=validate(message)
   if not checked then return nil,err end
   local keys={}
   for key in pairs(message) do
      if key~="type" then keys[#keys+1]=key end
   end
   table.sort(keys)
   local lines={codec.VERSION.." "..message.type}
   for _index,key in ipairs(keys) do
      lines[#lines+1]=escape(key).."="..escape(message[key])
   end
   local packet=table.concat(lines,"\n").."\n"
   if #packet>codec.MAX_PACKET then return nil,"packet too large" end
   return packet
end

function codec.decode ( packet )
   if type(packet)~="string" then return nil,"packet is not a string" end
   if #packet>codec.MAX_PACKET then return nil,"packet too large" end
   local header,body=packet:match("^([^\n]+)\n?(.*)$")
   if not header then return nil,"missing header" end
   local version,kind=header:match("^(%S+) ([%w_]+)$")
   if version~=codec.VERSION then return nil,"incompatible version" end
   local message={type=kind}
   for line in body:gmatch("([^\n]+)") do
      local raw_key,raw_value=line:match("^([^=]+)=(.*)$")
      if not raw_key then return nil,"invalid field" end
      local key,key_err=unescape(raw_key)
      local value,value_err=unescape(raw_value)
      if not key then return nil,key_err end
      if not value then return nil,value_err end
      if key=="type" or message[key]~=nil then
         return nil,"duplicate field"
      end
      message[key]=value
   end
   return validate(message)
end

return codec
