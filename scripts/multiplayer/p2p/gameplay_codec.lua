-- Fixed player-to-player gameplay protocol. Directory/bootstrap/object
-- traffic deliberately remains on multiplayer.p2p.codec (MP2P/1).
local codec = {}

codec.VERSION = "MP2G/2"
codec.MAX_PACKET = 16 * 1024

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
   hello={"node","name","endpoint"},
   query={"node","system","visit"},
   claim={"node","system","visit","epoch","endpoint"},
   heartbeat={"node","system","visit","seq"},
   leave={"node","system","visit","epoch","owner"},
   join={"node","system","visit","epoch","seq"},
   player_manifest={"node","system","visit","epoch","owner","entity","origin",
      "ship","name","outfits","slots","weapsets"},
   entity_manifest={"node","system","visit","epoch","kind","owner","entity",
      "origin","ship","name","faction","ai","outfits","slots"},
   entity_remove={"node","system","visit","epoch","kind","owner","entity",
      "seq","reason"},
   entity_query={"node","system","visit","epoch","entity","seq"},
   player_state={"node","system","visit","epoch","entity","seq","x","y",
      "vx","vy","dir","armour","shield","stress","energy","target",
      "weapset","accel","turn","reverse","primary","secondary","active"},
   player_control={"node","system","visit","epoch","owner","entity","seq","x","y",
      "vx","vy","dir","energy","target","weapset","accel","primary",
      "secondary","turn","reverse","active"},
   craft_state={"node","system","visit","epoch","owner","entity","seq",
      "state"},
   craft_order={"node","system","visit","epoch","owner","seq","order",
      "target"},
   target_interest={"node","system","visit","epoch","owner","seq","target"},
   world={"node","system","visit","epoch","seq","players","entities","objects"},
   entity_absent={"node","system","visit","epoch","entity","seq"},
   chat={"node","system","visit","epoch","owner","seq","text"},
}

local numeric = {
   seq={0,9007199254740991},
   ttl={1,60},
   x={-1e9,1e9},y={-1e9,1e9},
   vx={-1e7,1e7},vy={-1e7,1e7},
   dir={-1e6,1e6},
   armour={0,1e9},shield={0,1e9},stress={0,1e9},energy={0,1e9},
   weapset={1,10},accel={0,1},primary={0,1},secondary={0,1},
   turn={-1,1},reverse={0,1},
}

local function plain ( value, maximum )
   return type(value)=="string" and value~="" and #value<=maximum
      and not value:find("[%z\1-\31\127]")
end

local function node_id ( value )
   return type(value)=="string" and #value>=1 and #value<=64
      and value:match("^[%x]+$")~=nil
end

