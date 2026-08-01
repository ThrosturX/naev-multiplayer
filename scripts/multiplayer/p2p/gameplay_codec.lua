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

function codec.pack_state ( record )
   return table.concat({
      record.entity,record.x,record.y,record.vx,record.vy,record.dir,
      record.armour,record.shield,record.stress,record.energy,
      record.target or "-",record.weapset or 1,record.accel or 0,
      record.turn or 0,record.reverse or 0,
      record.primary or 0,record.secondary or 0,
   },",")
end

function codec.unpack_state ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=17 or not fields[1]:match("^[%w_%.%-]+$") then return nil end
   local record={
      entity=fields[1],
      x=tonumber(fields[2]),y=tonumber(fields[3]),
      vx=tonumber(fields[4]),vy=tonumber(fields[5]),
      dir=tonumber(fields[6]),armour=tonumber(fields[7]),
      shield=tonumber(fields[8]),stress=tonumber(fields[9]),
      energy=tonumber(fields[10]),target=fields[11],
      weapset=tonumber(fields[12]),accel=tonumber(fields[13]),
      turn=tonumber(fields[14]),reverse=tonumber(fields[15]),
      primary=tonumber(fields[16]),secondary=tonumber(fields[17]),
   }
   for _index,key in ipairs({
      "x","y","vx","vy","dir","armour","shield","stress","energy",
      "weapset","accel","turn","reverse","primary","secondary",
   }) do
      local value=record[key]
      if not value or value~=value then return nil end
   end
   if math.abs(record.x)>1e9 or math.abs(record.y)>1e9
         or math.abs(record.vx)>1e7 or math.abs(record.vy)>1e7
         or math.abs(record.dir)>1e6
         or record.armour<0 or record.armour>1e9
         or record.shield<0 or record.shield>1e9
         or record.stress<0 or record.stress>1e9
         or record.energy<0 or record.energy>1e9 then return nil end
   if #record.entity>255 or #record.target>255
         or (record.target~="-"
            and not record.target:match("^[%w_%.%-]+$"))
         or record.weapset<1 or record.weapset>10
         or record.accel<0 or record.accel>1
         or record.turn< -1 or record.turn>1
         or record.reverse<0 or record.reverse>1
         or record.primary<0 or record.primary>1
         or record.secondary<0 or record.secondary>1 then return nil end
   return record
end

function codec.pack_object_state ( record )
   return table.concat({
      record.entity,record.x,record.y,record.vx,record.vy,record.dir,
      record.armour,record.shield,record.stress,
   },",")
end

function codec.unpack_object_state ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=9 or not fields[1]:match("^[%w_%.%-]+$") then return nil end
   local record={
      entity=fields[1],
      x=tonumber(fields[2]),y=tonumber(fields[3]),
      vx=tonumber(fields[4]),vy=tonumber(fields[5]),
      dir=tonumber(fields[6]),
      armour=tonumber(fields[7]),shield=tonumber(fields[8]),
      stress=tonumber(fields[9]),
   }
   for _index,key in ipairs({
      "x","y","vx","vy","dir","armour","shield","stress",
   }) do
      local value=record[key]
      if not value or value~=value then return nil end
   end
   if #record.entity>255
         or math.abs(record.x)>1e9 or math.abs(record.y)>1e9
         or math.abs(record.vx)>1e7 or math.abs(record.vy)>1e7
         or math.abs(record.dir)>1e6
         or record.armour<0 or record.armour>1e9
         or record.shield<0 or record.shield>1e9
         or record.stress<0 or record.stress>1e9 then return nil end
   return record
end

function codec.pack_npc_announcement ( entry, record )
   local description=entry.description
   if not description then return nil end
   local slots=description.slots or "-"
   local outfits=slots~="-" and "-" or (description.outfits or "-")
   return table.concat({
      "n",codec.pack_state(record),
      escape(description.owner),
      escape(description.origin),
      escape(description.ship),
      escape(description.name),
      escape(description.faction),
      escape(description.ai),
      escape(outfits),
      escape(slots),
      escape(description.leader or "-"),
   },",")