local function entity_id ( value )
   return type(value)=="string" and #value>=1 and #value<=255
      and value:match("^[%w_%.%-]+$")~=nil
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
   for _index,key in ipairs({"host","owner"}) do
      if message[key]~=nil and not node_id(message[key]) then
         return nil,"invalid "..key
      end
   end
   if message.accepted_host and not node_id(message.accepted_host) then
      return nil,"invalid accepted host"
   end
   if message.visit and (#message.visit>64
         or not message.visit:match("^[%x]+$")) then
      return nil,"invalid visit"
   end
   if message.epoch and not plain(message.epoch,160) then
      return nil,"invalid epoch"
   end
   if message.accepted_epoch and not plain(message.accepted_epoch,160) then
      return nil,"invalid accepted epoch"
   end
   if message.system and not plain(message.system,240) then
      return nil,"invalid system"
   end
   if message.endpoint and (#message.endpoint>255
         or not message.endpoint:match("^[^%s:]+:%d+$")) then
      return nil,"invalid endpoint"
   end
   for _index,key in ipairs({"entity","origin","leader","target"}) do
      local value=message[key]
      if value~=nil and value~="-" and not entity_id(value) then
         return nil,"invalid "..key
      end
   end
   if message.kind and message.kind~="npc"
         and message.kind~="craft" then
      return nil,"invalid entity kind"
   end
   if message.type=="entity_manifest" and message.kind~="craft" then
      return nil,"entity manifests are only used for player-owned craft"
   end
   if message.reason and message.reason~="absent"
         and message.reason~="death" and message.reason~="exploded"
         and message.reason~="jump" and message.reason~="land"
         and message.reason~="removed" then
      return nil,"invalid removal reason"
   end
   if message.order and message.order~="e_attack"
         and message.order~="e_hold" and message.order~="e_return"
         and message.order~="e_clear" then
      return nil,"invalid craft order"
   end
   if message.name and not plain(message.name,240) then
      return nil,"invalid name"
   end
   if message.ship and not plain(message.ship,240) then
      return nil,"invalid ship"
   end
   if message.ship_fallbacks and message.ship_fallbacks~=""
         and (#message.ship_fallbacks>2048
            or message.ship_fallbacks:find("[%z\1-\31\127]")) then
      return nil,"invalid ship fallbacks"
   end
   if message.faction and message.faction~="-"
         and not plain(message.faction,240) then
      return nil,"invalid faction"
   end
   if message.ai and message.ai~="-"
         and (#message.ai>240 or not message.ai:match("^[%w_%-]+$")) then
      return nil,"invalid ai"
   end
   if message.text and (#message.text>1024
         or message.text:find("[%z\1-\8\11\12\14-\31\127]")) then
      return nil,"invalid text"
   end
   if message.outfits and (#message.outfits>12000
         or message.outfits:find("[%z\1-\31\127]")) then
      return nil,"invalid outfits"
   end
   if message.slots and (#message.slots>12000
         or message.slots:find("[%z\1-\31\127]")) then
      return nil,"invalid slots"
   end
   if message.weapsets and (#message.weapsets>4096
         or message.weapsets:find("[^%d:;%.]")) then
      return nil,"invalid weapon sets"
   end
   if message.active and (#message.active>4096
         or message.active:find("[%z\1-\31\127]")) then
      return nil,"invalid active outfits"
   end
   for _index,key in ipairs({"players","entities","objects","state"}) do
      local value=message[key]
      if value and (#value>12000 or value:find("[%z\1-\31\127]")) then
         return nil,"invalid packed state"
      end
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
   if message.type=="player_manifest" or message.type=="player_control" then
      if not message.entity:match("^"..message.owner.."%.") then
         return nil,"player entity does not match node"
      end
   elseif message.type=="player_state"
         and not message.entity:match("^"..message.node.."%.") then
      return nil,"player entity does not match node"
   end
   if message.type=="craft_state" and message.owner~=message.node then
      return nil,"craft owner does not match sender"
   end
   return message
end

codec.validate=validate

local packed_field = {
   players=true,entities=true,objects=true,state=true,
}

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
      local value=packed_field[key] and tostring(message[key])
         or escape(message[key])
      lines[#lines+1]=escape(key).."="..value
   end
   local packet=table.concat(lines,"\n").."\n"
   if #packet>codec.MAX_PACKET then return nil,"packet too large" end
   return packet
end

local function copy_message ( message )
   local copy={}
   for key,value in pairs(message) do copy[key]=value end
   return copy
end

local function empty_world ( base )
   local message=copy_message(base)
   message.players="-"
   message.entities="-"
   message.objects="-"
   return message
end

-- ENet rejects an unreliable packet that is larger than the peer MTU; its Lua
-- binding does not expose ENET_PACKET_FLAG_UNRELIABLE_FRAGMENT. Build several
-- independently replaceable world datagrams when a frame cannot fit in one.
-- Every returned buffer is already encoded so host fanout can reuse it.
function codec.encode_world_batches ( base, records, maximum )
   maximum=math.min(tonumber(maximum) or codec.MAX_PACKET,codec.MAX_PACKET)
   if maximum<256 then return nil,"invalid world packet budget" end
   records=records or {}
   local batches={}
   local oversized={}
   local current=empty_world(base)
   local current_packet,err=codec.encode(current)
   if not current_packet then return nil,err end
   local current_count=0

   local function flush ()
      if current_count==0 then return end
      batches[#batches+1]={message=current,packet=current_packet}
      current=empty_world(base)
      current_packet=assert(codec.encode(current))
      current_count=0
   end

   local function append ( field, line )
      if type(line)~="string" or line=="" then
         return nil,"invalid packed world record"
      end
      local candidate=copy_message(current)
      candidate[field]=candidate[field]=="-"
         and line or candidate[field]..";"..line
      local packet,encode_err=codec.encode(candidate)
      if packet and #packet<=maximum then
         current=candidate
         current_packet=packet
         current_count=current_count+1
         return true
      end
      if current_count==0 then
         return nil,encode_err or "world record exceeds packet budget"
      end
      flush()
      candidate=copy_message(current)
      candidate[field]=line
      packet,encode_err=codec.encode(candidate)
      if not packet or #packet>maximum then
         return nil,encode_err or "world record exceeds packet budget"
      end
      current=candidate
      current_packet=packet
      current_count=1
      return true
   end

   for _index,line in ipairs(records.players or {}) do
      local ok,append_err=append("players",line)
      if not ok then return nil,append_err end
   end
   for _index,line in ipairs(records.entities or {}) do
      local ok,append_err=append("entities",line)
      if not ok and append_err=="world record exceeds packet budget" then
         oversized[#oversized+1]=line
      elseif not ok then
         return nil,append_err
      end
   end
   for _index,line in ipairs(records.objects or {}) do
      local ok,append_err=append("objects",line)
      if not ok then return nil,append_err end
   end
   flush()
   if #batches==0 and #oversized==0 then
      return nil,"world frame has no records"
   end
   return batches,nil,oversized
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
      if not key then return nil,key_err end
      local value,value_err
      if packed_field[key] then
         value=raw_value
      else
         value,value_err=unescape(raw_value)
      end
      if not value then return nil,value_err end
      if key=="type" or message[key]~=nil then
         return nil,"duplicate field"
      end
      message[key]=value
   end
   return validate(message)
end

return codec