end

function codec.unpack_npc_announcement ( packed )
   local fields={}
   for value in (packed..","):gmatch("(.-),") do fields[#fields+1]=value end
   if #fields~=27 or fields[1]~="n" then return nil end
   local dynamic={}
   for index=2,18 do dynamic[#dynamic+1]=fields[index] end
   local record=codec.unpack_state(table.concat(dynamic,","))
   if not record then return nil end
   local decoded={}
   for index=19,27 do
      decoded[index]=unescape(fields[index])
      if not decoded[index] then return nil end
   end
   local owner,origin,ship_name,name,faction_name,ai_name,
      outfits,slots,leader=decoded[19],decoded[20],decoded[21],
      decoded[22],decoded[23],decoded[24],decoded[25],decoded[26],decoded[27]
   if #owner<1 or #owner>64 or not owner:match("^[%x]+$")
         or #origin<1 or #origin>255
         or not origin:match("^[%w_%.%-]+$")
         or #ship_name<1 or #ship_name>240
         or ship_name:find("[%z\1-\31\127]")
         or #name<1 or #name>240 or name:find("[%z\1-\31\127]")
         or #faction_name<1 or #faction_name>240
         or faction_name:find("[%z\1-\31\127]")
         or #ai_name<1 or #ai_name>240
         or not ai_name:match("^[%w_%-]+$")
         or #outfits>12000 or outfits:find("[%z\1-\31\127]")
         or #slots>12000 or slots:find("[%z\1-\31\127]")
         or (leader~="-" and (#leader>255
            or not leader:match("^[%w_%.%-]+$"))) then
      return nil
   end
   return record,{
      kind="npc",owner=owner,entity=record.entity,origin=origin,
      ship=ship_name,name=name,faction=faction_name,ai=ai_name,
      outfits=outfits,slots=slots,leader=leader,
      x=record.x,y=record.y,vx=record.vx,vy=record.vy,dir=record.dir,
      armour=record.armour,shield=record.shield,stress=record.stress,
      energy=record.energy,target=record.target,weapset=record.weapset,
      accel=record.accel,turn=record.turn,reverse=record.reverse,
      primary=record.primary,secondary=record.secondary,
   }
end

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
      "weapset","accel","turn","reverse","primary","secondary"},
   player_control={"node","system","visit","epoch","owner","entity","seq","x","y",
      "vx","vy","dir","energy","target","weapset","accel","primary",
      "secondary","turn","reverse"},
   outfit_toggle={"node","system","visit","epoch","owner","entity","seq",
      "slot","on"},
   entity_state={"node","system","visit","epoch","kind","owner","entity","seq",
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
   turn={-1,1},reverse={0,1},slot={1,512},on={0,1},
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
   if message.active~=nil then
      return nil,"active outfit snapshots are unsupported"
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
   if message.kind and message.kind~="npc" and message.kind~="craft"
         and not (message.type=="entity_remove"
            and message.kind=="player") then
      return nil,"invalid entity kind"
   end
   if message.type=="entity_remove" and message.kind=="player"
         and (message.reason~="death"
            or not message.entity:match("^"..message.owner.."%.")) then
      return nil,"invalid player removal"
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
   if message.type=="player_manifest" or message.type=="player_control"
         or message.type=="outfit_toggle" then
      if not message.entity:match("^"..message.owner.."%.") then
         return nil,"player entity does not match node"
      end
   elseif message.type=="player_state"
         and not message.entity:match("^"..message.node.."%.") then
      return nil,"player entity does not match node"
   end
   if message.type=="entity_manifest" then
      if not message.entity:match("^"..message.owner.."%.")
            or not message.origin:match("^"..message.owner.."%.") then
         return nil,"entity identity does not match owner"
      end
   end
   if message.type=="entity_state" then
      if message.owner~=message.node then
         return nil,"entity owner does not match sender"
      end
      if not message.entity:match("^"..message.owner.."%.") then
         return nil,"entity does not match owner"
      end
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
